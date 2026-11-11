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
#  ⑦ 服务 active 不代表 runner 在接 job。服务的主进程是 runsvc.sh，listener 崩了由它在里面重新拉起，
#     systemd 看不到，NRestarts 一直是 0。参考项目第二台盘满时 listener 一启动就崩，离线四个多小时，
#     这里一直记 runner=active（09 章 A23）。现在另看 Runner.Listener 进程，采样行多记一个 listener=。
#  ⑧ 磁盘 WARN 在两个 job 之间量。job 运行时它的镜像、临时目录都还在，参考项目一个算法测试 job 运行中要多占
#     约 5 GB，整点采样撞上就报 WARN，job 一结束又回来了（09 章 B21）。CRIT 照常立刻报。
#
# 2026-11-11 补的一条：
#
#  ⑨ 推送改成飞书卡片。原来的文本消息把数字、原因和排查命令挤在一段里，还夹着章节号，群里的人要读完整段
#     才知道多严重、先做什么。现在标题带级别和最严重那条，每条拆成情况、影响、先做什么、去哪看，
#     CRIT 红、WARN 橙、恢复绿，章节号换成手册链接（08 章 8.2「监控要点」）。卡片里要人跑 verify.sh 时
#     写出这台上手册仓库的完整路径，路径由 bootstrap 渲染进来。本机日志和 journal 里仍是单行文本。
set -uo pipefail
LOG="${CI_HEALTH_LOG:-/var/log/ci-health.log}"
SVC="__RUNNER_SVC__"                      # 由 bootstrap.sh 替换；--skip-runner 装的机器上是 none
# 装机用的手册仓库目录（绝对路径），由 bootstrap.sh 替换。卡片里写「用 root 跑 bash <目录>/scripts/verify.sh」；
# 没替换、目录挪走了，就改写成「装机用的手册仓库里的 scripts/verify.sh」。判断用 verify.sh 在不在，
# 不拿占位符本身做判据：sed 会把判据里的占位符一起换掉（09 章 A12）。
PLAYBOOK_DIR="__PLAYBOOK_DIR__"

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

# 下面两段 python 出错时，把 stderr 的最后一行写进日志，卡片让人去日志里看原因。只留一行、截 200 字，
# 里面出现 token 就换成「<已隐去>」（请求头写错时 http.client 的报错会带上头的值）。
ERRF=$(mktemp "${TMPDIR:-/tmp}/ci-health.XXXXXX" 2>/dev/null) || ERRF=""
trap '[ -n "$ERRF" ] && rm -f "$ERRF"' EXIT
hide_token(){ local s=$1; [ "${#TOKEN}" -ge 8 ] && s=${s//"$TOKEN"/<已隐去>}; printf '%s' "$s"; }
last_err(){ [ -n "$ERRF" ] || return 0; local s; s=$(grep -v '^[[:space:]]*$' "$ERRF" 2>/dev/null | tail -1); s=${s//[$'\t\r']/ }; s=$(hide_token "$s"); printf '%s' "${s:0:200}"; }

# 量不到的检查（这次没查、或者没查出结果）：上次报过的话，卡片标「看不到了」，不算消除。
# 元素形如 "key|原因代号|卡片发不了时文本消息里的一句"。job 采样出错、服务不是 active 这两种另有告警挡着，
# 卡片里写在那条告警下面，不在这里。
UNSEEN=()

t=$(python3 - <<'PY' 2>"${ERRF:-/dev/null}"
import hashlib, time
blk = b'x' * 4096
t0 = time.time()
h = hashlib.sha256()
for _ in range(180000):
    h.update(blk)
h.hexdigest()
print("%.3f" % (time.time() - t0))
PY
); rc=$?
t_why=""
if [ "$rc" -ne 0 ]; then t_why=$(last_err); t_why=${t_why:-python 退出码 $rc}; t=""
elif ! [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then t_why="输出不是秒数"; t=""; fi
[ -n "$t" ] || UNSEEN+=("contention|fixedwork|上次报的「vCPU 争抢」这次看不到了（定长任务没跑出结果），不算消除")
avail=$(df --output=avail -BM / 2>/dev/null | tail -1 | tr -dc 0-9)
ctr=$(du -sBM /var/lib/containerd 2>/dev/null | cut -f1 | tr -dc 0-9)
# /tmp 单独量：job 被取消时，程序自己建在 /tmp 下的临时目录不会被删（09 章 A22）
tmpm=$(du -sxBM /tmp 2>/dev/null | cut -f1 | tr -dc 0-9)
used=$(df --output=used -BM / 2>/dev/null | tail -1 | tr -dc 0-9)
vol=$(du -sBM /var/lib/docker/volumes 2>/dev/null | cut -f1 | tr -dc 0-9)
run="n/a"; [ "$SVC" != "none" ] && [ -n "$SVC" ] && run=$(systemctl is-active "$SVC" 2>/dev/null)
# listener 进程活了多少秒；不在就输出空。按进程名精确匹配（-x），取最老的那个（-o）
listener_age(){ local p; p=$(pgrep -xo Runner.Listener 2>/dev/null) || return 0; ps -o etimes= -p "$p" 2>/dev/null | tr -dc 0-9; }
# 不在、或者活了不到 60 秒时隔一会儿再看一次：刚重启服务、runner 自更新时第一次会不正常，再看就好了；
# 反复崩溃时（参考项目上是几秒一次）两次都不正常。只有不正常时才多等这一下。
listener="n/a"
if [ "$run" = active ]; then
  la=$(listener_age)
  if [ "${la:-0}" -lt 60 ]; then sleep "${CI_HEALTH_LISTENER_WAIT:-90}"; la=$(listener_age); fi
  if [ -z "$la" ]; then listener=none; elif [ "$la" -lt 60 ]; then listener="restarting(${la}s)"; else listener="${la}s"; fi
fi
# 内存只记录不告警：runner cgroup 自上次启动以来的峰值（含页缓存，比进程实际占用高），以及整机可用内存
mem_peak="n/a"
if [ "$SVC" != "none" ] && [ -n "$SVC" ]; then
  p=$(systemctl show "$SVC" -p MemoryPeak --value 2>/dev/null)
  case "$p" in ''|*[!0-9]*) ;; *) mem_peak="$((p / 1048576))M" ;; esac
fi
mem_avail="$(awk '/^MemAvailable:/{printf "%dM", $2/1024}' /proc/meminfo 2>/dev/null)"

# 可用空间落在 WARN 和 CRIT 之间、又正好有 job 在跑时，等到本机没有 job 的那一刻再量一次，WARN 以那次为准。
# 那一刻上一个 job 的清理（它自己的和 JOB_COMPLETED 钩子）都已经跑完。job 之间的空档常常只有两三秒，
# 所以每 0.5 秒看一次，空档里只用 df 量可用空间（毫秒级）；du containerd 要几十秒，来不及，告警里的分项
# 仍用整点那次的值。等满 CI_HEALTH_IDLE_WAIT 秒（默认 25 分钟）还一直有 job，这一小时就不判 WARN，下一小时再看。
avail_idle=""
if [ "${avail:-999999}" -lt "$WARN_MB" ] && [ "${avail:-0}" -ge "$CRIT_MB" ] && pgrep -x Runner.Worker >/dev/null 2>&1; then
  idle_end=$(( $(date +%s) + ${CI_HEALTH_IDLE_WAIT:-1500} ))
  while [ "$(date +%s)" -lt "$idle_end" ]; do
    if ! pgrep -x Runner.Worker >/dev/null 2>&1; then
      avail_idle=$(df --output=avail -BM / 2>/dev/null | tail -1 | tr -dc 0-9); break
    fi
    sleep 0.5
  done
  [ -n "$avail_idle" ] || avail_idle=busy
fi

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
    # 第一行是结果；连不上 GitHub、或者出了别的异常时多一行原因（DNS、连接被拒、证书、异常文本之类），
    # 写进下面的告警文本，卡片让人去日志里看。原因截 200 字，里面出现 token 就换掉；python 自己崩了取 stderr 最后一行。
    jobs_out=$(GH_REPO="$GH_REPO" TOKEN="$TOKEN" RNAME="$RNAME" python3 - <<'PY' 2>"${ERRF:-/dev/null}"
import json, os, urllib.error, urllib.request
repo, tok, name = os.environ["GH_REPO"], os.environ["TOKEN"], os.environ["RNAME"]
# 原因里不带 token：请求头写错时，http.client 的报错会带上头的值，而且是 repr 过的（控制字符写成 \r 之类），三种写法都换掉
HIDE = sorted({x for x in (tok, repr(tok)[1:-1], repr(tok.encode())[2:-1]) if len(x) >= 8}, key=len, reverse=True)
def why(s):   # 一行、截 200 字、不带 token
    s = str(s)
    for x in HIDE:
        s = s.replace(x, "<已隐去>")
    return " ".join(s.split())[:200]
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
except urllib.error.URLError as e:
    print("error:URLError")
    print(why(e.reason))
except Exception as e:
    print("error:" + type(e).__name__)
    print(why(e))
PY
) || jobs_out="error:python"$'\n'"$(last_err)"
    jobs=${jobs_out%%$'\n'*}
    [ "$jobs_out" = "$jobs" ] || jobs_why=${jobs_out#*$'\n'}
  fi
fi
jobs_why=${jobs_why:-}; jobs_why=${jobs_why//[$'\t\r\n']/ }; jobs_why=$(hide_token "$jobs_why")
# 没配 token、没有 runner 服务时连续失败这一项不查
case "$jobs" in
  skip)   UNSEEN+=("streak|skip|上次报的「本机 job 连续失败」这次看不到了（没配只读 token 或 GH_REPO，不查这一项），不算消除")
          UNSEEN+=("jobsprobe|skip|上次报的「读不到本机 job 结果」这次看不到了（没配只读 token 或 GH_REPO，不查这一项），不算消除") ;;
  skip:*) UNSEEN+=("streak|no-runner|上次报的「本机 job 连续失败」这次看不到了（这台按没有 runner 服务装的，不查这一项），不算消除") ;;
esac

fw=${t:+${t}s}; fw=${fw:-n/a}   # 有秒数写「2.100s」，没跑出结果写「n/a」
echo "$(date -Is) fixedwork=${fw} root_avail=${avail}M containerd=${ctr}M volumes=${vol}M runner=${run} jobs=${jobs} mem_peak=${mem_peak} mem_avail=${mem_avail} tmp=${tmpm}M listener=${listener} avail_between_jobs=${avail_idle:-n/a}" >> "$LOG"
# 定长任务没跑出结果时另记一行原因：采样行里只有 fixedwork=n/a
[ -n "$t" ] || echo "$(date -Is) WARN 定长任务没跑出结果（${t_why}），这一小时不判 vCPU 争抢" >> "$LOG"

# ── 告警 ────────────────────────────────────────────────────────────────
# 每条告警一个稳定的 key，用于推送去重（数值每小时都在变，key 不变）。
# warn <key> <一行文本> [字段=值 ...]：一行文本写本机日志和 journal，没变；字段是给飞书卡片用的原始数据，
# 卡片的文案在下面 notify() 里按 key 拼（2026-11-11 起推送改成卡片）。
ALERTS=()   # 元素形如 "key|文本"，去重和文本推送用
FACTS=()    # 元素形如 "key<TAB>级别<TAB>字段=值<TAB>…"，卡片用；值里的制表符和换行换成空格
warn(){
  local key=$1 text=$2 rec kv; shift 2
  ALERTS+=("$key|$text")
  rec="$key"$'\t'"${text%% *}"
  for kv in "$@" "text=$text"; do rec+=$'\t'"${kv//[$'\t\r\n']/ }"; done
  FACTS+=("$rec")
  echo "$(date -Is) $text" >> "$LOG"; logger -t ci-health "$text" 2>/dev/null || true
}

awk -v t="${t:-0}" -v b="$BASELINE_S" 'BEGIN{ if (b+0 > 0 && t+0 > b*1.4) exit 1 }' \
  || warn contention "WARN vCPU 争抢：定长任务 ${t}s（本机基线 ${BASELINE_S}s）" t="$t" base="$BASELINE_S"
# 文案里给出各部分的占用，让人知道先看哪里。containerd 涨了不一定是 BuildKit 缓存（它有 GC 上限），
# 更可能是 GC 管不到的镜像；/tmp 涨了多半是被取消的 job 留下的临时目录。排查顺序见 08 章 8.2。
# 只减和根分区在同一个设备上的部分：/tmp 是 tmpfs、containerd 在单独的盘上时，它们不占根分区。
rootdev=$(stat -c %d / 2>/dev/null); rest=${used:-0}; ctr_s="containerd ${ctr:-?}MB"; tmp_s="/tmp ${tmpm:-?}MB"; ctr_root=0; tmp_root=0
if [ -n "$rootdev" ] && [ "$(stat -c %d /var/lib/containerd 2>/dev/null)" = "$rootdev" ]; then rest=$((rest - ${ctr:-0})); ctr_root=1; else ctr_s+="（不在根分区）"; fi
if [ -n "$rootdev" ] && [ "$(stat -c %d /tmp 2>/dev/null)" = "$rootdev" ]; then rest=$((rest - ${tmpm:-0})); tmp_root=1; else tmp_s+="（不在根分区）"; fi
disk_parts="${ctr_s}，${tmp_s}，根分区其余 ${rest}MB。先看 docker images 里有没有每次运行留下的镜像、du -sh /tmp/* 里有没有被取消的 job 留下的目录（08 章 8.2）"
disk_facts=(warn="$WARN_MB" crit="$CRIT_MB" ctr="${ctr:-}" ctr_root="$ctr_root" tmp="${tmpm:-}" tmp_root="$tmp_root" rest="$rest")
if [ "${avail:-999999}" -lt "$CRIT_MB" ]; then
  warn disk_crit "CRIT 根分区可用 ${avail}MB < ${CRIT_MB}MB。${disk_parts}" \
    avail="$avail" "${disk_facts[@]}"
elif [ "${avail:-999999}" -lt "$WARN_MB" ]; then
  case "$avail_idle" in
    "")   warn disk_warn "WARN 根分区可用 ${avail}MB < ${WARN_MB}MB（整点量时没有 job 在跑）。${disk_parts}" \
            mode=now avail="$avail" "${disk_facts[@]}" ;;
    # 一直有 job，量不到 job 之间的值，这一小时不判。上一次推送里有这条 WARN 的话照旧带上，
    # 否则告警集合一变，就会推一条「已全部消除」，下一小时又报回来。
    busy) case " $(cat "$STATE_DIR/keys" 2>/dev/null) " in *" disk_warn "*)
            warn disk_warn "WARN 根分区可用 ${avail}MB < ${WARN_MB}MB（这一小时一直有 job 在跑，量不到两个 job 之间的值，沿用上一次的 WARN）。${disk_parts}" \
              mode=busy avail="$avail" "${disk_facts[@]}" ;; esac ;;
    *)    [ "$avail_idle" -lt "$WARN_MB" ] && warn disk_warn "WARN 根分区可用 ${avail_idle}MB < ${WARN_MB}MB（两个 job 之间量的）。整点时有 job 在跑，当时 ${disk_parts}" \
            mode=idle avail="$avail_idle" avail_now="$avail" "${disk_facts[@]}" ;;
  esac
fi
[ -n "$CFG_ERR" ] && warn config "WARN 配置无效（应为 MiB 整数）：${CFG_ERR# }，已改用默认阈值" bad="${CFG_ERR# }" warn="$WARN_MB" crit="$CRIT_MB"
[ "$run" != "n/a" ] && [ "$run" != "active" ] && warn runner "CRIT runner 服务不是 active（当前 $run）" state="$run" svc="$SVC"
case "$listener" in
  none) warn listener "CRIT runner 服务是 active，但隔了一会儿再看，Runner.Listener 进程还是不在，这台实际没在接 job。先看 journalctl -u $SVC 最后几行，常见原因是根分区满了（09 章 A23）" \
          mode=none wait="${CI_HEALTH_LISTENER_WAIT:-90}" svc="$SVC" ;;
  restarting*) warn listener "CRIT runner 服务是 active，但 Runner.Listener 两次查看都是刚启动（${listener#restarting}），在反复崩溃重启，这台实际没在接 job。先看 journalctl -u $SVC 最后几行，常见原因是根分区满了（09 章 A23）" \
          mode=restarting wait="${CI_HEALTH_LISTENER_WAIT:-90}" age="${listener//[!0-9]/}" svc="$SVC" ;;
esac
# 产出告警：服务 active 但 job 连红，正是 2026-09-07 那种「假绿」的唯一信号
case "$jobs" in
  streak=[3-9]|streak=[0-9][0-9]*)
    warn streak "CRIT 最近 ${jobs#streak=} 个用到本机的 run 里，本机的 job 连续失败。服务 active 不代表 CI 可用，先看 GitHub 上红在哪一步，再跑 verify.sh 看钩子实跑那一项" \
      n="${jobs#streak=}" runner="${RNAME:-}" repo="${GH_REPO:-}" ;;
  error:*)
    warn jobsprobe "WARN job 产出采样失败（${jobs#error:}${jobs_why:+：$jobs_why}），「本机 job 连续失败」这一项现在看不到" \
      reason="${jobs#error:}" runner_home="$RUNNER_HOME" repo="${GH_REPO:-}" ;;
esac

# ── 推送（可选）────────────────────────────────────────────────────────
# 只在告警集合变化时推（新出现、部分或全部消除），持续存在的每 24 小时提醒一次。
# 推的是飞书卡片（JSON 2.0，msg_type interactive）：告警卡 CRIT 红、只有 WARN 橙，全部消除时发绿色的恢复卡。
# 每条告警拆成「情况、影响、先做什么、去哪看」，文案按 key 写在下面的 python 里，数据来自 warn 的字段；
# 没写文案的 key（以后新加的检查）照样送达，情况一栏放日志里那行原文。
# 卡片拼不出来、超过 19000 字节、或者飞书以卡片格式不对拒收（11246、9499）时，改发原来的文本消息。
# 签名按飞书自定义机器人「签名校验」的算法：以「时间戳 + 换行 + 密钥」为 key 对空消息做 HMAC-SHA256。
# 用 Slack、钉钉、企业微信等要改下面的 notify()。
# 拼卡片、签名与推送都在 python 里做，JSON 由 json.dumps 生成；密钥和地址只经环境变量传入：放进 openssl/curl 的
# 命令行参数的话，本机任何用户都能从 /proc/<pid>/cmdline 读到。写进日志的推送结果里，地址和密钥都换成「<已隐去>」：
# 地址写错时 urllib 的报错会原样带上地址。
# 卡片「去哪看」链到这份手册的公开仓库（只读，链接里不带任何密钥）；fork 之后改成自己的地址。
DOC_URL="https://github.com/F-WORKS-FBY/self-hosted-runner-playbook/blob/main"
notify(){   # notify alert|recover <文本消息>：文本消息只在卡片发不了时用
  [ -n "${CI_ALERT_WEBHOOK:-}" ] || return 0
  local resp rc verify="" hid
  # 卡片里写 verify.sh 的完整路径；这台上找不到就写「装机用的手册仓库」
  case "$PLAYBOOK_DIR" in /*) [ -f "$PLAYBOOK_DIR/scripts/verify.sh" ] && verify="bash $PLAYBOOK_DIR/scripts/verify.sh" ;; esac
  resp=$(CARD_KIND="$1" CARD_TEXT="$2" CARD_ALERTS="$(printf '%s\n' "${FACTS[@]+"${FACTS[@]}"}")" \
    CARD_PREV="$prev" CARD_RUNNER="$rn" CARD_HOST="$hn" CARD_SVC="$SVC" CARD_REPO="${GH_REPO:-}" \
    CARD_RUNNER_HOME="$RUNNER_HOME" CARD_VERIFY="$verify" CARD_UNSEEN="$unseen_kv" \
    CARD_LOG="$LOG" CARD_ENV="$CI_HEALTH_ENV" CARD_DOC="$DOC_URL" \
    CI_ALERT_WEBHOOK="$CI_ALERT_WEBHOOK" CI_ALERT_SECRET="${CI_ALERT_SECRET:-}" python3 - <<'PY' 2>&1
import base64, hashlib, hmac, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

E = os.environ
URL, SECRET = E["CI_ALERT_WEBHOOK"], E.get("CI_ALERT_SECRET", "")
MAX_BODY = 19000                 # 飞书写的上限是 20KB，没说按 1000 还是 1024 算，取保守值
RATE_LIMITED, BACKOFF_S = 11232, 5
CARD_REJECTED = (11246, 9499)    # 卡片结构不对、请求体格式不对或超长：改发文本
REASONS = {
    19021: "签名或时间戳不对（CI_ALERT_SECRET 和机器人的签名密钥不一致，或本机时钟差了 1 小时以上）",
    19024: "关键词不符（机器人开了自定义关键词，消息里没有）",
    19022: "IP 不在机器人的白名单里",
    9499: "请求体格式不对，或超过 20KB",
    11246: "卡片 JSON 不合 2.0 结构",
    RATE_LIMITED: "被限流（单个机器人 100 次/分钟、5 次/秒）",
}
# 输出会写进日志：推送地址、密钥、地址末段的机器人 ID 一律换掉
HIDDEN = sorted({x for x in (URL, SECRET, URL.rstrip("/").rsplit("/", 1)[-1]) if len(x) >= 8}, key=len, reverse=True)
def redact(s):
    s = str(s)
    for x in HIDDEN:
        s = s.replace(x, "<已隐去>")
    return s

# ---- 转义：动态值一律经过这里，再由 json.dumps 做 JSON 转义 ----
UNSAFE = re.compile("[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2060-\u2069\ufeff]")   # 控制字符、零宽与双向控制
def plain(s):    # 卡片头部是 plain_text，不解析 markdown：只去控制字符
    return re.sub(r"\s+", " ", UNSAFE.sub(" ", s or "")).strip()
def txt(s):      # markdown 正文里的外来文字：记号换成 HTML 实体（飞书卡片的写法，不认反斜杠转义）
    return re.sub(r"[&<>\[\]()*_~`#$\\:|]", lambda m: "&#%d;" % ord(m.group()), UNSAFE.sub("", s or ""))
def code(s, limit=160):   # 代码样式：去掉反引号与控制字符，尖括号换全角（拼不出 <at> 这类标签）
    s = UNSAFE.sub("", s or "").replace("`", "'").replace("<", "＜").replace(">", "＞").strip()
    s = s if len(s) <= limit else s[:limit] + "…"
    return "`%s`" % s if s else "（空）"
def num(s):
    return s if re.fullmatch(r"\d{1,12}(\.\d{1,6})?", s or "") else "?"

KIND, TEXT = E.get("CARD_KIND", "alert"), E.get("CARD_TEXT", "")
RUNNER, HOST = plain(E.get("CARD_RUNNER")), plain(E.get("CARD_HOST"))
SVC, REPO, RUNNER_HOME = E.get("CARD_SVC", ""), E.get("CARD_REPO", ""), E.get("CARD_RUNNER_HOME", "")
LOG, ENVF = E.get("CARD_LOG", ""), E.get("CARD_ENV", "")
DOC = E.get("CARD_DOC", "").rstrip("/")
PREV = (E.get("CARD_PREV") or "").split()
VERIFY = E.get("CARD_VERIFY", "")
# 量不到的检查：key → 原因代号（bash 那边的 UNSEEN）
UNSEEN = dict(l.split("\t", 1) for l in (E.get("CARD_UNSEEN") or "").split("\n") if "\t" in l)
# 先做什么一律以这句开头；前几步不用登机（在群里问、看 GitHub、建 token）时，放在登机那一步的开头。
# 要 root 的有：verify.sh（查 iptables、sshd，还以 runner 用户的身份实跑一次清理钩子）、journalctl、systemctl、
# 0600 的 /etc/ci-health.env、/etc 下的配置
ROOT = "以下在这台上用 root 跑"
ROOT_PRE = ROOT + "："
VERIFY_CMD = code(VERIFY) if VERIFY else "装机用的手册仓库里的 `scripts/verify.sh`"
VERIFY_RUN = "跑" + (" " if VERIFY else "") + VERIFY_CMD
NEW_TOKEN = "找有仓库管理权限的人建只读 token（fine-grained，只授权这个仓库，Actions 只读）"

def doc(label, path, anchor):
    return "[手册：%s](%s/%s#%s)" % (label, DOC, urllib.parse.quote(path), urllib.parse.quote(anchor))
L_DISK = doc("磁盘各类占用分别由谁清理", "08-运维与容量.md", "82-磁盘各类占用分别由谁清理")
L_CANCEL = doc("job 被取消时，程序里的清理不执行", "09-踩坑记录.md", "a22-job-被取消时程序里的清理不执行")
L_CPU = doc("CPU 争抢监控", "08-运维与容量.md", "83-cpu-争抢监控")
L_REVIEW = doc("上线后看哪些数、什么时候复核", "10-按机器规格定参数.md", "107-上线后看哪些数什么时候复核")
L_THRESH = doc("BuildKit 与磁盘阈值", "10-按机器规格定参数.md", "104-buildkit-与磁盘阈值")
L_RESTART = doc("重启和升级，一次只动一台", "08-运维与容量.md", "重启和升级一次只动一台")
L_VERIFY = doc("verify.sh 查什么", "07-验证.md", "71-verifysh-查什么")
L_LISTENER = doc("runner 服务是 active，listener 却一直在崩", "09-踩坑记录.md", "a23-runner-服务是-activelistener-却一直在崩")
L_A11 = doc("runner 调 job 钩子时强加 -e，钩子出错 job 就红", "09-踩坑记录.md", "a11-runner-调-job-钩子时强加--e钩子里任何一条命令非零就让-job-全红")
L_HOOK = doc("为什么要实跑一次钩子", "07-验证.md", "为什么要实跑一次钩子")
L_MON = doc("监控要点", "08-运维与容量.md", "监控要点")
L_TOKEN = doc("job 采样为什么只给只读 token", "09-踩坑记录.md", "b12-把管理员-token-落在了-ci-机上2026-09-14-修-a11-时引入")
L_UPDATE = doc("更新已部署的机器", "08-运维与容量.md", "更新已部署的机器")
LOG_LINE = "这台的采样记录：" + code("tail -20 " + LOG)
JOBS_BACK = "`jobs=` 变回 `streak=数字` 就好了：" + code("grep -o 'jobs=[^ ]*' %s | tail -3" % LOG)
FIXED_BACK = "`fixedwork=` 变回秒数就好了：" + code("grep -o 'fixedwork=[^ ]*' %s | tail -3" % LOG)

NAMES = {"contention": "CPU 变慢", "disk_crit": "根分区快满了", "disk_warn": "根分区可用空间偏低",
         "config": "磁盘阈值配置无效", "runner": "runner 服务没在运行", "listener": "runner 没在接 job",
         "streak": "本机 job 连续失败", "jobsprobe": "读不到本机 job 结果"}
LEVELS = {"contention": "WARN", "disk_crit": "CRIT", "disk_warn": "WARN", "config": "WARN",
          "runner": "CRIT", "listener": "CRIT", "streak": "CRIT", "jobsprobe": "WARN"}
# 这几条在另一条出现时量不到：上次在报、这次没报，不能算消除。写在那一条的情况里
BLOCKED_BY = {"streak": ("jobsprobe", ""), "listener": ("runner", "服务不是 active 时不查这一项")}
def label(key):   # 「WARN 根分区可用空间偏低」：恢复、已消除、看不到了里用
    return ("%s %s" % (LEVELS[key], NAMES[key])) if key in NAMES else code(key)
def headline(key, lv, f, md=False):   # 标题和多条时每节的标题：级别、名字，连续失败带次数
    if key not in NAMES:
        return "%s %s" % (lv, code(key) if md else plain(key))
    n = num(f.get("n")) if key == "streak" else "?"
    return "%s %s%s" % (lv, NAMES[key], " %s 次" % n if n != "?" else "")
def counts(lvs):
    parts = ["%s %d 条" % (lv, lvs.count(lv)) for lv in ("CRIT", "WARN") if lv in lvs]
    other = sum(1 for lv in lvs if lv not in ("CRIT", "WARN"))
    return "、".join(parts + (["其他 %d 条" % other] if other else []))

def disk_parts(f, when=""):
    on, off = [], []
    for what, k, root in (("containerd", "ctr", "ctr_root"), ("/tmp", "tmp", "tmp_root")):
        (on if f.get(root) == "1" else off).append("%s %s MB" % (what, num(f.get(k))))
    s = "%s根分区已用：%s" % (when, "，".join(on + ["其他 %s MB" % num(f.get("rest"))]))
    return s + ("；不在根分区的：%s" % "，".join(off) if off else "")
DISK_PRE = ROOT + "，先 `pgrep -x Runner.Worker` 没输出（没有 job 在跑）再删："
DISK_STEPS = [
    "`docker images`：有没有一串名字只差一段随机串的镜像（被取消的 job 留下的），有就 `docker image rm` 删，不带 `-f`",
    "`du -sh /tmp/* | sort -h | tail`：有没有同一前缀的一串大目录（也是被取消的 job 留下的），有就删",
    "前两样都不多，再看 Docker 以外：`du -sh /root/.vscode-server /home/*/.vscode-server /home/*/.cache`",
]

def t_contention(f):
    t, b = num(f.get("t")), num(f.get("base"))
    try:
        r = "%.2f" % (float(t) / float(b))
    except (ValueError, ZeroDivisionError):
        r = "?"
    return dict(
        facts=["定长任务（固定量的 sha256 计算）这次用了 **%s 秒**，这台的基线 %s 秒，是基线的 %s 倍；超过 1.4 倍就报" % (t, b, r)],
        impact="这台跑 job 会变慢，本来就贴着超时的 job 可能超时",
        pre=ROOT_PRE,
        steps=["看最近 24 次有几次超：%s" % code("grep -o 'fixedwork=[0-9.]*s' %s | tail -24" % LOG),
               "连着几个小时都超，`lscpu | grep 'Model name'` 看 CPU 型号变没变，变了要重测基线",
               "型号没变，按下面「上线后看哪些数」那一节往下查"],
        links=[L_CPU, L_REVIEW])

def t_disk_crit(f):
    return dict(
        facts=["根分区可用 **%s MB**，低于 CRIT 线 %s MB" % (num(f.get("avail")), num(f.get("crit"))), disk_parts(f)],
        impact="再满下去，job 会因为写不进盘而失败；盘满时 runner 会掉线",
        pre=DISK_PRE, steps=DISK_STEPS, links=[L_DISK, L_CANCEL])

def t_disk_warn(f):
    mode, avail, line = f.get("mode"), num(f.get("avail")), "低于 WARN 线 %s MB" % num(f.get("warn"))
    if mode == "idle":
        facts = ["两个 job 之间量的根分区可用 **%s MB**，%s" % (avail, line),
                 "整点时有 job 在跑，当时可用 %s MB" % num(f.get("avail_now")), disk_parts(f, "整点时")]
    elif mode == "busy":
        facts = ["根分区可用 **%s MB**，%s" % (avail, line),
                 "这一小时一直有 job 在跑，量不到两个 job 之间的值，沿用上一次的 WARN", disk_parts(f)]
    else:
        facts = ["根分区可用 **%s MB**，%s" % (avail, line), "整点量时没有 job 在跑", disk_parts(f)]
    return dict(facts=facts, impact="CI 照常跑；可用空间降到 BuildKit 的保底线 Min Free 以下时，它才会删构建缓存，部分构建会变慢",
                pre=DISK_PRE, steps=DISK_STEPS, links=[L_DISK, L_CANCEL])

def t_config(f):
    return dict(
        facts=["%s 不是 MiB 整数" % code(f.get("bad")),
               "这次判磁盘用的是：WARN 线 %s MB，CRIT 线 %s MB（写错的那项换成了默认值）" % (num(f.get("warn")), num(f.get("crit")))],
        impact="磁盘告警的阈值可能和这台盘的大小对不上",
        pre=ROOT_PRE,
        steps=["改 `/etc/cron.d/ci-health` 和 `/etc/ci-runner.env` 里的这一项，写成 MiB 整数",
               "取值按下面手册算；两处都有时以 cron.d 为准"],
        links=[L_THRESH])

def t_runner(f):
    svc = f.get("svc") or SVC or "?"
    return dict(
        facts=["runner 服务当前是 %s，不是 active" % code(f.get("state"))],
        impact="这台不接 job；job 会排给别的 runner，没有别的就一直排队",
        steps=["先在群里问一声是不是有人在维护这台：重启、升级前都会先停服务",
               "没人在维护的话，%s：%s 看原因" % (ROOT, code("journalctl -u %s -n 50" % svc)),
               "处理完 %s，起来以后%s" % (code("systemctl start %s" % svc), VERIFY_RUN)],
        links=[L_RESTART, L_VERIFY])

def t_listener(f):
    svc, wait = f.get("svc") or SVC or "?", num(f.get("wait"))
    if f.get("mode") == "restarting":
        facts = ["runner 服务是 active，但接 job 的 `Runner.Listener` 进程在反复崩溃重启",
                 "隔 %s 秒看了两次，都是刚启动（第二次 %s 秒）" % (wait, num(f.get("age")))]
    else:
        facts = ["runner 服务是 active，但接 job 的 `Runner.Listener` 进程不在", "隔 %s 秒再看还是不在" % wait]
    return dict(
        facts=facts, impact="这台实际没在接 job；看服务状态只能看到 active",
        pre=ROOT_PRE,
        steps=["%s 看最后几行" % code("journalctl -u %s -n 50" % svc),
               "`df -h /` 看根分区是不是满了：盘满时它一启动就崩，之前出过",
               "处理完再%s，要有一行 `Runner.Listener 在跑`" % VERIFY_RUN],
        links=[L_LISTENER])

def t_streak(f):
    repo, links = f.get("repo") or REPO, []
    if re.fullmatch(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", repo):
        links.append("[GitHub Actions 运行记录](https://github.com/%s/actions)" % repo)
    first = "打开%sGitHub Actions，看落在这台的 job 红在哪一步、几次是不是同一处" % ("下面的 " if links else " ")
    if RUNNER:
        first += "。job 日志开头 Set up job 里 Runner name 是 %s 的，就是落在这台的" % code(RUNNER)
    return dict(
        facts=["这台上的 job 从最近一次往回数连续失败 **%s 次**（被取消的 run 不算，满 3 次就报）" % num(f.get("n"))],
        impact="这台接的 job 可能继续失败；runner 服务照样显示 active，光看服务状态发现不了",
        steps=[first,   # 第 1 步在 GitHub 上看，不用登机
               "%s：%s，看带 `清理钩子` 和 `bash -e` 的那一行是 PASS 还是 FAIL。有 job 在跑时这一项会跳过，"
               "那一行换成 `有 job 正在运行，跳过钩子实跑`，等 `pgrep -x Runner.Worker` 没输出再跑" % (ROOT, VERIFY_CMD)],
        links=links + [L_A11, L_HOOK])

def t_jobsprobe(f):
    reason = f.get("reason") or ""
    reason = reason if re.fullmatch(r"[A-Za-z0-9_.-]{1,40}", reason) else "?"
    auth, pre = reason in ("HTTP401", "HTTP403", "HTTP404"), ROOT_PRE
    if reason == "HTTP401":   # GitHub 只在凭据无效时回 401，仓库名写错不会回 401：直接换 token
        fact = "统计这台 job 结果时，GitHub 回了 %s：token 失效（过期、被撤销或写错）" % code(reason)
        pre, steps = "", [NEW_TOKEN,   # 不用登机
                          "%s：把新 token 写进 %s 的 `CI_HEALTH_GH_TOKEN=`" % (ROOT, code(ENVF)),
                          "下一小时 " + JOBS_BACK]
    elif auth:   # 没权限回 403，没授权的私有仓库和不存在的仓库一样回 404
        fact = "统计这台 job 结果时，GitHub 回了 %s：token 失效、没权限或仓库名不对" % code(reason)
        steps = ["先核仓库名：%s 里 `GH_REPO=` 现在是 %s" % (code(ENVF), code(f.get("repo") or REPO)),
                 "仓库名没错，就%s，写进同一个文件的 `CI_HEALTH_GH_TOKEN=`" % NEW_TOKEN,
                 "下一小时 " + JOBS_BACK]
    elif reason == "no-runner-name":
        fact = "统计这台 job 结果时出错：读不到 %s 里的 runner 注册名" % code((f.get("runner_home") or RUNNER_HOME) + "/.runner")
        steps = ["看这台注册了没有、这个文件还在不在", "下一小时 " + JOBS_BACK]
    else:      # 采样脚本自己出错、连不上 GitHub、GitHub 回了别的码：不猜原因，原因在日志那一行里
        fact = "统计这台 job 结果时出错（%s）" % code(reason)
        steps = ["原因见日志：%s" % code("grep 采样失败 %s | tail -3" % LOG), "下一小时会自动再试，" + JOBS_BACK]
    return dict(
        facts=[fact], hint="「本机 job 连续失败」这一项现在看不到",   # 上次报过连续失败时，换成「看不到了」那一行
        impact="这台的 job 连续失败时不会报警",
        pre=pre, steps=[] if f.get("_recover") else steps,   # 恢复卡里不再列：采样已经回来了
        links=[L_MON] + ([L_TOKEN] if auth else []))

def t_unseen(key, why):   # 上次报过、这次量不到的一条，没有别的告警挡着它：单列一节，写明为什么量不到
    if why == "skip":
        fact = "%s 里没有只读 token 或 `GH_REPO=`，这一项没在查" % code(ENVF)
        impact, links = "这台的 job 连续失败时不会报警", [L_MON, L_TOKEN]
        steps = ["看 %s 里 `GH_REPO=`、`CI_HEALTH_GH_TOKEN=` 两行还在不在" % code(ENVF),
                 "少了哪行补哪行；没有 token 就" + NEW_TOKEN, "下一小时 " + JOBS_BACK]
    elif why == "no-runner":
        fact = "这台的 ci-health 是按没有 runner 服务装的，这一项没在查"
        impact, links = "这台的 job 连续失败、runner 不在接 job 时都不会报警", [L_UPDATE]
        steps = ["这台注册过 runner 的话，按下面手册「更新已部署的机器」重新换上 `/usr/local/bin/ci-health.sh`，服务名要填上"]
    elif why == "fixedwork":
        fact = "定长任务这次没跑出结果，这一项没在查"
        impact, links = "这台 CPU 变慢时不会报警", [L_CPU]
        steps = ["原因见日志：%s" % code("grep 定长任务没跑出结果 %s | tail -3" % LOG), "下一小时会自动再试，" + FIXED_BACK]
    else:
        fact, impact, links, steps = "这一项这次没量到（%s）" % code(why), "", [], []
    return dict(facts=[fact, "上次报的「%s」看不到了，不算消除" % label(key)], impact=impact,
                pre=ROOT_PRE, steps=steps, links=links)

TEMPLATES = {"contention": t_contention, "disk_crit": t_disk_crit, "disk_warn": t_disk_warn, "config": t_config,
             "runner": t_runner, "listener": t_listener, "streak": t_streak, "jobsprobe": t_jobsprobe}
def items(key, f):
    t = TEMPLATES.get(key)
    return t(f) if t else dict(facts=[txt(f.get("text") or key)], impact="", steps=[], links=[])

def ul(xs):
    return "\n".join("- " + x for x in xs)
def ol(xs):
    return "\n".join("%d. %s" % (i, x) for i, x in enumerate(xs, 1))
def todo(it):   # 先做什么：前提一句（有的话）加有序列表
    return (it["pre"] + "\n\n" if it.get("pre") else "") + ol(it["steps"])
def sections(secs):
    return "\n\n".join("#### %d. %s\n%s" % (i, h, c) for i, (h, c) in enumerate(secs, 1))

def card(title, subtitle, template, content):
    header = {"title": {"tag": "plain_text", "content": title}, "template": template}
    if subtitle:
        header["subtitle"] = {"tag": "plain_text", "content": subtitle}
    return {"schema": "2.0", "config": {"update_multi": True, "summary": {"content": title}},
            "header": header, "body": {"elements": [{"tag": "markdown", "content": content}]}}

# 标题先写机器（runner 注册名，没有才用主机名），再写最严重那条和它的级别。副标题只放各级条数和这次的变化，
# 不放主机名：标题已经分开了几台机器，云上的默认主机名又常是一串编号，和注册名的编号容易看反。
def alert_card():
    alerts = []
    for line in (E.get("CARD_ALERTS") or "").split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        f = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
        alerts.append((parts[0], "CRIT" if parts[1:2] == ["CRIT"] else "WARN", f))
    alerts.sort(key=lambda a: a[1] != "CRIT")      # CRIT 在前；同级保持脚本里的检查顺序
    keys = [a[0] for a in alerts]
    new, gone = [k for k in keys if k not in PREV], [k for k in PREV if k not in keys]
    unseen = [k for k in gone if k in BLOCKED_BY and BLOCKED_BY[k][0] in keys]   # 写进挡住它的那一条
    loose = sorted((k for k in gone if k not in unseen and k in UNSEEN), key=lambda k: LEVELS[k] != "CRIT")  # 没有告警挡着：单列一节，CRIT 在前
    gone = [k for k in gone if k not in unseen and k not in loose]
    crit = sum(a[1] == "CRIT" for a in alerts)
    if not PREV:
        change = "新出现"
    elif not (new or gone or unseen or loose):
        change = "超过 24 小时未消除，再提醒一次"
    else:
        change = "，".join(x for x in ("新出现 %d 条" % len(new) if new else "", "消除 %d 条" % len(gone) if gone else "",
                                      "%d 条看不到了" % (len(unseen) + len(loose)) if unseen or loose else "") if x)
    def facts(key, it):   # 这条让哪几条量不到了，写在这条的情况里；有的话不再写通用的那一句
        lost = ["上次报的「%s」看不到了%s，不算消除" % (label(u), "（%s）" % BLOCKED_BY[u][1] if BLOCKED_BY[u][1] else "")
                for u in unseen if BLOCKED_BY[u][0] == key]
        return it["facts"] + (lost or ([it["hint"]] if it.get("hint") else []))
    # 每条一节：告警在前，看不到了的在后。(多条时的节标题, 单条时的标题, 内容, 情况)
    entries = [(headline(k, lv, f, md=True) + ("（新）" if PREV and k in new else ""), headline(k, lv, f), it, facts(k, it))
               for k, lv, f in alerts for it in [items(k, f)]]
    entries += [(label(k) + " 看不到了", "「%s %s」看不到了" % (LEVELS[k], NAMES[k]), it, it["facts"])
                for k in loose for it in [t_unseen(k, UNSEEN[k])]]
    title = "[CI runner 告警] %s：%s%s" % (RUNNER or HOST or "?", entries[0][1],
                                          "，等 %d 条" % len(entries) if len(entries) > 1 else "")
    subtitle = " · ".join(x for x in (counts([a[1] for a in alerts]), change) if x)
    if len(entries) == 1:
        _, _, it, fs = entries[0]
        secs = [("情况", ul(fs + (["同时消除：" + "、".join(label(g) for g in gone)] if gone else [])))]
        if it["impact"]:
            secs.append(("影响", it["impact"]))
        if it["steps"]:
            secs.append(("先做什么", todo(it)))
        secs.append(("去哪看", ul(it["links"] + [LOG_LINE])))
        content = sections(secs)
    else:
        blocks = []
        for i, (head, _, it, fs) in enumerate(entries, 1):
            blk = ["#### %d. %s\n**情况**\n%s" % (i, head, ul(fs))]
            if it["impact"]:
                blk.append("**影响**\n" + it["impact"])
            if it["steps"]:
                blk.append("**先做什么**\n" + todo(it))
            if it["links"]:
                blk.append("**去哪看**\n" + ul(it["links"]))
            blocks.append("\n\n".join(blk))
        if gone:
            blocks.append("#### %d. 已消除\n%s" % (len(entries) + 1, ul(label(g) for g in gone)))
        blocks.append(LOG_LINE)
        content = "\n\n".join(blocks)
    return card(title, subtitle, "red" if crit else "orange", content)

# 恢复只说明这次整点检查没再报，不代表原因查清了，所以照样列出告警时各条的先做什么，没做完的接着做
def recover_card():
    prev = sorted(PREV, key=lambda k: LEVELS.get(k) != "CRIT")   # CRIT 在前
    base = {"svc": SVC, "repo": REPO, "runner_home": RUNNER_HOME, "_recover": "1"}
    steps, links = [], []
    for k in prev:
        if k not in TEMPLATES:
            continue
        it = TEMPLATES[k](dict(base))
        if it["steps"]:
            steps.append("**%s**\n%s" % (label(k), todo(it)))
        links += [l for l in it["links"] if l not in links]
    handle = "这次整点检查没再报，不代表原因查清了。" + (
        "告警时的这几步没做完的，接着做：\n\n" + "\n\n".join(steps) if steps else "告警时开始的排查没做完的，接着做")
    was = "之前的告警这次都没再出现" + ("：\n" + ul(label(k) for k in prev) if prev else "")
    return card("[CI runner 恢复] %s：告警已全部消除" % (RUNNER or HOST or "?"),
                "之前 " + counts([LEVELS.get(k) for k in prev]) if prev else "", "green",
                sections([("情况", was), ("要不要处理", handle), ("去哪看", ul(links + [LOG_LINE]))]))

# ---- 发送：飞书对签名错、关键词不符等也回 HTTP 200，成败只看返回体里的 code（没有才看旧版 StatusCode），0 为成功 ----
def clip(s, n=400):
    s = re.sub(r"\s+", " ", s or "")
    return s if len(s) <= n else s[:n] + "…"
def send(payload):
    body = dict(payload)
    if SECRET:   # 每次发都重新取时间戳、重新签名
        ts = str(int(time.time()))
        body["timestamp"] = ts
        body["sign"] = base64.b64encode(hmac.new(f"{ts}\n{SECRET}".encode(), b"", hashlib.sha256).digest()).decode()
    status = 200
    try:   # 地址写错时 Request() 自己就会报错，也要在 try 里
        req = urllib.request.Request(URL, data=json.dumps(body, ensure_ascii=False).encode(),
                                     headers={"Content-Type": "application/json; charset=utf-8"})
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read(65536).decode(errors="replace")
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            raw = e.read(65536).decode(errors="replace")
        except Exception:
            raw = ""
    except Exception as e:
        return None, "请求失败：%s: %s" % (type(e).__name__, clip(redact(e), 200))
    raw = redact(raw)
    try:
        obj = json.loads(raw)
    except ValueError:
        obj = None
    c = (obj.get("code", obj.get("StatusCode")) if isinstance(obj, dict) else None)
    if not isinstance(c, int) or isinstance(c, bool):
        return None, "HTTP %d，返回体认不出：%s" % (status, clip(raw))
    return c, clip(raw)
def send_retry(payload):
    c, raw = send(payload)
    if c == RATE_LIMITED:   # 限流：等一会儿、重新签名再发一次
        time.sleep(BACKOFF_S)
        c, raw = send(payload)
    return c, raw

text_payload = {"msg_type": "text", "content": {"text": TEXT}}
note = ""
try:
    payload = {"msg_type": "interactive", "card": recover_card() if KIND == "recover" else alert_card()}
    if len(json.dumps(payload, ensure_ascii=False).encode()) > MAX_BODY:
        payload, note = text_payload, "告警卡片超过 %d 字节，改发了文本" % MAX_BODY
except Exception as e:   # 卡片拼不出来也不能让告警丢掉
    payload, note = text_payload, "告警卡片拼装出错（%s: %s），改发了文本" % (type(e).__name__, clip(redact(e), 200))
c, raw = send_retry(payload)
if c in CARD_REJECTED and payload is not text_payload:
    note = "告警卡片被飞书拒收（%d，%s；返回体：%s），改发了文本" % (c, REASONS[c], raw)
    c, raw = send_retry(text_payload)
if c == 0:
    print(note)
    sys.exit(0)
print("%s%s" % ("飞书返回 %d（%s）：" % (c, REASONS.get(c, "未知返回码，对照飞书自定义机器人文档")) if c is not None else "", raw)
      + ("；之前：" + note if note else ""))
sys.exit(1)
PY
)
  rc=$?
  # python 之外的报错（比如 traceback）也会进 resp：写日志前同样把地址、密钥和机器人 ID 换掉
  resp=${resp//$'\n'/ }
  resp=${resp//"$CI_ALERT_WEBHOOK"/<已隐去>}
  [ -n "${CI_ALERT_SECRET:-}" ] && resp=${resp//"$CI_ALERT_SECRET"/<已隐去>}
  hid=${CI_ALERT_WEBHOOK%/}; hid=${hid##*/}; [ "${#hid}" -ge 8 ] && resp=${resp//"$hid"/<已隐去>}
  if [ "$rc" -eq 0 ]; then
    [ -z "${resp// /}" ] || echo "$(date -Is) WARN $resp" >> "$LOG"
    return 0
  fi
  echo "$(date -Is) WARN 告警推送失败：$resp" >> "$LOG"; return 1
}
# 量不到的检查交给卡片：每行「key<TAB>原因代号」
unseen_kv=$(for u in "${UNSEEN[@]+"${UNSEEN[@]}"}"; do k=${u%%|*}; r=${u#*|}; printf '%s\t%s\n' "$k" "${r%%|*}"; done)
if [ -n "${CI_ALERT_WEBHOOK:-}" ]; then
  mkdir -p "$STATE_DIR"
  keys=$(for a in "${ALERTS[@]+"${ALERTS[@]}"}"; do printf '%s\n' "${a%%|*}"; done | sort -u | tr '\n' ' ')
  prev=$(cat "$STATE_DIR/keys" 2>/dev/null)
  last=$(stat -c %Y "$STATE_DIR/keys" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$keys" != "$prev" ] || { [ -n "$keys" ] && [ $((now - last)) -ge 86400 ]; }; then
    # 卡片标题用 runner 注册名（GitHub 上 job 页面「Set up job」和 Settings → Runners 里显示的就是它），读不到才用主机名。
    # 几台机器推到同一个群时，只看主机名分不清哪台是哪台：云上的默认主机名常常是一串编号。
    rn=$(RUNNER_FILE="$RUNNER_HOME/.runner" python3 -c 'import json,os;print(json.load(open(os.environ["RUNNER_FILE"],encoding="utf-8-sig")).get("agentName",""))' 2>/dev/null)
    hn=$(hostname -s)
    host="${rn:+$rn（}${hn}${rn:+）}"
    # 上次报过、这次没报，但这次量不到的（UNSEEN 里有）不算消除：只剩这种时也发告警卡，标「看不到了」，不发恢复卡。
    # 推送成功后状态文件里不再有它：下次量得到、又出了问题，按新出现报
    lost=()
    for u in "${UNSEEN[@]+"${UNSEEN[@]}"}"; do
      case " $prev " in *" ${u%%|*} "*) case " $keys " in *" ${u%%|*} "*) ;; *) lost+=("${u#*|*|}") ;; esac ;; esac
    done
    # 文本消息只在卡片发不了时用，和原来的格式相同
    if [ -n "$keys" ] || [ "${#lost[@]}" -gt 0 ]; then
      body="[CI runner 告警] $host"
      for a in "${ALERTS[@]+"${ALERTS[@]}"}"; do body+=$'\n'"· ${a#*|}"; done
      for a in "${lost[@]+"${lost[@]}"}"; do body+=$'\n'"· $a"; done
      notify alert "$body"
    else
      notify recover "[CI runner 恢复] $host：之前的告警已全部消除"
    fi && printf '%s' "$keys" > "$STATE_DIR/keys"
  fi
fi
exit 0
