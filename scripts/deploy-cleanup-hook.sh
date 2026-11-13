#!/usr/bin/env bash
# 把仓库里的 ci-cleanup.sh 单独部署到一台已经装好的 CI 机上（不重跑 bootstrap.sh）。
#
# 做法和 bootstrap.sh 第 7 步一样：按 /etc/ci-runner.env 里的参数渲染成 .new，以 runner 的真实调用方式
# （bash -e）试跑通过，再替换正式钩子。多做一件事：先确认现行钩子等于「上一版源文件」的渲染结果，
# 不相等说明机器上被人手改过，停下不换。
#
# 用法（root）：
#   scp scripts/ci-cleanup.sh <机器>:/root/ci-cleanup.src.sh
#   git show HEAD~1:scripts/ci-cleanup.sh | ssh <机器> 'cat > /root/ci-cleanup.prev.sh'   # 现在机器上那一版的源文件
#   scp scripts/deploy-cleanup-hook.sh <机器>:/root/ && ssh <机器> 'bash /root/deploy-cleanup-hook.sh'
set -euo pipefail
SRC="${1:-/root/ci-cleanup.src.sh}"
PREV="${2:-/root/ci-cleanup.prev.sh}"
ENVF="${CI_RUNNER_ENV:-/etc/ci-runner.env}"
[ "$(id -u)" = 0 ] || { echo "要用 root 执行" >&2; exit 1; }

# /etc/ci-runner.env 的值里有空格且不带引号，不能直接 source
val(){ sed -n "s/^$1=//p" "$ENVF" | head -1; }
RUNNER_USER=$(val RUNNER_USER); RUNNER_HOME=$(val RUNNER_HOME)
CI_APP_PORTS=$(val CI_APP_PORTS); CI_LABEL=$(val CI_LABEL)
CI_PER_RUN_IMAGE_LABEL=$(val CI_PER_RUN_IMAGE_LABEL); CI_TMP_GLOBS=$(val CI_TMP_GLOBS)
HOOK="$RUNNER_HOME/hooks/ci-cleanup.sh"
render(){ sed -e "s#__CI_APP_PORTS__#${CI_APP_PORTS}#" -e "s#__CI_LABEL__#${CI_LABEL}#" \
              -e "s#__CI_PER_RUN_IMAGE_LABEL__#${CI_PER_RUN_IMAGE_LABEL}#" -e "s#__CI_TMP_GLOBS__#${CI_TMP_GLOBS}#" "$1"; }

T=$(mktemp -d /tmp/deploy-hook.XXXXXX); trap 'rm -rf "$T"' EXIT
render "$PREV" > "$T/prev.rendered"
if ! cmp -s "$T/prev.rendered" "$HOOK"; then
  echo "现行钩子和上一版源文件的渲染结果不一样（机器上被改过？），不换：" >&2
  diff "$T/prev.rendered" "$HOOK" | head -20 >&2; exit 1
fi
echo "现行钩子 = 上一版源文件的渲染结果"

render "$SRC" > "$HOOK.new"; chmod 0755 "$HOOK.new"; chown "$RUNNER_USER:$RUNNER_USER" "$HOOK.new"
echo "新旧差异 $(diff "$HOOK" "$HOOK.new" | grep -c '^[<>]' || true) 行"

n=$(pgrep -cx -u "$RUNNER_USER" Runner.Worker 2>/dev/null || true)
[ "${n:-0}" = 0 ] || { echo "有 job 在跑，先不换（.new 已删）" >&2; rm -f "$HOOK.new"; exit 1; }
if ! sudo -u "$RUNNER_USER" /usr/bin/bash -e "$HOOK.new"; then
  echo "按 runner 的调用方式（bash -e）试跑失败，正式钩子没动" >&2; rm -f "$HOOK.new"; exit 1
fi
if grep -qE '^(L|APP_PORTS|PER_RUN_LABEL|TMP_GLOBS)=.*__CI_' "$HOOK.new"; then
  echo "还有没替换的占位符，正式钩子没动" >&2; rm -f "$HOOK.new"; exit 1
fi
cp -p "$HOOK" "/root/ci-cleanup.sh.bak-$(date +%Y%m%d)"
mv -f "$HOOK.new" "$HOOK"
echo "已替换：$(sha256sum "$HOOK" | cut -c1-16)  备份在 /root/ci-cleanup.sh.bak-$(date +%Y%m%d)"
rm -f "$SRC" "$PREV"
