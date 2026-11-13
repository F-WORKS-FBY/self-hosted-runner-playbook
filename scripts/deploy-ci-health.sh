#!/usr/bin/env bash
# 把仓库里的 ci-health.sh 单独部署到一台已经装好的 CI 机上（不重跑 bootstrap.sh）。
#
# 渲染方式和 bootstrap.sh 第 7 步一样，两个占位符：runner 服务名、手册仓库目录。两个值都沿用机器上现行那份里的，
# 不重新探测：同机有轻任务实例时 actions.runner.* 不止一个，按名字取第一个会取到轻实例的。
# 顺序：
#   1. 确认现行那份等于「上一版源文件」按这两个值渲染的结果。不相等说明机器上被人手改过，停下不换；
#   2. 渲染新版成 .new，查 bash 语法、内嵌的几段 python 语法、占位符有没有剩；
#   3. 用不带推送地址和 token 的临时配置把 .new 试跑一次（日志和状态写临时目录，不推送，不动正式的日志和状态），
#      要有一行采样；/etc/ci-runner.env 里登记了轻任务实例（LIGHT_SVC=）的，采样行里要有 light=；
#   4. 备份现行那份，把 .new 改名替换上去（改名是原子的），再和渲染结果逐字节比对。
#
# 什么时候做：ci-health.sh 不影响正在跑的 job，不用停 runner 服务。但试跑要量一遍 containerd（几十秒磁盘读），
# 所以有 job 在跑时不换（确实要换加 FORCE_WHILE_BUSY=1）；每小时第 13 分 cron 会跑它，第 10～20 分不换，它正在跑时也不换。
#
# 用法（root）。在手册仓库里：
#   scp scripts/ci-health.sh <机器>:/root/ci-health.src.sh
#   git show <机器上那一版所在的提交>:scripts/ci-health.sh | ssh <机器> 'cat > /root/ci-health.prev.sh'
#   scp scripts/deploy-ci-health.sh <机器>:/root/ && ssh <机器> 'bash /root/deploy-ci-health.sh'
# 回退：cp -p <备份> /usr/local/bin/ci-health.sh（备份的路径在最后一行输出里）。
#
# 演练或装到别处时路径都能换：CI_HEALTH_DEST（现行那份）、CI_HEALTH_BACKUP_DIR（备份放哪）、CI_RUNNER_ENV；
# CI_HEALTH_DEST 不是默认值时不要求 root。
set -euo pipefail
SRC="${1:-/root/ci-health.src.sh}"
PREV="${2:-/root/ci-health.prev.sh}"
DEST="${CI_HEALTH_DEST:-/usr/local/bin/ci-health.sh}"
BACKUP_DIR="${CI_HEALTH_BACKUP_DIR:-/root}"
ENVF="${CI_RUNNER_ENV:-/etc/ci-runner.env}"
CRON_MINUTE=13   # bootstrap.sh 写进 /etc/cron.d/ci-health 的那一分

[ "$DEST" != /usr/local/bin/ci-health.sh ] || [ "$(id -u)" = 0 ] || { echo "要用 root 执行" >&2; exit 1; }
for f in "$SRC" "$PREV" "$DEST"; do [ -f "$f" ] || { echo "没有这个文件：$f" >&2; exit 1; }; done
grep -q '^SVC="__RUNNER_SVC__"' "$SRC" && grep -q '^PLAYBOOK_DIR="__PLAYBOOK_DIR__"$' "$SRC" \
  || { echo "$SRC 不像没渲染过的 ci-health.sh 源文件（找不到两个占位符）" >&2; exit 1; }

# 两个值从现行那份里取。只放行 sed 替换串里没有特殊含义的字符
SVC=$(sed -n 's/^SVC="\([^"]*\)".*/\1/p' "$DEST" | head -1)
PB_DIR=$(sed -n 's/^PLAYBOOK_DIR="\([^"]*\)"$/\1/p' "$DEST" | head -1)
case "$SVC" in ''|*[!A-Za-z0-9_.@-]*) echo "从 $DEST 里取不到 runner 服务名（SVC=\"$SVC\"），不换。这台是按没有 runner 服务装的话，那一行应是 none" >&2; exit 1 ;; esac
case "$PB_DIR" in *[!A-Za-z0-9_./-]*) echo "从 $DEST 里取到的手册仓库目录有特殊字符（$PB_DIR），不换" >&2; exit 1 ;; esac
echo "沿用现行那份的两个值：runner 服务 $SVC，手册仓库目录 ${PB_DIR:-<空>}"
[ "$SVC" != none ] || echo "注意：服务名是 none，这台的 ci-health 不查 runner 服务、listener 和连续失败。这台注册过 runner 的话先停下来查（08 章 8.7）"
render(){ sed -e "s#__RUNNER_SVC__#${SVC}#" -e "s#__PLAYBOOK_DIR__#${PB_DIR}#" "$1"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/deploy-health.XXXXXX"); trap 'rm -rf "$T"; rm -f "$DEST.new"' EXIT
render "$SRC" > "$T/new.rendered"
if cmp -s "$T/new.rendered" "$DEST"; then
  echo "现行那份已经是新版的渲染结果，不用换：$(sha256sum "$DEST" | cut -c1-16)"; exit 0
fi
render "$PREV" > "$T/prev.rendered"
if ! cmp -s "$T/prev.rendered" "$DEST"; then
  echo "现行那份和上一版源文件的渲染结果不一样（机器上被改过，或者给的不是机器上那一版），不换：" >&2
  diff "$T/prev.rendered" "$DEST" | head -20 >&2; exit 1
fi
echo "现行那份 = 上一版源文件的渲染结果（$(sha256sum "$DEST" | cut -c1-16)）"

# 什么时候不换
m=$((10#$(date +%M)))
if [ "$m" -ge $((CRON_MINUTE - 3)) ] && [ "$m" -le $((CRON_MINUTE + 7)) ] && [ "${FORCE_NEAR_CRON:-0}" != 1 ]; then
  echo "现在是第 $m 分，cron 在第 $CRON_MINUTE 分跑 ci-health，第 $((CRON_MINUTE - 3))～$((CRON_MINUTE + 7)) 分不换，过了再来" >&2; exit 1
fi
if pgrep -fx "(/usr/bin/|/bin/)?(ba)?sh( -c)? $DEST" >/dev/null 2>&1; then
  echo "ci-health.sh 正在跑（磁盘贴近 WARN 线时它会等 job 之间的空档，最长 25 分钟），等它结束再换" >&2; exit 1
fi
if pgrep -x Runner.Worker >/dev/null 2>&1 && [ "${FORCE_WHILE_BUSY:-0}" != 1 ]; then
  echo "有 job 在跑，先不换；确实要换就加 FORCE_WHILE_BUSY=1" >&2; exit 1
fi

# 渲染新版，查语法
cp "$T/new.rendered" "$DEST.new"; chmod 0755 "$DEST.new"
echo "新旧差异 $(diff "$DEST" "$DEST.new" | grep -c '^[<>]' || true) 行"
bash -n "$DEST.new" || { echo "新版 bash 语法不过，现行那份没动" >&2; exit 1; }
if grep -q '__RUNNER_SVC__\|__PLAYBOOK_DIR__' "$DEST.new"; then
  echo "新版还有没替换的占位符，现行那份没动" >&2; exit 1
fi
# 内嵌的 python（定长任务、job 采样、拼卡片与推送）平时只有跑到那一步才会发现语法错，这里先编译一遍
npy=$(python3 - "$DEST.new" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY\n", src, re.S)
for i, b in enumerate(blocks, 1):
    compile(b, "ci-health.sh 第 %d 段 python" % i, "exec")
print(len(blocks))
PY
) || { echo "新版内嵌的 python 语法不过，现行那份没动" >&2; exit 1; }
[ "${npy:-0}" -ge 3 ] || { echo "新版里只找到 ${npy:-0} 段内嵌 python（应不少于 3 段），现行那份没动" >&2; exit 1; }
echo "语法：bash 通过，内嵌 python $npy 段通过，没有剩下的占位符"

# 试跑：不带推送地址和 token（CI_HEALTH_ENV 指向空文件），日志和状态写临时目录。有告警时本机 journal 里会多一行，不推送
: > "$T/empty.env"; mkdir -p "$T/state"
if ! env -u CI_ALERT_WEBHOOK -u CI_ALERT_SECRET -u GH_TOKEN -u CI_HEALTH_GH_TOKEN -u GH_REPO \
     CI_HEALTH_LOG="$T/try.log" CI_HEALTH_STATE_DIR="$T/state" CI_HEALTH_ENV="$T/empty.env" CI_RUNNER_ENV="$ENVF" \
     CI_HEALTH_IDLE_WAIT=0 bash "$DEST.new"; then
  echo "新版试跑的退出码不是 0，现行那份没动" >&2; exit 1
fi
line=$(grep ' fixedwork=' "$T/try.log" 2>/dev/null | head -1 || true)
[ -n "$line" ] || { echo "新版试跑没有写出采样行，现行那份没动" >&2; exit 1; }
echo "试跑的采样行：$line"
light=$(sed -n 's/^LIGHT_SVC=//p' "$ENVF" 2>/dev/null | head -1 || true)
if [ -n "$light" ] && [ "$light" != none ]; then
  case "$line" in
    *" light=active light_listener="[0-9]*) echo "轻任务实例：$light 在接任务" ;;
    *" light="*) echo "轻任务实例：$light 这次试跑看着不正常（见上面采样行的 light=、light_listener=），换上以后下一个整点会告警" ;;
    *) echo "$ENVF 里登记了轻任务实例（$light），新版试跑的采样行里却没有 light=，现行那份没动" >&2; exit 1 ;;
  esac
else
  echo "轻任务实例：$ENVF 里没有登记（没有 LIGHT_SVC= 这一行），新版不查它"
fi
grep -v ' fixedwork=' "$T/try.log" | sed 's/^/试跑时报的（没有推送）：/' || true

# 备份、替换、比对
BAK="$BACKUP_DIR/ci-health.sh.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$DEST" "$BAK"
mv -f "$DEST.new" "$DEST"
cmp -s "$T/new.rendered" "$DEST" || { echo "替换后和渲染结果不一致，用备份回退：cp -p $BAK $DEST" >&2; exit 1; }
echo "已替换：$(sha256sum "$DEST" | cut -c1-16)  备份在 $BAK（回退：cp -p $BAK $DEST）"
rm -f "$SRC" "$PREV"
