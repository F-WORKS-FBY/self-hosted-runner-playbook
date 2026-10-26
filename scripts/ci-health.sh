#!/usr/bin/env bash
# ci-health.sh：CI 机每小时采点。由 bootstrap.sh 安装到 /usr/local/bin/。
#
# 两条规矩，都是踩过坑总结的：
#
#  ① 不能采 /proc/stat 的 steal。很多云的宿主不向 guest 暴露 KVM_FEATURE_STEAL_TIME
#     （CPUID 0x40000001 的 bit5），这时 steal 列一直是 0。那不是测出来是 0，而是根本没接线，
#     基于 %st 的告警在这种机器上永远不会响（09 章 B1）。
#     争抢改用定长任务的墙钟衡量：同样的活干一遍，被邻居抢核就会变慢。
#     （preflight.sh 会告诉你这台机器的 steal 能不能用。）
#     这个基线只对本机有效，不能拿来比较两台机器的快慢（09 章 B16）。sha256 的速度主要看 CPU 有没有
#     SHA 指令扩展，有和没有能差约 5 倍，实际单核只差约 2 倍。参考项目两台同为 EPYC 的机器，sha256 只差约 4%，
#     Python 循环却差 15% 到 25%。两个方向都会测偏。每台用自己 preflight 测的 p50；换机、换规格、
#     CPU 型号变了都要重测。比较两台机器用 machine-check.sh，或者回放最慢的 job（02 章 2.7）。
#
#  ② 磁盘要量 /var/lib/containerd。Docker 29 默认用 containerd 快照器，镜像字节不在 /var/lib/docker 里。
#     参考机实测 containerd 2.6G、docker 115M，只量后者会低估约 10 倍（09 章 A2）。
#     匿名卷在 /var/lib/docker/volumes，要单独量。
#
# 上线一个月后补的三条（2026-10-16）：
#
#  ③ 磁盘阈值要跟 BuildKit GC 对齐。缓存会长到 GC 的 Max Used（bootstrap 默认 20 GiB）才停，
#     参考机上这时可用空间稳定在约 23 GiB，这是设计稳态，不该告警。原来写死的 WARN<40G 于是从第 5 周起
#     每小时都响（一个月 309 次，没有送达任何人）；CRIT<20000 MiB 又只比 GC 的 Min Free（20 GiB）低 480 MiB。
#     现在 WARN = Min Free + 1 GiB：可用空间被别的东西挤到 Min Free 附近时，GC 开始为保底而驱逐缓存。
#     CRIT = 10 GiB。按盘大小怎么取见 10 章 10.4。
#  ④ 失败连续计数只看落在本机上的 job，按 runner 名匹配。原来统计全仓库的 run，GitHub 托管的 PR 标题检查
#     之类的失败也算进来，2026-10-08 那次 CRIT 就是这么误报的。准备加第二台机器时又改了一次：几台共用一套标签，
#     同一个 run 的 job 分在几台上，按 run 的结论算会互相背锅。读不到本机 runner 名时报错，不再退回统计全仓库。
#  ⑤ 告警要送到人。只写本机 journal 等于没告警。配了 CI_ALERT_WEBHOOK 就推送（目前只实现了飞书自定义机器人），
#     按告警集合的变化推送（新出现、全部恢复），持续存在的每 24 小时提醒一次。
#
# 2026-10-26 补的一条：
#
#  ⑥ 磁盘告警只报数，不替人下结论。原来的文案写的是「是 Docker 以外的东西在吃盘」，参考项目那次 CRIT
#     查下来，可用空间少掉的部分七成在 containerd 里：被取消的 job 留下的镜像，BuildKit GC 管不到（09 章 B20）。
#     现在告警带上 containerd、/tmp 和其余部分各占多少，采样行也多记一个 tmp=。
set -uo pipefail
LOG="${CI_HEALTH_LOG:-/var/log/ci-health.log}"
SVC="__RUNNER_SVC__"                      # 由 bootstrap.sh 替换；--skip-runner 装的机器上是 none

# 部署参数从 /etc/ci-runner.env 读回，读法和 bootstrap.sh 相同：逐行按 KEY=VALUE 解析，只认下面这几个键，不 source。
# 优先级：环境变量（cron.d 里写的那几行）> 文件 > 默认值。不读回的话，用了非默认 RUNNER_HOME 的机器读不到
# runner 名，手工运行时用的阈值也和 cron 里的不一样。
CI_RUNNER_ENV="${CI_RUNNER_ENV:-/etc/ci-runner.env}"
if [ -r "$CI_RUNNER_ENV" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; k=${line%%=*}; v=${line#*=}
    case "$k" in RUNNER_HOME|CI_FIXEDWORK_BASELINE|CI_DISK_WARN_MB|CI_DISK_CRIT_MB) [ -z "${!k+x}" ] && printf -v "$k" '%s' "$v" ;; esac
  done < "$CI_RUNNER_ENV"
fi
RUNNER_HOME="${RUNNER_HOME:-/opt/actions-runner}"
BASELINE_S="${CI_FIXEDWORK_BASELINE:-0}"  # preflight 给的 p50；为 0 则只记录不告警
WARN_MB="${CI_DISK_WARN_MB:-21504}"       # bootstrap 按 BUILDKIT_MIN_FREE + 1 GiB 写进 cron.d 和 /etc/ci-runner.env
CRIT_MB="${CI_DISK_CRIT_MB:-10240}"
STATE_DIR="${CI_HEALTH_STATE_DIR:-/var/lib/ci-health}"
# 阈值必须是 MiB 整数。写成「30G」之类会让下面的 [ -lt ] 静默失败、磁盘告警整个失效，所以改用默认值并报出来。
CFG_ERR=""
case "$WARN_MB" in ''|*[!0-9]*) CFG_ERR+=" CI_DISK_WARN_MB=$WARN_MB"; WARN_MB=21504 ;; esac
case "$CRIT_MB" in ''|*[!0-9]*) CFG_ERR+=" CI_DISK_CRIT_MB=$CRIT_MB"; CRIT_MB=10240 ;; esac

# 凭据与推送地址单独放一个 0600 的文件，不写进 /etc/cron.d/（那是 0644，全局可读）。
#   GH_REPO=owner/repo
#   CI_HEALTH_GH_TOKEN=...   job 产出采样用，只读：fine-grained、只授权这个仓库、Actions: read
#   CI_ALERT_WEBHOOK=...     可选，飞书自定义机器人地址
#   CI_ALERT_SECRET=...      可选，机器人开了「签名校验」时填
# 旧版本把注册用的 GH_TOKEN 也写进了这个文件。那通常是一个管理员级 token，
# 而 runner 在 docker 组里（约等于 root），任何 CI job 都读得到它。这里仍兼容旧变量名，
# 但应尽快换成只读的 CI_HEALTH_GH_TOKEN。见 09 章 B12。
#
# 按 KEY=VALUE 逐行读、只认下面这几个键，不 source：密钥里出现 $ ` \ 空格之类字符时，
# source 会把它们当 shell 代码解释（改写值，甚至执行）。
CI_HEALTH_ENV="${CI_HEALTH_ENV:-/etc/ci-health.env}"
if [ -r "$CI_HEALTH_ENV" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; k=${line%%=*}; v=${line#*=}
    case "$k" in GH_REPO|GH_TOKEN|CI_HEALTH_GH_TOKEN|CI_ALERT_WEBHOOK|CI_ALERT_SECRET) printf -v "$k" '%s' "$v" ;; esac
  done < "$CI_HEALTH_ENV"
fi
TOKEN="${CI_HEALTH_GH_TOKEN:-${GH_TOKEN:-}}"

t=$(python3 - <<'PY' 2>/dev/null || echo 0
import hashlib, time
blk = b'x' * 4096
t0 = time.time()
h = hashlib.sha256()
for _ in range(180000):
    h.update(blk)
h.hexdigest()
print("%.3f" % (time.time() - t0))
PY
)
avail=$(df --output=avail -BM / 2>/dev/null | tail -1 | tr -dc 0-9)
ctr=$(du -sBM /var/lib/containerd 2>/dev/null | cut -f1 | tr -dc 0-9)
# /tmp 单独量：job 被取消时，程序自己建在 /tmp 下的临时目录不会被删（09 章 A22）
tmpm=$(du -sxBM /tmp 2>/dev/null | cut -f1 | tr -dc 0-9)
used=$(df --output=used -BM / 2>/dev/null | tail -1 | tr -dc 0-9)
vol=$(du -sBM /var/lib/docker/volumes 2>/dev/null | cut -f1 | tr -dc 0-9)
run="n/a"; [ "$SVC" != "none" ] && [ -n "$SVC" ] && run=$(systemctl is-active "$SVC" 2>/dev/null)
# 内存只记录不告警：runner cgroup 自上次启动以来的峰值（含页缓存，比进程实际占用高），以及整机可用内存
mem_peak="n/a"
if [ "$SVC" != "none" ] && [ -n "$SVC" ]; then
  p=$(systemctl show "$SVC" -p MemoryPeak --value 2>/dev/null)
  case "$p" in ''|*[!0-9]*) ;; *) mem_peak="$((p / 1048576))M" ;; esac
fi
mem_avail="$(awk '/^MemAvailable:/{printf "%dM", $2/1024}' /proc/meminfo 2>/dev/null)"

# ── job 产出采样（2026-09-07 事故后补）──────────────────────────────────
#
# 上面那个 run=active 是存活指标，不是产出指标。事故期间它连续 170 个小时报 active，
# 服务确实活着，只是它接到的每个 job 都红。「服务活着」和「CI 可用」是两件事，只测前者等于没测。
#
# 判据：最近 10 个「至少有一个 job 跑在本机」的 run，只看其中落在本机的 job，从最近一次往回数连续失败，
# 3 次及以上告警。单次红是正常的开发活动，连续三次红多半是机器侧或流水线出了问题。
#
# 结果有这几种，都不伪装成绿：
#   streak=N             正常采到
#   skip                 没配 token
#   skip:no-runner       本机没有 runner 服务（--skip-runner 装的机器注册之前）。注册时重跑 bootstrap 会重新渲染本脚本
#   error:<原因>          token 过期、没权限、网络不通，或者读不到本机的 runner 名（no-runner-name）
jobs="skip"
if [ "$SVC" = "none" ] || [ -z "$SVC" ]; then
  jobs="skip:no-runner"
elif [ -n "${GH_REPO:-}" ] && [ -n "$TOKEN" ]; then
  RNAME="${CI_HEALTH_RUNNER_NAME:-$(RUNNER_FILE="$RUNNER_HOME/.runner" python3 -c 'import json,os;print(json.load(open(os.environ["RUNNER_FILE"],encoding="utf-8-sig")).get("agentName",""))' 2>/dev/null)}"
  if [ -z "$RNAME" ]; then
    # 读不到本机 runner 名（.runner 不可读、没注册）就不统计。退回统计全仓库会把托管检查和别的机器的 job
    # 都算进来，结果看起来正常其实是错的。
    jobs="error:no-runner-name"
  else
    jobs=$(GH_REPO="$GH_REPO" TOKEN="$TOKEN" RNAME="$RNAME" python3 - <<'PY' 2>/dev/null || echo "error:python"
import json, os, urllib.error, urllib.request
repo, tok, name = os.environ["GH_REPO"], os.environ["TOKEN"], os.environ["RNAME"]
def get(path):
    req = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=20) as f:
        return json.load(f)
try:
    # 多台机器时每台只分到一部分 run，取 50 个才大概率凑得满 10 个用到本机的
    runs = get(f"/repos/{repo}/actions/runs?per_page=50&status=completed").get("workflow_runs", [])
    concl = []
    for r in runs:
        # 被取消的 run 整个跳过（不计入，也不打断连续计数）。新推送顶掉旧 run 时，写了 if: always() 的汇总 job
        # 照样会跑，因为前面的 job 被取消而判失败；按 job 统计会把它当成本机失败，PR 推得勤的时候一小时能凑满 3 次。
        # job 超时时 run 的结论是 failure，不是 cancelled，不受影响。
        if r.get("conclusion") == "cancelled":
            continue
        js = get(f"/repos/{repo}/actions/runs/{r['id']}/jobs?per_page=100").get("jobs", [])
        mine = [j for j in js if j.get("runner_name") == name]
        if not mine:
            continue
        # 只看落在本机的 job。几台 runner 共用一套标签，同一个 run 的 job 会分到不同机器上，
        # 按 run 的结论算的话，别的机器上的 job 红了，这台也跟着报连续失败。
        concl.append("failure" if any(j.get("conclusion") in ("failure", "timed_out") for j in mine) else "ok")
        if len(concl) >= 10:
            break
    streak = 0
    for c in concl:
        if c != "failure":
            break
        streak += 1
    print(f"streak={streak}")
except urllib.error.HTTPError as e:
    print(f"error:HTTP{e.code}")
except Exception as e:
    print("error:" + type(e).__name__)
PY
)
  fi
fi

echo "$(date -Is) fixedwork=${t}s root_avail=${avail}M containerd=${ctr}M volumes=${vol}M runner=${run} jobs=${jobs} mem_peak=${mem_peak} mem_avail=${mem_avail} tmp=${tmpm}M" >> "$LOG"

# ── 告警 ────────────────────────────────────────────────────────────────
# 每条告警一个稳定的 key，用于推送去重（数值每小时都在变，key 不变）。
ALERTS=()   # 元素形如 "key|文本"
warn(){ ALERTS+=("$1|$2"); echo "$(date -Is) $2" >> "$LOG"; logger -t ci-health "$2" 2>/dev/null || true; }

awk -v t="${t:-0}" -v b="$BASELINE_S" 'BEGIN{ if (b+0 > 0 && t+0 > b*1.4) exit 1 }' \
  || warn contention "WARN vCPU 争抢：定长任务 ${t}s（本机基线 ${BASELINE_S}s）"
# 文案里给出各部分的占用，让人知道先看哪里。containerd 涨了不一定是 BuildKit 缓存（它有 GC 上限），
# 更可能是 GC 管不到的镜像；/tmp 涨了多半是被取消的 job 留下的临时目录。排查顺序见 08 章 8.2。
# 只减和根分区在同一个设备上的部分：/tmp 是 tmpfs、containerd 在单独的盘上时，它们不占根分区。
rootdev=$(stat -c %d / 2>/dev/null); rest=${used:-0}; ctr_s="containerd ${ctr:-?}MB"; tmp_s="/tmp ${tmpm:-?}MB"
if [ -n "$rootdev" ] && [ "$(stat -c %d /var/lib/containerd 2>/dev/null)" = "$rootdev" ]; then rest=$((rest - ${ctr:-0})); else ctr_s+="（不在根分区）"; fi
if [ -n "$rootdev" ] && [ "$(stat -c %d /tmp 2>/dev/null)" = "$rootdev" ]; then rest=$((rest - ${tmpm:-0})); else tmp_s+="（不在根分区）"; fi
disk_parts="${ctr_s}，${tmp_s}，根分区其余 ${rest}MB。先看 docker images 里有没有每次运行留下的镜像、du -sh /tmp/* 里有没有被取消的 job 留下的目录（08 章 8.2）"
if [ "${avail:-999999}" -lt "$CRIT_MB" ]; then
  warn disk_crit "CRIT 根分区可用 ${avail}MB < ${CRIT_MB}MB，已远低于 BuildKit GC 的 Min Free，GC 腾不出空间了。${disk_parts}"
elif [ "${avail:-999999}" -lt "$WARN_MB" ]; then
  warn disk_warn "WARN 根分区可用 ${avail}MB < ${WARN_MB}MB，已逼近 BuildKit GC 的 Min Free，GC 开始为保底而驱逐缓存。${disk_parts}"
fi
[ -n "$CFG_ERR" ] && warn config "WARN 配置无效（应为 MiB 整数）：${CFG_ERR# }，已改用默认阈值"
[ "$run" != "n/a" ] && [ "$run" != "active" ] && warn runner "CRIT runner 服务不是 active（当前 $run）"
# 产出告警：服务 active 但 job 连红，正是 2026-09-07 那种「假绿」的唯一信号
case "$jobs" in
  streak=[3-9]|streak=[0-9][0-9]*)
    warn streak "CRIT 最近 ${jobs#streak=} 个用到本机的 run 里，本机的 job 连续失败。服务 active 不代表 CI 可用，先跑 verify.sh 看钩子实跑那一项" ;;
  error:*)
    warn jobsprobe "WARN job 产出采样失败（${jobs#error:}），这一项现在看不到：HTTP401/403 多半是 token 过期或没权限，no-runner-name 是读不到 $RUNNER_HOME/.runner" ;;
esac

# ── 推送（可选）────────────────────────────────────────────────────────
# 只在告警集合变化时推（新出现、全部恢复），持续存在的每 24 小时提醒一次。
# 签名按飞书自定义机器人「签名校验」的算法：以「时间戳 + 换行 + 密钥」为 key 对空消息做 HMAC-SHA256。
# 用 Slack、钉钉、企业微信等要改下面的 notify()。
# 签名与推送都在 python 里做，密钥和地址只经环境变量传入：放进 openssl/curl 的命令行参数的话，
# 本机任何用户都能从 /proc/<pid>/cmdline 读到。
notify(){
  [ -n "${CI_ALERT_WEBHOOK:-}" ] || return 0
  local resp
  resp=$(TEXT="$1" CI_ALERT_WEBHOOK="$CI_ALERT_WEBHOOK" CI_ALERT_SECRET="${CI_ALERT_SECRET:-}" python3 - <<'PY' 2>&1
import base64, hashlib, hmac, json, os, time, urllib.request
url, secret, text = os.environ["CI_ALERT_WEBHOOK"], os.environ.get("CI_ALERT_SECRET", ""), os.environ["TEXT"]
body = {"msg_type": "text", "content": {"text": text}}
if secret:
    ts = str(int(time.time()))
    body["timestamp"] = ts
    body["sign"] = base64.b64encode(hmac.new(f"{ts}\n{secret}".encode(), b"", hashlib.sha256).digest()).decode()
req = urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode(),
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=15) as f:
        print(f.read().decode(errors="replace"))
except Exception as e:
    print(f"请求失败：{type(e).__name__}: {e}")
PY
)
  # 飞书对签名错、关键词不符等也回 HTTP 200，成败只看返回体里的 code
  printf '%s' "$resp" | grep -Eq '"(code|StatusCode)"[[:space:]]*:[[:space:]]*0[^0-9]' && return 0
  echo "$(date -Is) WARN 告警推送失败：$resp" >> "$LOG"; return 1
}
if [ -n "${CI_ALERT_WEBHOOK:-}" ]; then
  mkdir -p "$STATE_DIR"
  keys=$(for a in "${ALERTS[@]+"${ALERTS[@]}"}"; do printf '%s\n' "${a%%|*}"; done | sort -u | tr '\n' ' ')
  prev=$(cat "$STATE_DIR/keys" 2>/dev/null)
  last=$(stat -c %Y "$STATE_DIR/keys" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$keys" != "$prev" ] || { [ -n "$keys" ] && [ $((now - last)) -ge 86400 ]; }; then
    # 标题带上 runner 注册名（GitHub 上 job 页面「Set up job」和 Settings → Runners 里显示的就是它）和主机名。
    # 几台机器推到同一个群时，只看主机名分不清哪台是哪台：云上的默认主机名常常是一串编号。
    rn=$(RUNNER_FILE="$RUNNER_HOME/.runner" python3 -c 'import json,os;print(json.load(open(os.environ["RUNNER_FILE"],encoding="utf-8-sig")).get("agentName",""))' 2>/dev/null)
    host="${rn:+$rn（}$(hostname -s)${rn:+）}"
    if [ -n "$keys" ]; then
      body="[CI runner 告警] $host"
      for a in "${ALERTS[@]}"; do body+=$'\n'"· ${a#*|}"; done
    else
      body="[CI runner 恢复] $host：之前的告警已全部消除"
    fi
    notify "$body" && printf '%s' "$keys" > "$STATE_DIR/keys"
  fi
fi
exit 0
