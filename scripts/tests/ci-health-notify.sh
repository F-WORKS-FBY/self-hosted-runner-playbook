#!/usr/bin/env bash
# ci-health-notify.sh：ci-health.sh 推送飞书卡片的用例。不要 root、不联网、不写 /var、不进 journal。
#
#   bash scripts/tests/ci-health-notify.sh
#   SAMPLES_DIR=<目录> bash scripts/tests/ci-health-notify.sh   # 另把几张典型卡片（card 对象）存成 JSON
#
# 做法：按 bootstrap 的方式渲染出 ci-health.sh，PATH 前面放 systemctl、pgrep、ps、df、du、stat、hostname、logger、sleep
# 的桩，按 FAKE_* 变量给出磁盘、服务、listener、job 的读数；python3 也包一层，只把定长任务和 job 产出采样两段换成
# FAKE_FIXEDWORK、FAKE_JOBS（不烧 CPU、不连 GitHub），其余照常交给真的 python3。
# 推送地址指向 127.0.0.1 上的假 webhook：它把请求体存下来，按 codes 文件依次回飞书的返回码（默认 0）。
# 核：卡片结构、颜色、标题与副标题、分节、转义、签名、去重、24 小时提醒、部分消除、恢复、限流重试、
# 卡片被拒改发文本、失败不写状态、日志里不出现地址和密钥。
# 名字可换：TEST_RUNNER_NAME、TEST_HOST、TEST_REPO（默认 ci-1、ubuntu-4gb-hel1-1、owner/repo）。
# 下面关掉的两条 shellcheck 提示是故意的：桩和断言用单引号，交给桩或 python 再展开（SC2016）；ok、no 总是返回 0（SC2015）。
# shellcheck disable=SC2016,SC2015
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$HERE/../ci-health.sh"
REAL_PY=$(command -v python3) || { echo "缺 python3" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/ci-health-notify.XXXXXX")
SRV_PID=""
cleanup(){ [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
RUNNER_NAME_T="${TEST_RUNNER_NAME:-ci-1}"; HOST_T="${TEST_HOST:-ubuntu-4gb-hel1-1}"; REPO_T="${TEST_REPO:-owner/repo}"
SVC_T="actions.runner.${REPO_T//\//-}.${RUNNER_NAME_T}.service"
SECRET_T="test-secret-$RANDOM$RANDOM"
PASS=0; FAIL=0
ok(){ PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
no(){ FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# ---- 渲染：和 bootstrap.sh 一样只替换服务名占位符 ----
sed "s#__RUNNER_SVC__#${SVC_T}#" "$SRC" > "$T/ci-health.sh"; chmod 0755 "$T/ci-health.sh"

# ---- 桩 ----
mkdir -p "$T/bin" "$T/fake" "$T/srv" "$T/runner"
stub(){ printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/bin/$1"; chmod 0755 "$T/bin/$1"; }
stub systemctl 'case "$1" in is-active) echo "${FAKE_SVC_STATE:-active}" ;; show) echo 2147483648 ;; esac; exit 0'
stub pgrep 'case "${@: -1}" in
  Runner.Listener) [ -n "${FAKE_LISTENER_AGE:-}" ] && { echo 4242; exit 0; }; exit 1 ;;
  Runner.Worker) n=$(( $(cat "$FAKE_DIR/worker_calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/worker_calls"
    [ "$n" -le "${FAKE_WORKER_BUSY_CALLS:-0}" ] && exit 0
    [ -n "${FAKE_AVAIL_IDLE:-}" ] && echo "$FAKE_AVAIL_IDLE" > "$FAKE_DIR/avail"; exit 1 ;;
esac; exit 1'
stub ps 'echo "${FAKE_LISTENER_AGE:-}"'
stub df 'case "$*" in *avail*) printf "Avail\n%sM\n" "$(cat "$FAKE_DIR/avail")" ;; *used*) printf "Used\n%sM\n" "${FAKE_USED:-52120}" ;; esac'
stub du 'case "${@: -1}" in /var/lib/containerd) v=${FAKE_CTR:-32339} ;; /tmp) v=${FAKE_TMP:-1411} ;; *) v=0 ;; esac; printf "%sM\t%s\n" "$v" "${@: -1}"'
stub stat "REAL=$(printf '%q' "$(command -v stat)")"'
if [ "$1" = -c ] && [ "$2" = %d ]; then
  case "$3" in /var/lib/containerd) echo "${FAKE_CTR_DEV:-2049}" ;; /tmp) echo "${FAKE_TMP_DEV:-2049}" ;; *) echo 2049 ;; esac; exit 0
fi
exec "$REAL" "$@"'
stub hostname 'echo "${FAKE_HOST}"'
stub logger 'echo "$*" >> "$FAKE_DIR/journal"'
stub sleep 'exec /bin/sleep 0.01'
stub python3 "REAL=$(printf '%q' "$REAL_PY")"'
if [ "${1:-}" = - ]; then
  src=$(cat)
  case "$src" in
    *workflow_runs*) [ -n "${FAKE_JOBS:-}" ] && { echo "$FAKE_JOBS"; exit 0; } ;;
    *"range(180000)"*) [ -n "${FAKE_FIXEDWORK:-}" ] && { echo "$FAKE_FIXEDWORK"; exit 0; } ;;
  esac
  printf "%s\n" "$src" | "$REAL" -
  exit $?
fi
exec "$REAL" "$@"'

# ---- 假 webhook ----
cat > "$T/server.py" <<'PY'
import http.server, json, os, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        n = len([f for f in os.listdir(d) if f.startswith("req.")]) + 1
        with open(os.path.join(d, "req.%d.json" % n), "wb") as f:
            f.write(body)
        p = os.path.join(d, "codes")
        codes = open(p).read().split() if os.path.exists(p) else []
        open(p, "w").write(" ".join(codes[1:]))
        code = int(codes[0]) if codes else 0
        out = json.dumps({"code": code, "msg": "success" if code == 0 else "fail", "data": {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY
"$REAL_PY" -I "$T/server.py" "$T/srv" & SRV_PID=$!
for _ in $(seq 100); do [ -f "$T/srv/port" ] && break; /bin/sleep 0.05; done
[ -f "$T/srv/port" ] || { echo "假 webhook 没起来" >&2; exit 2; }
HOOK="http://127.0.0.1:$(cat "$T/srv/port")/open-apis/bot/v2/hook/test-hook-id"

printf '{"agentId": 7, "agentName": "%s"}' "$RUNNER_NAME_T" > "$T/runner/.runner"
write_env(){   # write_env [webhook] [secret]
  { echo "GH_REPO=$REPO_T"; echo "CI_HEALTH_GH_TOKEN=fake-read-only"
    [ -n "${1:-}" ] && echo "CI_ALERT_WEBHOOK=$1"; [ -n "${2:-}" ] && echo "CI_ALERT_SECRET=$2"; } > "$T/ci-health.env"
}
printf 'RUNNER_HOME=%s\nCI_FIXEDWORK_BASELINE=2.000\nCI_DISK_WARN_MB=21504\nCI_DISK_CRIT_MB=10240\n' "$T/runner" > "$T/ci-runner.env"

# 跑一次 ci-health。参数是 FAKE_* 等变量赋值（KEY=VALUE），每次都从默认读数起
run_health(){
  rm -f "$T/fake/worker_calls"; echo 30000 > "$T/fake/avail"
  local kv; for kv in "$@"; do case "$kv" in FAKE_AVAIL=*) echo "${kv#FAKE_AVAIL=}" > "$T/fake/avail" ;; esac; done
  env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" FAKE_DIR="$T/fake" FAKE_HOST="$HOST_T" \
    FAKE_FIXEDWORK=2.100 FAKE_JOBS=streak=0 FAKE_LISTENER_AGE=3600 \
    CI_HEALTH_LOG="$T/ci-health.log" CI_HEALTH_STATE_DIR="$T/state" CI_HEALTH_ENV="$T/ci-health.env" \
    CI_RUNNER_ENV="$T/ci-runner.env" CI_HEALTH_IDLE_WAIT=1 "$@" bash "$T/ci-health.sh"
}
nreq(){ find "$T/srv" -name 'req.*.json' | wc -l | tr -d ' '; }
keys(){ cat "$T/state/keys" 2>/dev/null; }
# check <请求序号> <说明> <python 表达式>：b 是请求体，c 是卡片，m 是卡片正文，h 是头部，raw 是原始字节
check(){
  local f="$T/srv/req.$1.json"
  if [ ! -f "$f" ]; then no "$2（没有第 $1 个请求）"; return; fi
  if SECRET="$SECRET_T" "$REAL_PY" -I - "$f" "$3" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
raw = open(sys.argv[1], "rb").read()
b = json.loads(raw)
c = b.get("card") or {}
h = c.get("header") or {}
m = "\n".join(e.get("content", "") for e in (c.get("body") or {}).get("elements", []))
def signed():
    ts = b.get("timestamp", "")
    want = base64.b64encode(hmac.new(("%s\n%s" % (ts, os.environ["SECRET"])).encode(), b"", hashlib.sha256).digest()).decode()
    return ts.isdigit() and abs(time.time() - int(ts)) < 120 and b.get("sign") == want
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
  then ok "$2"; else no "$2"; fi
}
save_sample(){ [ -n "${SAMPLES_DIR:-}" ] || return 0; mkdir -p "$SAMPLES_DIR"
  "$REAL_PY" -I -c 'import json,sys; c=json.load(open(sys.argv[1]))["card"]; json.dump(c, open(sys.argv[2],"w"), ensure_ascii=False, indent=2)' \
    "$T/srv/req.$1.json" "$SAMPLES_DIR/$2"
  sed -i "s#$T/ci-health.log#/var/log/ci-health.log#g" "$SAMPLES_DIR/$2"; }   # 样张里写机器上的日志路径
reset_state(){ rm -rf "$T/state" "$T/srv"/req.*.json "$T/ci-health.log"; : > "$T/srv/codes"; }

echo "== 1. 没配推送地址：只记日志，不发"
write_env; reset_state
run_health FAKE_AVAIL=21300; rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || no "退出码 $rc"
[ "$(nreq)" = 0 ] && ok "没有请求" || no "发了 $(nreq) 个请求"
grep -q 'WARN 根分区可用 21300MB < 21504MB' "$T/ci-health.log" && ok "日志照旧记一行文本" || no "日志里没有那行文本"

echo "== 2. WARN 磁盘：橙色卡片，四节，签名对"
write_env "$HOOK" "$SECRET_T"; reset_state
run_health FAKE_AVAIL=21300
check 1 "msg_type 是 interactive，schema 2.0" 'b["msg_type"] == "interactive" and c["schema"] == "2.0"'
check 1 "timestamp、sign 在顶层且签名对" 'signed()'
check 1 "标题" 'h["title"] == {"tag": "plain_text", "content": "[CI runner 告警] '"$RUNNER_NAME_T"'：根分区可用空间偏低"}'
check 1 "副标题：主机名、级别、新出现" 'h["subtitle"]["content"] == "'"$HOST_T"' · WARN · 新出现"'
check 1 "颜色 orange" 'h["template"] == "orange"'
check 1 "预览文字就是标题" 'c["config"]["summary"]["content"] == h["title"]["content"]'
check 1 "四节依次是情况、影响、先做什么、去哪看" '[l for l in m.split("\n") if l.startswith("#### ")] == ["#### 1. 情况", "#### 2. 影响", "#### 3. 先做什么", "#### 4. 去哪看"]'
check 1 "数字照报" '"**21300 MB**" in m and "低于 WARN 线 21504 MB" in m and "containerd 32339 MB" in m and "/tmp 1411 MB" in m'
check 1 "先做什么是有序列表，命令用代码样式" '"\n1. `docker images`" in m and "\n3. " in m and "\n4. " not in m'
check 1 "去哪看链到手册公开仓库，锚点已编码" '"(https://github.com/F-WORKS-FBY/self-hosted-runner-playbook/blob/main/08-%E8%BF%90%E7%BB%B4%E4%B8%8E%E5%AE%B9%E9%87%8F.md#82-%E7%A3%81%E7%9B%98" in m'
check 1 "正文不再出现章节号" '"08 章" not in m and "8.2" not in m and "A22" not in m'
check 1 "请求体小于 19000 字节" 'len(raw) < 19000'
[ "$(keys)" = "disk_warn " ] && ok "状态文件记下 disk_warn" || no "状态文件是「$(keys)」"
save_sample 1 pb-warn-disk.json

echo "== 3. 告警没变：不重复发"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 1 ] && ok "没有新请求" || no "又发了（共 $(nreq) 个）"

echo "== 4. 满 24 小时：再提醒一次"
touch -d '25 hours ago' "$T/state/keys"
run_health FAKE_AVAIL=21300
check 2 "副标题写明是 24 小时提醒" 'h["subtitle"]["content"].endswith("超过 24 小时未消除，再提醒一次")'

echo "== 5. CRIT 连续失败 + 原有的 WARN：红色，按条分节，新的标出来"
run_health FAKE_AVAIL=21300 FAKE_JOBS=streak=4
check 3 "颜色 red" 'h["template"] == "red"'
check 3 "标题取最高级那条，注明几项" 'h["title"]["content"] == "[CI runner 告警] '"$RUNNER_NAME_T"'：本机 job 连续失败等 2 项"'
check 3 "副标题：各级条数与变化" 'h["subtitle"]["content"] == "'"$HOST_T"' · CRIT 1 条、WARN 1 条 · 新出现 1 条"'
check 3 "每条一节，CRIT 在前，新出现的标（新）" '[l for l in m.split("\n") if l.startswith("#### ")] == ["#### 1. CRIT 本机 job 连续失败（新）", "#### 2. WARN 根分区可用空间偏低", "#### 3. 本机采样记录"]'
check 3 "节内有情况、影响、先做什么、去哪看" 'm.count("**情况**") == 2 and m.count("**影响**：") == 2 and m.count("**先做什么**") == 2 and m.count("**去哪看**") == 2'
check 3 "连续失败次数与 runner 名" '"连续失败 **4 次**" in m and "`'"$RUNNER_NAME_T"'`" in m'
check 3 "附 GitHub Actions 链接" '"(https://github.com/'"$REPO_T"'/actions)" in m'
save_sample 3 pb-mixed.json

echo "== 6. 磁盘那条消除、连续失败还在：单条格式，写明同时消除"
run_health FAKE_JOBS=streak=5
check 4 "副标题：新出现 0、消除 1" 'h["subtitle"]["content"] == "'"$HOST_T"' · CRIT · 消除 1 条"'
check 4 "情况里列出同时消除的那条" '"- 同时消除：WARN 根分区可用空间偏低" in m'
check 4 "单条格式四节" 'm.startswith("#### 1. 情况\n") and "#### 4. 去哪看" in m'

echo "== 7. 全部消除：绿色恢复卡，列出之前的告警（CRIT 在前）"
printf 'disk_warn streak ' > "$T/state/keys"
run_health
check 5 "颜色 green" 'h["template"] == "green"'
check 5 "标题与副标题" 'h["title"]["content"] == "[CI runner 恢复] '"$RUNNER_NAME_T"'：告警已全部消除" and h["subtitle"]["content"] == "'"$HOST_T"' · 已恢复"'
check 5 "列出消除的告警" '"：\n- CRIT 本机 job 连续失败\n- WARN 根分区可用空间偏低\n\n#### 2. 要不要处理" in m'
[ -z "$(keys)" ] && ok "状态文件清空" || no "状态文件是「$(keys)」"
save_sample 5 pb-recover.json

echo "== 8. 单条 CRIT 连续失败（样张）"
reset_state
run_health FAKE_JOBS=streak=3
check 1 "红色，单条四节" 'h["template"] == "red" and m.startswith("#### 1. 情况\n") and "#### 3. 先做什么" in m'
check 1 "先跑 verify.sh 看钩子那一项" '"1. 在这台的手册仓库目录里跑 `bash scripts/verify.sh`" in m'
save_sample 1 pb-crit-streak.json

echo "== 9. 多条混合 + 外来字符：转义、排序、体积"
reset_state
printf 'RUNNER_HOME=%s\nCI_FIXEDWORK_BASELINE=2.000\nCI_DISK_WARN_MB=3`0*G_[x](y)<at id=all></at>\nCI_DISK_CRIT_MB=10240\n' "$T/runner" > "$T/ci-runner.env"
run_health FAKE_AVAIL=5500 FAKE_TMP_DEV=40 FAKE_SVC_STATE=failed FAKE_FIXEDWORK=3.300 FAKE_JOBS=streak=6
check 1 "CRIT 在前（磁盘、服务、连续失败），WARN 在后（CPU、配置）" '[l.split(" ", 3)[2] for l in m.split("\n") if l.startswith("#### ") and ("CRIT" in l or "WARN" in l)] == ["CRIT", "CRIT", "CRIT", "WARN", "WARN"]'
check 1 "配置原值进代码样式：没有反引号、拼不出 <at>" '"<at" not in m and "`CI_DISK_WARN_MB=3'"'"'0*G_[x](y)＜at id=all＞＜/at＞`" in m'
check 1 "/tmp 不在根分区时注明" '"/tmp 1411 MB（不在根分区）" in m'
check 1 "服务状态与服务名" '"`failed`" in m and "`'"$SVC_T"'`" in m'
check 1 "CPU 倍数" '"**3.300 秒**" in m and "1.65 倍" in m'
check 1 "请求体小于 19000 字节" 'len(raw) < 19000'
printf 'RUNNER_HOME=%s\nCI_FIXEDWORK_BASELINE=2.000\nCI_DISK_WARN_MB=21504\nCI_DISK_CRIT_MB=10240\n' "$T/runner" > "$T/ci-runner.env"

echo "== 10. listener 反复崩溃、job 采样 401"
reset_state
run_health FAKE_LISTENER_AGE=5 FAKE_JOBS=error:HTTP401
check 1 "listener：两次都是刚启动" '"隔 90 秒看了两次，都是刚启动（第二次 5 秒）" in m and "`journalctl -u '"$SVC_T"' -n 50`" in m'
check 1 "jobsprobe：401 给换 token 的步骤" '"`HTTP401`" in m and "CI_HEALTH_GH_TOKEN=" in m'

echo "== 11. 磁盘 WARN 在两个 job 之间量"
reset_state
run_health FAKE_AVAIL=20000 FAKE_WORKER_BUSY_CALLS=1 FAKE_AVAIL_IDLE=21000
check 1 "写明两个 job 之间量的值和整点值" '"两个 job 之间量的根分区可用 **21000 MB**" in m and "当时可用 20000 MB" in m'

echo "== 12. 一直有 job：沿用上一次的 WARN"
printf 'disk_warn ' > "$T/state/keys"; touch -d '25 hours ago' "$T/state/keys"
run_health FAKE_AVAIL=20000 FAKE_WORKER_BUSY_CALLS=999999
check 2 "写明沿用上一次" '"沿用上一次的 WARN" in m'

echo "== 13. 限流：等一会儿、重新签名再发一次"
reset_state; echo "11232 0" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 2 ] && ok "发了两次" || no "发了 $(nreq) 次"
check 2 "第二次签名也对" 'signed() and b["msg_type"] == "interactive"'
[ "$(keys)" = "disk_warn " ] && ok "成功后写状态" || no "状态文件是「$(keys)」"

echo "== 14. 卡片被拒（11246）：改发文本，日志记一行"
reset_state; echo "11246 0" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
check 2 "第二次是原来的文本消息" 'b["msg_type"] == "text" and b["content"]["text"].startswith("[CI runner 告警] '"$RUNNER_NAME_T"'（'"$HOST_T"'）\n· WARN 根分区可用 21300MB") and signed()'
grep -q '告警卡片被飞书拒收（11246' "$T/ci-health.log" && ok "日志记了卡片被拒" || no "日志里没有卡片被拒"
[ "$(keys)" = "disk_warn " ] && ok "文本发成功也写状态" || no "状态文件是「$(keys)」"

echo "== 15. 签名错（19021）：记失败，不写状态，下一小时重发"
reset_state; echo "19021" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
grep -q '告警推送失败：飞书返回 19021（签名或时间戳不对' "$T/ci-health.log" && ok "日志写明返回码和原因" || no "日志里没有失败原因"
[ ! -s "$T/state/keys" ] && ok "没写状态" || no "状态文件是「$(keys)」"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 2 ] && [ "$(keys)" = "disk_warn " ] && ok "下一次重发并成功" || no "请求 $(nreq) 个，状态「$(keys)」"

echo "== 16. 地址连不上：记失败，不写状态"
write_env "http://127.0.0.1:9/open-apis/bot/v2/hook/test-hook-id" "$SECRET_T"; reset_state
run_health FAKE_AVAIL=21300
grep -q '告警推送失败：请求失败' "$T/ci-health.log" && ok "日志写明请求失败" || no "日志里没有请求失败"
[ ! -s "$T/state/keys" ] && ok "没写状态" || no "状态文件是「$(keys)」"

echo "== 17. 没配签名密钥：不带 timestamp、sign"
write_env "$HOOK"; reset_state
run_health FAKE_AVAIL=21300
check 1 "请求体里没有 timestamp、sign" '"timestamp" not in b and "sign" not in b and b["msg_type"] == "interactive"'

echo "== 18. 日志和 journal 里没有推送地址和密钥"
if grep -rqF -e "$SECRET_T" -e "test-hook-id" "$T/ci-health.log" "$T/fake/journal" 2>/dev/null; then no "日志里出现了地址或密钥"; else ok "日志里没有地址和密钥"; fi

echo "== 19. 没写文案的 key（以后新加的检查）：照样送达，原文转义后放进情况"
# 直接跑 notify() 里那段 python，喂一条 ci-health 现在不会产生的 key
awk '/^notify\(\)\{/{n=1} n&&/^PY$/{exit} n>1{print} n&&/<<.PY. 2>&1$/{n=2}' "$T/ci-health.sh" > "$T/notify.py"
reset_state
CARD_KIND=alert CARD_TEXT="[CI runner 告警] x" CARD_RUNNER="$RUNNER_NAME_T" CARD_HOST="$HOST_T" CARD_LOG=/var/log/ci-health.log \
  CARD_ALERTS="$(printf 'newcheck\tWARN\ttext=WARN 新检查 *x* [a](b) <at id=all></at>')" CARD_PREV="" CARD_DOC=https://example.invalid \
  CI_ALERT_WEBHOOK="$HOOK" CI_ALERT_SECRET="$SECRET_T" "$REAL_PY" -I "$T/notify.py"; rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || no "退出码 $rc"
check 1 "标题用 key 本身" 'h["title"]["content"] == "[CI runner 告警] '"$RUNNER_NAME_T"'：newcheck"'
check 1 "原文转义后放进情况，拼不出链接和 @" '"- WARN 新检查 &#42;x&#42; &#91;a&#93;&#40;b&#41; &#60;at id=all&#62;&#60;/at&#62;" in m and "<at" not in m'

echo "== 20. 卡片拼装出错：改发文本"
reset_state
CARD_KIND=alert CARD_TEXT="[CI runner 告警] x" CARD_ALERTS="$(printf 'disk_warn\tWARN\tmode=now')" CARD_PREV="" CARD_DOC=x CARD_LOG=x \
  CI_ALERT_WEBHOOK="$HOOK" CI_ALERT_SECRET="$SECRET_T" "$REAL_PY" -I -c 'import sys; exec(open(sys.argv[1]).read().replace("def disk_parts(f):", "def disk_parts(f):\n    raise RuntimeError(\"boom\")"))' "$T/notify.py" > "$T/out.txt"; rc=$?
[ "$rc" = 0 ] && grep -q '告警卡片拼装出错（RuntimeError' "$T/out.txt" && ok "发成功并说明改发了文本" || no "退出码 $rc，输出：$(cat "$T/out.txt")"
check 1 "发的是文本消息" 'b["msg_type"] == "text" and b["content"]["text"] == "[CI runner 告警] x"'

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" = 0 ]
