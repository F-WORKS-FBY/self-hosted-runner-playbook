#!/usr/bin/env bash
# 在已经装好「重」runner 实例的 CI 机上，再加一个只接轻任务的 runner 实例（标签 metta-ci-light）。
#
# 为什么要它：预检、PR 描述检查、纯文档 PR 的检查只要几十秒到几分钟，却要排在一小时的重检查后面；
# 放到托管机上跑又要花托管分钟。轻实例和重实例各接各的标签，互不抢槽。
#
# 它和重实例的区别：
#   · 单独的系统用户（默认 runner-light），不进 docker 组：轻任务不起容器，PR 代码在这个实例上碰不到 docker；
#   · 不挂清理钩子：它不产生容器和镜像，没有要清的东西；
#   · 内存上限 1536M、CPU 一个核、OOM 分值 1000：内存吃紧时内核先杀它的进程，重检查不受连累（被杀的 job 要手动重跑）。
#
# 用法（root；注册 token 从标准输入读，不进命令行参数与 shell 历史）。在有仓库管理权限的机器上：
#   scp scripts/add-light-runner.sh <机器>:/root/add-light-runner.sh
#   gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token \
#     | ssh <机器> 'bash /root/add-light-runner.sh <runner 名>'
# 重跑安全：已经注册过（有 .runner）就只补服务配置，不重新注册，不用给 token；轻实例上正在跑的 job 不受影响。
#
# 不做的事：不动重实例的服务、钩子；/etc/ci-runner.env 里只加一行 LIGHT_SVC=（ci-health.sh 读到才查轻实例），
# 别的行不动；不重启 docker。
#
# 回退（root）：systemctl disable --now <轻实例的服务>，删掉 /etc/ci-runner.env 里的 LIGHT_SVC= 那一行
# （不删的话 ci-health 每小时报一次「轻任务 runner 没在接任务」）。workflow 那边怎么切回托管见 10 章 10.6。
set -euo pipefail

NAME="${1:?用法：add-light-runner.sh <runner 名，如 metta-ci-hetzner-light>（注册 token 从标准输入读）}"
GH_REPO="${GH_REPO:-Antiheroism/metta-app}"
LIGHT_USER="${LIGHT_USER:-runner-light}"
LIGHT_HOME="${LIGHT_HOME:-/opt/actions-runner-light}"
LIGHT_LABELS="${LIGHT_LABELS:-metta-ci-light}"
LIGHT_MEM_MAX="${LIGHT_MEM_MAX:-1536M}"
# 与本机重实例同一个版本；校验值取自 GitHub 发布页该文件的 digest
RV="${RUNNER_VERSION:-2.338.2}"
RV_SHA256="${RUNNER_SHA256:-baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40}"

[ "$(id -u)" = 0 ] || { echo "要用 root 执行" >&2; exit 1; }
info(){ printf '  %s\n' "$*"; }
step(){ printf '\n== %s\n' "$*"; }

step "1/7 系统用户（不进 docker 组）"
id "$LIGHT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$LIGHT_USER"
if id -nG "$LIGHT_USER" | tr ' ' '\n' | grep -qx docker; then
  echo "$LIGHT_USER 在 docker 组里，轻实例不该有 docker 权限" >&2; exit 1
fi
info "$(id "$LIGHT_USER")"

step "2/7 runner 程序 $RV"
mkdir -p "$LIGHT_HOME"
if [ ! -f "$LIGHT_HOME/config.sh" ]; then
  T=$(mktemp /tmp/runner-light.XXXXXX.tar.gz)
  curl -fsSLo "$T" "https://github.com/actions/runner/releases/download/v${RV}/actions-runner-linux-x64-${RV}.tar.gz"
  echo "${RV_SHA256}  $T" | sha256sum -c - >/dev/null || { echo "runner 包校验值不对，已中止" >&2; rm -f "$T"; exit 1; }
  tar xzf "$T" -C "$LIGHT_HOME"; rm -f "$T"
  info "已下载并校验"
else
  info "已有程序文件，跳过下载"
fi
chown -R "$LIGHT_USER:$LIGHT_USER" "$LIGHT_HOME"

step "3/7 注册（标签 $LIGHT_LABELS）"
if [ ! -f "$LIGHT_HOME/.runner" ]; then
  IFS= read -r REG || true
  [ -n "${REG:-}" ] || { echo "标准输入里没有注册 token" >&2; exit 1; }
  # 不带 --replace：同名注册已存在就让它失败，别悄悄顶掉另一台
  sudo -u "$LIGHT_USER" bash -c "cd '$LIGHT_HOME' && ./config.sh --unattended \
    --url 'https://github.com/${GH_REPO}' --token '$REG' \
    --name '$NAME' --labels '$LIGHT_LABELS' --work _work" >/dev/null
  info "已注册：$NAME"
else
  info "已注册过，跳过"
fi
chmod 0600 "$LIGHT_HOME/.credentials" "$LIGHT_HOME/.runner" 2>/dev/null || true
# 只写 LANG，不挂 ACTIONS_RUNNER_HOOK_*
printf 'LANG=en_US.UTF-8\n' > "$LIGHT_HOME/.env"; chown "$LIGHT_USER:$LIGHT_USER" "$LIGHT_HOME/.env"; chmod 0600 "$LIGHT_HOME/.env"

step "4/7 systemd 服务"
SVC="actions.runner.$(printf '%s' "$GH_REPO" | tr '/' '-').${NAME}.service"
[ -f "/etc/systemd/system/$SVC" ] || ( cd "$LIGHT_HOME" && ./svc.sh install "$LIGHT_USER" >/dev/null )
[ -f "/etc/systemd/system/$SVC" ] || { echo "没找到服务单元 $SVC（svc.sh 生成的名字和预期不一样）" >&2; ls /etc/systemd/system/actions.runner.* >&2; exit 1; }
D="/etc/systemd/system/${SVC}.d"; mkdir -p "$D"
cat > "$D/override.conf" <<CONF
# 轻任务 runner 实例（由 add-light-runner.sh 生成）
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
# 内存吃紧时先杀轻任务的进程，别连累同机的重检查
OOMScoreAdjust=1000
MemoryAccounting=yes
MemoryMax=${LIGHT_MEM_MAX}
CPUQuota=100%
CONF
systemctl daemon-reload

step "5/7 清掉别的用户留下的 /tmp/pr*.json"
# 描述检查把中间文件写在固定路径；别的用户（重实例的 runner）写过的话，/tmp 有粘滞位，轻实例的用户盖不掉，描述检查会失败。
# 只删不属于轻实例用户的：重跑本脚本时，轻实例上正在跑的 job 自己写的那几个不动。
for f in /tmp/pr.json /tmp/pr-files.json /tmp/pr-meta.json; do
  if [ -e "$f" ] && [ "$(stat -c %U "$f" 2>/dev/null)" != "$LIGHT_USER" ]; then rm -f "$f"; fi
done

step "6/7 启动与结果"
systemctl enable --now "$SVC" >/dev/null 2>&1
sleep 5
info "服务：$SVC  $(systemctl is-active "$SVC")"
info "用户：$(systemctl show "$SVC" -p User --value)  MemoryMax=$(systemctl show "$SVC" -p MemoryMax --value)  OOMScoreAdjust=$(systemctl show "$SVC" -p OOMScoreAdjust --value)"
info "监听进程：$(pgrep -x -u "$LIGHT_USER" Runner.Listener >/dev/null && echo 在跑 || echo 不在)"
info "重实例没有动：$(systemctl list-units --type=service --no-legend --plain 'actions.runner.*' | awk '{print $1, $3}' | tr '\n' ' ')"

step "7/7 登记给 ci-health.sh"
# ci-health.sh 从 /etc/ci-runner.env 读 LIGHT_SVC=，读到才查轻实例（服务状态、Runner.Listener、内存峰值）。
# 只动这一行：有就改成现在的服务名，没有就加在末尾。bootstrap.sh 重跑时会把这一行原样写回去。
ENVF="${CI_RUNNER_ENV:-/etc/ci-runner.env}"
if [ -f "$ENVF" ]; then
  TMPF=$(mktemp "$ENVF.XXXXXX")
  K=LIGHT_SVC V="$SVC" awk -F= '$1==ENVIRON["K"]{if(!d) print ENVIRON["K"]"="ENVIRON["V"]; d=1; next} {print} END{if(!d) print ENVIRON["K"]"="ENVIRON["V"]}' "$ENVF" > "$TMPF"
  chmod --reference="$ENVF" "$TMPF"; chown --reference="$ENVF" "$TMPF"; mv -f "$TMPF" "$ENVF"
  info "$ENVF：$(grep '^LIGHT_SVC=' "$ENVF")"
  if grep -q 'LIGHT_SVC' /usr/local/bin/ci-health.sh 2>/dev/null; then
    info "ci-health.sh 下一个整点（第 13 分）起查轻实例"
  else
    info "这台的 /usr/local/bin/ci-health.sh 还不认轻实例：用 scripts/deploy-ci-health.sh 换上新版后才会查"
  fi
else
  info "没有 $ENVF（这台不是 bootstrap.sh 装的），跳过；ci-health.sh 不会查轻实例"
fi
