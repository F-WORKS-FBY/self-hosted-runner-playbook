#!/usr/bin/env bash
# ci-health-notify.sh：ci-health.sh 推送飞书卡片的用例。不要 root、不联网、不写 /var、不进 journal。
#
#   bash scripts/tests/ci-health-notify.sh
#   SAMPLES_DIR=<目录> bash scripts/tests/ci-health-notify.sh   # 另把几张典型卡片（card 对象）存成 JSON
#   DEBUG_CARDS=1 bash scripts/tests/ci-health-notify.sh          # 断言失败时打出那张卡片的标题和正文
#
# 做法：按 bootstrap 的方式渲染出 ci-health.sh（替换服务名和手册仓库目录两个占位符），PATH 前面放 systemctl、pgrep、ps、
# df、du、stat、hostname、logger、sleep 的桩，按 FAKE_* 变量给出磁盘、服务、listener、job 的读数；python3 也包一层，
# 只把定长任务和 job 产出采样两段换成 FAKE_FIXEDWORK、FAKE_JOBS（不烧 CPU、不连 GitHub），其余照常交给真的 python3。
# FAKE_FIXEDWORK=crash、FAKE_JOBS_STDERR=<一行> 模拟那段 python 自己崩溃：往 stderr 写一段 traceback、退 1。
# 推送地址指向 127.0.0.1 上的假 webhook：它把请求体存下来，按 codes 文件依次回飞书的返回码（默认 0）。
# codes 里写「状态码:返回码」时回那个 HTTP 状态，返回码写「-」时回一段不是 JSON 的返回体。
# 核：卡片结构、颜色、标题与副标题、分节、转义、签名、去重、24 小时提醒、部分消除、量不到的不算消除（含没配 token、
# 定长任务没跑出结果）、恢复、先做什么以「以下在这台上用 root 跑」开头、verify.sh 的路径、401 单独写、采样出错时日志带原因
# 且不带 token、限流重试、卡片被拒或超长改发文本、失败不写状态、所有日志和输出里不出现地址和密钥、手册链接的锚点。
# 名字可换：TEST_RUNNER_NAME、TEST_HOST、TEST_REPO（默认 ci-1、ubuntu-4gb-hel1-1、owner/repo）。
# 样张里的路径换成机器上的：日志 /var/log/ci-health.log、凭据 /etc/ci-health.env、runner /opt/actions-runner，
# 手册仓库目录用 SAMPLE_PLAYBOOK_DIR（默认 /root/self-hosted-runner-playbook）。
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
BAD_HOOK_ID="bad-hook-id-$RANDOM$RANDOM"
PASS=0; FAIL=0
ok(){ PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
no(){ FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# ---- 渲染：和 bootstrap.sh 一样替换两个占位符；手册仓库目录里放一个 verify.sh，卡片才会写出完整路径 ----
PB_T="$T/pb"; mkdir -p "$PB_T/scripts"; : > "$PB_T/scripts/verify.sh"
sed -e "s#__RUNNER_SVC__#${SVC_T}#" -e "s#__PLAYBOOK_DIR__#${PB_T}#" "$SRC" > "$T/ci-health.sh"; chmod 0755 "$T/ci-health.sh"
# 只替换服务名的一份：模拟旧的渲染方式，卡片里改写「装机用的手册仓库」
sed "s#__RUNNER_SVC__#${SVC_T}#" "$SRC" > "$T/ci-health-nodir.sh"; chmod 0755 "$T/ci-health-nodir.sh"
SCRIPT="$T/ci-health.sh"

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
    *workflow_runs*)
      [ -n "${FAKE_JOBS_STDERR:-}" ] && { printf "Traceback (most recent call last):\n  File \"<stdin>\", line 9\n%s\n\n" "$FAKE_JOBS_STDERR" >&2; exit 1; }
      [ -n "${FAKE_JOBS:-}" ] && { echo "$FAKE_JOBS"; exit 0; } ;;
    *"range(180000)"*)
      [ "${FAKE_FIXEDWORK:-}" = crash ] && { printf "Traceback (most recent call last):\nMemoryError: boom\n" >&2; exit 1; }
      [ -n "${FAKE_FIXEDWORK:-}" ] && { echo "$FAKE_FIXEDWORK"; exit 0; } ;;
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
        status, _, code = (codes[0] if codes else "0").rpartition(":")
        if code == "-":
            out = b"<html>bad gateway</html>"
        else:
            out = json.dumps({"code": int(code), "msg": "success" if code == "0" else "fail", "data": {}}).encode()
        self.send_response(int(status or 200))
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
    CI_RUNNER_ENV="$T/ci-runner.env" CI_HEALTH_IDLE_WAIT=1 "$@" bash "$SCRIPT"
}
nreq(){ find "$T/srv" -name 'req.*.json' | wc -l | tr -d ' '; }
keys(){ cat "$T/state/keys" 2>/dev/null; }
# check <请求序号> <说明> <python 表达式>：b 是请求体，c 是卡片，m 是卡片正文，h 是头部，raw 是原始字节，
# heads 是正文里的四级标题，sub 是副标题，todos 是各个先做什么的内容，root_ok() 核 root 那句的位置
check(){
  local f="$T/srv/req.$1.json"
  if [ ! -f "$f" ]; then no "$2（没有第 $1 个请求）"; return; fi
  if SECRET="$SECRET_T" DEBUG_CARDS="${DEBUG_CARDS:-}" "$REAL_PY" -I - "$f" "$3" <<'PY'
import base64, hashlib, hmac, json, os, re, sys, time
raw = open(sys.argv[1], "rb").read()
b = json.loads(raw)
c = b.get("card") or {}
h = c.get("header") or {}
m = "\n".join(e.get("content", "") for e in (c.get("body") or {}).get("elements", []))
heads = [l for l in m.split("\n") if l.startswith("#### ")]
sub = (h.get("subtitle") or {}).get("content")
ROOT = "以下在这台上用 root 跑"
todos = [t.split("\n\n**")[0].split("\n\n#### ")[0] for t in re.split(r"(?:\*\*先做什么\*\*|#### \d+\. 先做什么)\n", m)[1:]]
def root_ok():   # 每个先做什么都以 root 那句开头；第 1 步不用登机时，root 那句在第 2 步里
    return bool(todos) and all(t.startswith(ROOT) or ROOT not in t.split("\n2. ")[0] and ROOT in t.split("\n2. ")[1].split("\n")[0]
                               for t in todos)
def signed():
    ts = b.get("timestamp", "")
    want = base64.b64encode(hmac.new(("%s\n%s" % (ts, os.environ["SECRET"])).encode(), b"", hashlib.sha256).digest()).decode()
    return ts.isdigit() and abs(time.time() - int(ts)) < 120 and b.get("sign") == want
if eval(sys.argv[2]):
    sys.exit(0)
if os.environ.get("DEBUG_CARDS"):   # 排查用：失败时把标题、副标题和正文打出来
    print(h, "\n" + m, file=sys.stderr)
sys.exit(1)
PY
  then ok "$2"; else no "$2"; fi
}
save_sample(){ [ -n "${SAMPLES_DIR:-}" ] || return 0; mkdir -p "$SAMPLES_DIR"
  "$REAL_PY" -I -c 'import json,sys; c=json.load(open(sys.argv[1]))["card"]; json.dump(c, open(sys.argv[2],"w"), ensure_ascii=False, indent=2)' \
    "$T/srv/req.$1.json" "$SAMPLES_DIR/$2"
  sed -i -e "s#$T/ci-health.log#/var/log/ci-health.log#g" -e "s#$T/ci-health.env#/etc/ci-health.env#g" \
    -e "s#$T/runner#/opt/actions-runner#g" -e "s#$PB_T#${SAMPLE_PLAYBOOK_DIR:-/root/self-hosted-runner-playbook}#g" "$SAMPLES_DIR/$2"; }
# 每组开始前清掉状态和请求；日志攒进 all.log，最后一组查全程有没有漏出地址和密钥
reset_state(){ [ -f "$T/ci-health.log" ] && cat "$T/ci-health.log" >> "$T/all.log"
  rm -rf "$T/state" "$T/srv"/req.*.json "$T/ci-health.log"; : > "$T/srv/codes"; }
LOG_T="$T/ci-health.log"
DOC_T="https://github.com/F-WORKS-FBY/self-hosted-runner-playbook/blob/main"
VCMD_T="\`bash $PB_T/scripts/verify.sh\`"
ROOT_T="以下在这台上用 root 跑"

echo "== 1. 没配推送地址：只记日志，不发"
write_env; reset_state
run_health FAKE_AVAIL=21300; rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || no "退出码 $rc"
[ "$(nreq)" = 0 ] && ok "没有请求" || no "发了 $(nreq) 个请求"
grep -q 'WARN 根分区可用 21300MB < 21504MB（整点量时没有 job 在跑）。containerd' "$LOG_T" && ok "日志记一行文本，不写 GC 怎样" || no "日志里没有那行文本"

echo "== 2. WARN 磁盘：橙色卡片，四节，签名对"
write_env "$HOOK" "$SECRET_T"; reset_state
run_health FAKE_AVAIL=21300
check 1 "msg_type 是 interactive，schema 2.0" 'b["msg_type"] == "interactive" and c["schema"] == "2.0"'
check 1 "timestamp、sign 在顶层且签名对" 'signed()'
check 1 "标题带级别和最严重那条" 'h["title"] == {"tag": "plain_text", "content": "[CI runner 告警] '"$RUNNER_NAME_T"'：WARN 根分区可用空间偏低"}'
check 1 "副标题是条数和变化，不放主机名" 'sub == "WARN 1 条 · 新出现"'
check 1 "颜色 orange" 'h["template"] == "orange"'
check 1 "预览文字就是标题" 'c["config"]["summary"]["content"] == h["title"]["content"]'
check 1 "四节依次是情况、影响、先做什么、去哪看" 'heads == ["#### 1. 情况", "#### 2. 影响", "#### 3. 先做什么", "#### 4. 去哪看"]'
check 1 "数字照报，WARN 线不带括号" '"**21300 MB**，低于 WARN 线 21504 MB\n" in m and "GiB" not in m'
check 1 "写明整点量时没有 job 在跑" '"\n- 整点量时没有 job 在跑\n" in m'
check 1 "已用分项" '"- 根分区已用：containerd 32339 MB，/tmp 1411 MB，其他 18370 MB\n" in m'
check 1 "影响：Min Free 第一次出现时说明是 BuildKit 的保底线" '"\n#### 2. 影响\nCI 照常跑；可用空间降到 BuildKit 的保底线 Min Free 以下时，它才会删构建缓存" in m and m.count("Min Free") == 1'
check 1 "先做什么：root 那句加前提在前，再是有序列表" '"#### 3. 先做什么\n'"$ROOT_T"'，先 `pgrep -x Runner.Worker` 没输出（没有 job 在跑）再删：\n\n1. `docker images`" in m and "\n3. " in m and "\n4. " not in m and root_ok()'
check 1 "去哪看链到手册公开仓库，锚点已编码" '"('"$DOC_T"'/08-%E8%BF%90%E7%BB%B4%E4%B8%8E%E5%AE%B9%E9%87%8F.md#82-%E7%A3%81%E7%9B%98" in m'
check 1 "采样记录在去哪看里" 'm.endswith("\n- 这台的采样记录：`tail -20 '"$LOG_T"'`")'
check 1 "正文不出现章节号，也不出现「本机」" '"08 章" not in m and "8.2" not in m and "A22" not in m and "本机" not in m'
check 1 "请求体小于 19000 字节" 'len(raw) < 19000'
[ "$(keys)" = "disk_warn " ] && ok "状态文件记下 disk_warn" || no "状态文件是「$(keys)」"
save_sample 1 pb-warn-disk.json

echo "== 2b. 正常时的采样行：fixedwork 只写一次秒数"
reset_state
run_health FAKE_AVAIL=999999 FAKE_FIXEDWORK=2.100
grep ' fixedwork=' "$LOG_T" | tail -1 | grep -q ' fixedwork=2.100s root_avail=' \
  && ok "采样行是 fixedwork=2.100s" || no "采样行不对：$(grep ' fixedwork=' "$LOG_T" | tail -1)"

echo "== 3. 告警没变：不重复发"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 1 ] && ok "没有新请求" || no "又发了（共 $(nreq) 个）"

echo "== 4. 满 24 小时：再提醒一次"
touch -d '25 hours ago' "$T/state/keys"
run_health FAKE_AVAIL=21300
check 2 "副标题写明是 24 小时提醒" 'sub == "WARN 1 条 · 超过 24 小时未消除，再提醒一次"'

echo "== 5. CRIT 连续失败 + 原有的 WARN：红色，按条分节，新的标出来"
run_health FAKE_AVAIL=21300 FAKE_JOBS=streak=4
check 3 "颜色 red" 'h["template"] == "red"'
check 3 "标题取最严重那条，带次数，逗号后注明几条" 'h["title"]["content"] == "[CI runner 告警] '"$RUNNER_NAME_T"'：CRIT 本机 job 连续失败 4 次，等 2 条"'
check 3 "副标题：各级条数与变化" 'sub == "CRIT 1 条、WARN 1 条 · 新出现 1 条"'
check 3 "每条一节，CRIT 在前，新出现的标（新），采样记录不单独成节" 'heads == ["#### 1. CRIT 本机 job 连续失败 4 次（新）", "#### 2. WARN 根分区可用空间偏低"]'
check 3 "节内情况、影响、先做什么、去哪看各自另起一行" 'all(m.count(x) == 2 for x in ("**情况**\n- ", "**影响**\n", "**先做什么**\n", "**去哪看**\n- ")) and "**影响**：" not in m'
check 3 "采样记录放在最后一行" 'm.endswith("\n\n这台的采样记录：`tail -20 '"$LOG_T"'`")'
check 3 "连续失败次数" '"这台上的 job 从最近一次往回数连续失败 **4 次**（被取消的 run 不算，满 3 次就报）" in m'
check 3 "先看 GitHub 上红在哪一步，再登机用 root 跑 verify.sh" 'm.index("1. 打开下面的 GitHub Actions") < m.index("2. '"$ROOT_T"'：'"$VCMD_T"'") and root_ok()'
check 3 "附 GitHub Actions 链接和钩子强加 -e 那一篇" '"(https://github.com/'"$REPO_T"'/actions)" in m and "#a11-runner-" in m'
save_sample 3 pb-mixed.json

echo "== 6. 磁盘那条消除、连续失败还在：单条格式，写明同时消除"
run_health FAKE_JOBS=streak=5
check 4 "副标题：消除 1 条" 'sub == "CRIT 1 条 · 消除 1 条"'
check 4 "情况里列出同时消除的那条" '"- 同时消除：WARN 根分区可用空间偏低" in m'
check 4 "单条格式四节" 'm.startswith("#### 1. 情况\n") and "#### 4. 去哪看" in m'

echo "== 7. 全部消除：绿色恢复卡，列出之前的告警和当时的先做什么"
printf 'disk_warn streak ' > "$T/state/keys"
run_health
check 5 "颜色 green" 'h["template"] == "green"'
check 5 "标题；副标题是之前的条数，不重复「已恢复」" 'h["title"]["content"] == "[CI runner 恢复] '"$RUNNER_NAME_T"'：告警已全部消除" and sub == "之前 CRIT 1 条、WARN 1 条"'
check 5 "列出消除的告警（CRIT 在前）" '"#### 1. 情况\n之前的告警这次都没再出现：\n- CRIT 本机 job 连续失败\n- WARN 根分区可用空间偏低\n\n#### 2. 要不要处理\n" in m'
check 5 "要不要处理：不说「不用」，说明没再报不代表查清" '"#### 2. 要不要处理\n这次整点检查没再报，不代表原因查清了。告警时的这几步没做完的，接着做：" in m and "不用" not in m'
check 5 "按条列出当时的先做什么" '"\n\n**CRIT 本机 job 连续失败**\n1. 打开下面的 GitHub Actions" in m and "\n\n**WARN 根分区可用空间偏低**\n'"$ROOT_T"'，先" in m'
check 5 "去哪看有两条的手册链接和采样记录" '"#a11-runner-" in m and "#82-%E7%A3%81%E7%9B%98" in m and m.endswith("这台的采样记录：`tail -20 '"$LOG_T"'`")'
[ -z "$(keys)" ] && ok "状态文件清空" || no "状态文件是「$(keys)」"
save_sample 5 pb-recover.json

echo "== 8. 单条 CRIT 连续失败（样张）：verify.sh 写完整路径"
reset_state
run_health FAKE_JOBS=streak=3
check 1 "红色，单条四节，标题带次数" 'h["template"] == "red" and heads == ["#### 1. 情况", "#### 2. 影响", "#### 3. 先做什么", "#### 4. 去哪看"] and h["title"]["content"].endswith("：CRIT 本机 job 连续失败 3 次")'
check 1 "情况里不重复 runner 名" '"#### 1. 情况\n- 这台上的 job 从最近一次往回数连续失败 **3 次**（被取消的 run 不算，满 3 次就报）\n\n" in m'
check 1 "第 1 步看 GitHub，怎么认出这台单独成句" '"\n1. 打开下面的 GitHub Actions，看落在这台的 job 红在哪一步、几次是不是同一处。job 日志开头 Set up job 里 Runner name 是 `'"$RUNNER_NAME_T"'` 的，就是落在这台的\n" in m'
check 1 "第 2 步先写 root 那句，再跑这台上的 verify.sh，看钩子那一行" '"\n2. '"$ROOT_T"'：'"$VCMD_T"'，看带 `清理钩子` 和 `bash -e` 的那一行是 PASS 还是 FAIL。" in m and root_ok()'
check 1 "有 job 时会跳过并进第 2 步，照原文；只有 2 步" '"。有 job 在跑时这一项会跳过，那一行换成 `有 job 正在运行，跳过钩子实跑`，等 `pgrep -x Runner.Worker` 没输出再跑\n" in m and "\n3. " not in m'
save_sample 1 pb-crit-streak.json
# 卡片里引用的 verify.sh 原文要和脚本对得上
grep -q 'ok "清理钩子按 runner 的调用方式（bash -e）可正常退出"' "$HERE/../verify.sh" \
  && grep -q 'no "清理钩子在 bash -e 下非零退出' "$HERE/../verify.sh" \
  && grep -q 'sk "有 job 正在运行，跳过钩子实跑' "$HERE/../verify.sh" \
  && grep -q 'ok "Runner.Listener 在跑' "$HERE/../verify.sh" \
  && ok "卡片引用的 verify.sh 输出与脚本原文一致" || no "verify.sh 的输出原文变了，卡片要跟着改"
# 卡片让人去跑 verify.sh：它的根分区那一项也只报数，不替人下结论（09 章 B20）
grep -q 'no "根分区可用 ${av}MB，低于 CRIT 线 ${CRIT_MB}MB。' "$HERE/../verify.sh" && ! grep -q 'GC 腾不出\|GC 已在按' "$HERE/../verify.sh" \
  && ok "verify.sh 的根分区那一项只报数" || no "verify.sh 的根分区那一项又写了原因"

echo "== 9. 手册仓库目录没渲染或不在了：写「装机用的手册仓库」"
reset_state; SCRIPT="$T/ci-health-nodir.sh"
run_health FAKE_JOBS=streak=3
check 1 "改写成装机用的手册仓库" '"\n2. '"$ROOT_T"'：装机用的手册仓库里的 `scripts/verify.sh`，看" in m and "__PLAYBOOK" not in m'
SCRIPT="$T/ci-health.sh"

echo "== 10. 多条混合 + 外来字符：转义、排序、体积"
reset_state
printf 'RUNNER_HOME=%s\nCI_FIXEDWORK_BASELINE=2.000\nCI_DISK_WARN_MB=3`0*G_[x](y)<at id=all></at>\nCI_DISK_CRIT_MB=10240\n' "$T/runner" > "$T/ci-runner.env"
run_health FAKE_AVAIL=5500 FAKE_TMP_DEV=40 FAKE_SVC_STATE=failed FAKE_FIXEDWORK=3.300 FAKE_JOBS=streak=6
check 1 "CRIT 在前（磁盘、服务、连续失败），WARN 在后（CPU、配置）" '[l.split(" ", 3)[2] for l in heads] == ["CRIT", "CRIT", "CRIT", "WARN", "WARN"]'
check 1 "标题注明 5 条" 'h["title"]["content"] == "[CI runner 告警] '"$RUNNER_NAME_T"'：CRIT 根分区快满了，等 5 条" and sub == "CRIT 3 条、WARN 2 条 · 新出现"'
check 1 "5 条的先做什么都有 root 那句，位置对" 'len(todos) == 5 and root_ok()'
check 1 "配置原值进代码样式：没有反引号、拼不出 <at>" '"<at" not in m and "`CI_DISK_WARN_MB=3'"'"'0*G_[x](y)＜at id=all＞＜/at＞`" in m'
check 1 "/tmp 不在根分区时单列" '"根分区已用：containerd 32339 MB，其他 19781 MB；不在根分区的：/tmp 1411 MB" in m'
check 1 "服务状态在情况里，服务名在命令里" '"runner 服务当前是 `failed`，不是 active" in m'
check 1 "runner 三步：先在群里问，再登机用 root 看日志，处理完启动、跑 verify" '"\n1. 先在群里问一声是不是有人在维护这台：重启、升级前都会先停服务\n2. 没人在维护的话，'"$ROOT_T"'：`journalctl -u '"$SVC_T"' -n 50` 看原因\n3. 处理完 `systemctl start '"$SVC_T"'`，起来以后跑 '"$VCMD_T"'\n\n**去哪看**" in m'
check 1 "CPU 倍数" '"**3.300 秒**，这台的基线 2.000 秒，是基线的 1.65 倍" in m'
check 1 "请求体小于 19000 字节" 'len(raw) < 19000'
printf 'RUNNER_HOME=%s\nCI_FIXEDWORK_BASELINE=2.000\nCI_DISK_WARN_MB=21504\nCI_DISK_CRIT_MB=10240\n' "$T/runner" > "$T/ci-runner.env"

echo "== 11. listener 反复崩溃、job 采样 401"
reset_state
run_health FAKE_LISTENER_AGE=5 FAKE_JOBS=error:HTTP401
check 1 "listener：两次都是刚启动" '"- 隔 90 秒看了两次，都是刚启动（第二次 5 秒）" in m and "`journalctl -u '"$SVC_T"' -n 50`" in m'
check 1 "listener：root 那句在前，处理完再跑 verify.sh 看 Runner.Listener 那一行" '"**先做什么**\n'"$ROOT_T"'：\n\n1. `journalctl -u" in m and "处理完再跑 '"$VCMD_T"'，要有一行 `Runner.Listener 在跑`" in m'
check 1 "jobsprobe：401 单独写成 token 失效" '"GitHub 回了 `HTTP401`：token 失效（过期、被撤销或写错）\n" in m and "仓库名" not in m'
check 1 "jobsprobe：401 第 1 步直接找人建 token，root 那句在第 2 步" '"\n1. 找有仓库管理权限的人建只读 token（fine-grained，只授权这个仓库，Actions 只读）\n2. '"$ROOT_T"'：把新 token 写进 `'"$T"'/ci-health.env` 的 `CI_HEALTH_GH_TOKEN=`\n3. 下一小时" in m and root_ok()'
check 1 "jobsprobe：用 grep 看 jobs=，不用 tail -1" '"`grep -o '"'"'jobs=[^ ]*'"'"' '"$LOG_T"' | tail -3`" in m and "tail -1" not in m'

echo "== 12. job 采样 404：并进 token 没权限或仓库名不对"
reset_state
run_health FAKE_JOBS=error:HTTP404
check 1 "404 也给核仓库名、换 token 的步骤" '"GitHub 回了 `HTTP404`：token 失效、没权限或仓库名不对" in m and "#b12-" in m'
check 1 "404：root 那句在前，先核仓库名，再找人建 token" '"#### 3. 先做什么\n'"$ROOT_T"'：\n\n1. 先核仓库名：`'"$T"'/ci-health.env` 里 `GH_REPO=` 现在是 `'"$REPO_T"'`\n2. 仓库名没错，就找有仓库管理权限的人建只读 token（fine-grained，只授权这个仓库，Actions 只读），写进同一个文件的 `CI_HEALTH_GH_TOKEN=`\n" in m'

echo "== 13. job 采样连不上：只写原因见日志，日志里有原因"
reset_state
run_health FAKE_JOBS=$'error:URLError\n[Errno -3] Temporary failure in name resolution'
check 1 "情况里是出错类型，不猜原因" '"统计这台 job 结果时出错（`URLError`）" in m and "网络" not in m and "多半" not in m'
check 1 "第 1 步：原因见日志" '"\n1. 原因见日志：`grep 采样失败 '"$LOG_T"' | tail -3`\n2. 下一小时会自动再试，`jobs=` 变回 `streak=数字` 就好了" in m and root_ok()'
grep -q 'jobs=error:URLError mem_peak' "$LOG_T" && grep -q 'WARN job 产出采样失败（URLError：\[Errno -3\] Temporary failure in name resolution），「本机 job 连续失败」这一项现在看不到' "$LOG_T" \
  && ok "采样行只记类型，告警行带原因" || no "日志里的采样行或告警行不对"

echo "== 14. job 采样脚本自己崩了：卡片写原因见日志，日志里是 stderr 最后一行，截 200 字、不带 token"
reset_state
run_health FAKE_JOBS_STDERR="RuntimeError: boom Bearer fake-read-only $(printf 'x%.0s' $(seq 300))"
check 1 "python 出错：原因见日志" '"统计这台 job 结果时出错（`python`）" in m and "原因见日志" in m and "网络" not in m'
"$REAL_PY" -I - "$LOG_T" <<'PY' && ok "日志里有原因：stderr 最后一行，token 换成 <已隐去>，截 200 字" || no "日志里的原因不对：$(grep 采样失败 "$LOG_T")"
import sys
line = [l for l in open(sys.argv[1], encoding="utf-8") if "job 产出采样失败（python：" in l][0]
why = line.split("python：", 1)[1].split("），「本机", 1)[0]
sys.exit(0 if why.startswith("RuntimeError: boom Bearer <已隐去> xxx") and len(why) <= 200 and "fake-read-only" not in line else 1)
PY

echo "== 14b. job 采样抛出别的异常（token 里夹着回车，请求头不合法）：日志带异常文本，token 换成 <已隐去>"
# 走真的采样代码：http.client 在连网之前就拒掉这个请求头；万一连了，也只会连到 127.0.0.1:9 的代理上
reset_state
TOK_A="tokpart-$RANDOM$RANDOM"; TOK_B="secretpart-$RANDOM$RANDOM"
{ echo "GH_REPO=$REPO_T"; printf 'CI_HEALTH_GH_TOKEN=%s\r%s\n' "$TOK_A" "$TOK_B"; echo "CI_ALERT_WEBHOOK=$HOOK"; echo "CI_ALERT_SECRET=$SECRET_T"; } > "$T/ci-health.env"
run_health FAKE_JOBS= https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
check 1 "情况里是异常类型" '"统计这台 job 结果时出错（`ValueError`）" in m'
grep -q 'jobs=error:ValueError mem_peak' "$LOG_T" && grep -q 'WARN job 产出采样失败（ValueError：.*<已隐去>.*），「本机 job 连续失败」这一项现在看不到' "$LOG_T" \
  && ok "告警行带异常文本，token 已隐去" || no "日志不对：$(grep 采样失败 "$LOG_T")"
grep -qF -e "$TOK_A" -e "$TOK_B" "$LOG_T" "$T/fake/journal" && no "日志里出现了 token" || ok "日志和 journal 里没有 token"
write_env "$HOOK" "$SECRET_T"

echo "== 15. 上次报连续失败、这次采样出错：连续失败那条看不到了，不算消除（样张）"
reset_state; mkdir -p "$T/state"; printf 'streak ' > "$T/state/keys"
run_health FAKE_JOBS=error:HTTP401
check 1 "副标题：新出现 1 条，1 条看不到了，没有消除" 'sub == "WARN 1 条 · 新出现 1 条，1 条看不到了" and "消除" not in sub'
check 1 "情况里写明看不到了、不算消除，不再出通用那一句" '"\n- 上次报的「CRIT 本机 job 连续失败」看不到了，不算消除\n" in m and "同时消除" not in m and "这一项现在看不到" not in m'
[ "$(keys)" = "jobsprobe " ] && ok "状态文件换成 jobsprobe" || no "状态文件是「$(keys)」"
save_sample 1 pb-streak-unseen.json

echo "== 16. 上次报 listener、这次服务不是 active：listener 那条看不到了"
reset_state; mkdir -p "$T/state"; printf 'listener ' > "$T/state/keys"
run_health FAKE_SVC_STATE=failed
check 1 "情况里写明 listener 那条看不到了" '"上次报的「CRIT runner 没在接 job」看不到了（服务不是 active 时不查这一项），不算消除" in m and sub == "CRIT 1 条 · 新出现 1 条，1 条看不到了"'

echo "== 16b. 上次报连续失败、这次没配 token（jobs=skip）：只剩看不到了，发橙色告警卡，不发恢复卡（样张）"
reset_state; mkdir -p "$T/state"; printf 'streak ' > "$T/state/keys"
{ echo "CI_ALERT_WEBHOOK=$HOOK"; echo "CI_ALERT_SECRET=$SECRET_T"; } > "$T/ci-health.env"
run_health
check 1 "橙色告警卡，标题写看不到了，副标题只有变化" 'h["template"] == "orange" and h["title"]["content"] == "[CI runner 告警] '"$RUNNER_NAME_T"'：「CRIT 本机 job 连续失败」看不到了" and sub == "1 条看不到了"'
check 1 "单条四节，情况写明为什么看不到、不算消除" 'heads == ["#### 1. 情况", "#### 2. 影响", "#### 3. 先做什么", "#### 4. 去哪看"] and "\n- `'"$T"'/ci-health.env` 里没有只读 token 或 `GH_REPO=`，这一项没在查\n- 上次报的「CRIT 本机 job 连续失败」看不到了，不算消除\n" in m and "恢复" not in m'
check 1 "先做什么：root 那句开头，补回两行，token 找人建" '"#### 3. 先做什么\n'"$ROOT_T"'：\n\n1. 看 `'"$T"'/ci-health.env` 里 `GH_REPO=`、`CI_HEALTH_GH_TOKEN=` 两行还在不在\n2. 少了哪行补哪行；没有 token 就找有仓库管理权限的人建只读 token" in m and root_ok()'
[ -z "$(keys)" ] && ok "推送后状态文件清空" || no "状态文件是「$(keys)」"
save_sample 1 pb-unseen-skip.json
run_health
[ "$(nreq)" = 1 ] && ok "下一小时照旧没配 token：不再推" || no "又发了（共 $(nreq) 个）"
reset_state; mkdir -p "$T/state"; printf 'streak ' > "$T/state/keys"; echo "11246 0" > "$T/srv/codes"
run_health
check 2 "卡片被拒时的文本消息也写看不到了，不写已全部消除" 'b["msg_type"] == "text" and b["content"]["text"] == "[CI runner 告警] '"$RUNNER_NAME_T"'（'"$HOST_T"'）\n· 上次报的「本机 job 连续失败」这次看不到了（没配只读 token 或 GH_REPO，不查这一项），不算消除"'
write_env "$HOOK" "$SECRET_T"

echo "== 16b2. 上次报读不到 job 结果、这次没配 token（jobs=skip）：那条也看不到了，不发恢复卡"
reset_state; mkdir -p "$T/state"; printf 'jobsprobe ' > "$T/state/keys"
{ echo "CI_ALERT_WEBHOOK=$HOOK"; echo "CI_ALERT_SECRET=$SECRET_T"; } > "$T/ci-health.env"
run_health
check 1 "橙色告警卡，标题写「读不到本机 job 结果」看不到了" 'h["template"] == "orange" and h["title"]["content"].endswith("：「WARN 读不到本机 job 结果」看不到了") and sub == "1 条看不到了"'
write_env "$HOOK" "$SECRET_T"

echo "== 16c. 上次报 CPU 变慢、这次定长任务崩了，同时新出现磁盘 WARN：CPU 那条单列一节标看不到了"
reset_state; mkdir -p "$T/state"; printf 'contention ' > "$T/state/keys"
run_health FAKE_AVAIL=21300 FAKE_FIXEDWORK=crash
check 1 "标题取告警那条，逗号后注明 2 条；副标题不算消除" 'h["title"]["content"].endswith("：WARN 根分区可用空间偏低，等 2 条") and sub == "WARN 1 条 · 新出现 1 条，1 条看不到了"'
check 1 "看不到了的那条单列一节，在告警后面" 'heads == ["#### 1. WARN 根分区可用空间偏低（新）", "#### 2. WARN CPU 变慢 看不到了"] and "- 定长任务这次没跑出结果，这一项没在查\n- 上次报的「WARN CPU 变慢」看不到了，不算消除" in m'
check 1 "先做什么：原因见日志，两节都有 root 那句" '"1. 原因见日志：`grep 定长任务没跑出结果 '"$LOG_T"' | tail -3`" in m and len(todos) == 2 and root_ok()'
grep -q ' fixedwork=n/a root_avail=' "$LOG_T" && grep -q 'WARN 定长任务没跑出结果（MemoryError: boom），这一小时不判 vCPU 争抢' "$LOG_T" \
  && ok "采样行记 fixedwork=n/a，另一行写原因" || no "日志不对：$(head -3 "$LOG_T")"
[ "$(keys)" = "disk_warn " ] && ok "状态文件只剩 disk_warn" || no "状态文件是「$(keys)」"

echo "== 17. 磁盘 WARN 在两个 job 之间量"
reset_state
run_health FAKE_AVAIL=20000 FAKE_WORKER_BUSY_CALLS=1 FAKE_AVAIL_IDLE=21000
check 1 "写明两个 job 之间量的值和整点值" '"两个 job 之间量的根分区可用 **21000 MB**，低于 WARN 线 21504 MB" in m and "- 整点时有 job 在跑，当时可用 20000 MB\n- 整点时根分区已用：" in m and "整点量时没有" not in m'

echo "== 18. 一直有 job：沿用上一次的 WARN"
printf 'disk_warn ' > "$T/state/keys"; touch -d '25 hours ago' "$T/state/keys"
run_health FAKE_AVAIL=20000 FAKE_WORKER_BUSY_CALLS=999999
check 2 "写明沿用上一次" '"沿用上一次的 WARN" in m'

echo "== 19. 限流：等一会儿、重新签名再发一次"
reset_state; echo "11232 0" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 2 ] && ok "发了两次" || no "发了 $(nreq) 次"
check 2 "第二次签名也对" 'signed() and b["msg_type"] == "interactive"'
[ "$(keys)" = "disk_warn " ] && ok "成功后写状态" || no "状态文件是「$(keys)」"

echo "== 20. 卡片被拒（11246）：改发文本，日志记一行"
reset_state; echo "11246 0" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
check 2 "第二次是原来的文本消息" 'b["msg_type"] == "text" and b["content"]["text"].startswith("[CI runner 告警] '"$RUNNER_NAME_T"'（'"$HOST_T"'）\n· WARN 根分区可用 21300MB") and signed()'
grep -q '告警卡片被飞书拒收（11246' "$LOG_T" && ok "日志记了卡片被拒" || no "日志里没有卡片被拒"
[ "$(keys)" = "disk_warn " ] && ok "文本发成功也写状态" || no "状态文件是「$(keys)」"

echo "== 21. 请求体格式不对（9499）：同样改发文本"
reset_state; echo "9499 0" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
check 2 "第二次是文本" 'b["msg_type"] == "text"'
grep -q '告警卡片被飞书拒收（9499，请求体格式不对' "$LOG_T" && ok "日志记了 9499" || no "日志里没有 9499"

echo "== 22. HTTP 400 带 JSON 返回体（走 HTTPError 那条路）：照样按 code 判"
reset_state; echo "400:9499 0" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 2 ] && ok "卡片被拒后改发文本" || no "发了 $(nreq) 次"
grep -q '告警卡片被飞书拒收（9499' "$LOG_T" && [ "$(keys)" = "disk_warn " ] && ok "日志记了拒收，文本发成功后写状态" || no "日志或状态不对：「$(keys)」"

echo "== 23. HTTP 502、返回体不是 JSON：记失败，不写状态"
reset_state; echo "502:-" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
grep -q '告警推送失败：HTTP 502，返回体认不出：<html>bad gateway</html>' "$LOG_T" && ok "日志写明状态码和返回体" || no "日志里没有 502"
[ ! -s "$T/state/keys" ] && ok "没写状态" || no "状态文件是「$(keys)」"

echo "== 24. 签名错（19021）：记失败，不写状态，下一小时重发"
reset_state; echo "19021" > "$T/srv/codes"
run_health FAKE_AVAIL=21300
grep -q '告警推送失败：飞书返回 19021（签名或时间戳不对' "$LOG_T" && ok "日志写明返回码和原因" || no "日志里没有失败原因"
[ ! -s "$T/state/keys" ] && ok "没写状态" || no "状态文件是「$(keys)」"
run_health FAKE_AVAIL=21300
[ "$(nreq)" = 2 ] && [ "$(keys)" = "disk_warn " ] && ok "下一次重发并成功" || no "请求 $(nreq) 个，状态「$(keys)」"

echo "== 25. 地址连不上：记失败，不写状态"
write_env "http://127.0.0.1:9/open-apis/bot/v2/hook/test-hook-id" "$SECRET_T"; reset_state
run_health FAKE_AVAIL=21300
grep -q '告警推送失败：请求失败' "$LOG_T" && ok "日志写明请求失败" || no "日志里没有请求失败"
[ ! -s "$T/state/keys" ] && ok "没写状态" || no "状态文件是「$(keys)」"

echo "== 26. 地址写错（没有 https://）：报错里不带地址"
write_env "open.feishu.invalid/open-apis/bot/v2/hook/$BAD_HOOK_ID" "$SECRET_T"; reset_state
run_health FAKE_AVAIL=21300
grep -q '告警推送失败：请求失败：ValueError: unknown url type' "$LOG_T" && ok "日志写明地址格式不对" || no "日志里没有 ValueError：$(tail -1 "$LOG_T")"
grep -qF -e "$BAD_HOOK_ID" -e "open.feishu.invalid" "$LOG_T" && no "日志里出现了推送地址" || ok "日志里地址换成了 <已隐去>"

echo "== 27. 没配签名密钥：不带 timestamp、sign"
write_env "$HOOK"; reset_state
run_health FAKE_AVAIL=21300
check 1 "请求体里没有 timestamp、sign" '"timestamp" not in b and "sign" not in b and b["msg_type"] == "interactive"'
write_env "$HOOK" "$SECRET_T"

echo "== 28. 没写文案的 key（以后新加的检查）：照样送达，原文转义后放进情况"
# 直接跑 notify() 里那段 python，喂一条 ci-health 现在不会产生的 key
awk '/^notify\(\)\{/{n=1} n&&/^PY$/{exit} n>1{print} n&&/<<.PY. 2>&1$/{n=2}' "$T/ci-health.sh" > "$T/notify.py"
reset_state
CARD_KIND=alert CARD_TEXT="[CI runner 告警] x" CARD_RUNNER="$RUNNER_NAME_T" CARD_HOST="$HOST_T" CARD_LOG=/var/log/ci-health.log \
  CARD_ALERTS="$(printf 'newcheck\tWARN\ttext=WARN 新检查 *x* [a](b) <at id=all></at>')" CARD_PREV="" CARD_DOC=https://example.invalid \
  CI_ALERT_WEBHOOK="$HOOK" CI_ALERT_SECRET="$SECRET_T" "$REAL_PY" -I "$T/notify.py" > "$T/out.28.txt"; rc=$?
[ "$rc" = 0 ] && ok "退出码 0" || no "退出码 $rc"
check 1 "标题用级别和 key 本身" 'h["title"]["content"] == "[CI runner 告警] '"$RUNNER_NAME_T"'：WARN newcheck"'
check 1 "原文转义后放进情况，拼不出链接和 @" '"- WARN 新检查 &#42;x&#42; &#91;a&#93;&#40;b&#41; &#60;at id=all&#62;&#60;/at&#62;" in m and "<at" not in m'

echo "== 29. 卡片拼装出错：改发文本"
reset_state
CARD_KIND=alert CARD_TEXT="[CI runner 告警] x" CARD_ALERTS="$(printf 'disk_warn\tWARN\tmode=now')" CARD_PREV="" CARD_DOC=x CARD_LOG=x \
  CI_ALERT_WEBHOOK="$HOOK" CI_ALERT_SECRET="$SECRET_T" "$REAL_PY" -I -c 'import sys; exec(open(sys.argv[1]).read().replace("def disk_parts(f, when=\"\"):", "def disk_parts(f, when=\"\"):\n    raise RuntimeError(\"boom\")"))' "$T/notify.py" > "$T/out.29.txt"; rc=$?
[ "$rc" = 0 ] && grep -q '告警卡片拼装出错（RuntimeError' "$T/out.29.txt" && ok "发成功并说明改发了文本" || no "退出码 $rc，输出：$(cat "$T/out.29.txt")"
check 1 "发的是文本消息" 'b["msg_type"] == "text" and b["content"]["text"] == "[CI runner 告警] x"'

echo "== 30. 卡片超过 19000 字节：改发文本"
reset_state
big=$(for i in $(seq 40); do printf 'newcheck%d\tWARN\ttext=%s\n' "$i" "$(printf '*%.0s' $(seq 400))"; done)
CARD_KIND=alert CARD_TEXT="[CI runner 告警] x" CARD_ALERTS="$big" CARD_PREV="" CARD_DOC=x CARD_LOG=x \
  CI_ALERT_WEBHOOK="$HOOK" CI_ALERT_SECRET="$SECRET_T" "$REAL_PY" -I "$T/notify.py" > "$T/out.30.txt"; rc=$?
[ "$rc" = 0 ] && grep -q '告警卡片超过 19000 字节，改发了文本' "$T/out.30.txt" && ok "发成功并说明改发了文本" || no "退出码 $rc，输出：$(cat "$T/out.30.txt")"
check 1 "只发了一次，是文本" 'b["msg_type"] == "text"'
[ "$(nreq)" = 1 ] || no "发了 $(nreq) 次"

echo "== 31. 卡片里的手册链接，锚点都在手册的章节标题里"
"$REAL_PY" -I - "$HERE/../ci-health.sh" "$HERE/../.." <<'PY' && ok "锚点都对得上" || no "有锚点在手册里找不到"
import re, sys, unicodedata
src, root = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
def slug(h):   # GitHub 的标题锚点：转小写，去掉标点和符号（- 和 _ 除外），空格换成 -
    return "".join(ch for ch in h.lower() if ch in "-_ " or unicodedata.category(ch)[0] not in "PS").replace(" ", "-")
bad = []
for path, anchor in re.findall(r'doc\("[^"]*", "([^"]+)", "([^"]+)"\)', src):
    heads = [slug(l.lstrip("#").strip()) for l in open("%s/%s" % (root, path), encoding="utf-8") if re.match(r"#{2,6} ", l)]
    if anchor not in heads:
        bad.append("%s#%s" % (path, anchor))
print("\n".join(bad), file=sys.stderr)
sys.exit(1 if bad or not re.search(r'doc\(', src) else 0)
PY

echo "== 32. bootstrap 按同样的方式渲染两个占位符，渲染后不剩占位符"
grep -q 's#__RUNNER_SVC__#${SVC:-none}#' "$HERE/../bootstrap.sh" && grep -q 's#__PLAYBOOK_DIR__#${PB_DIR}#' "$HERE/../bootstrap.sh" \
  && ok "bootstrap 替换服务名和手册仓库目录" || no "bootstrap 的渲染和用例不一致"
! grep -q '__RUNNER_SVC__\|__PLAYBOOK_DIR__' "$T/ci-health.sh" && grep -qx "PLAYBOOK_DIR=\"$PB_T\"" "$T/ci-health.sh" \
  && ok "渲染后没有占位符，目录写进去了" || no "渲染结果不对"

echo "== 33. 全程的日志、journal 和输出里没有推送地址、密钥和 token"
reset_state
if grep -rqF -e "$SECRET_T" -e "test-hook-id" -e "$BAD_HOOK_ID" -e "$TOK_A" -e "$TOK_B" "$T/all.log" "$T/fake/journal" "$T"/out.*.txt 2>/dev/null; then
  no "出现了地址或密钥"; else ok "没有地址和密钥（$(wc -l < "$T/all.log") 行日志）"; fi

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" = 0 ]
