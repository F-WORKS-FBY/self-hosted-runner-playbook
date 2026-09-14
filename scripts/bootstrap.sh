#!/usr/bin/env bash
# bootstrap.sh —— 把一台干净的 Ubuntu 机器装成 GitHub Actions 自建 CI runner。
#
# **幂等**：重复跑不会破坏已有配置，只补齐缺的。已在一台配置完成的机器上重跑验证过。
# 必须 root 运行。
#
# 用法：
#   GH_REPO=owner/repo GH_TOKEN=ghp_xxx bash bootstrap.sh
#   GH_REPO=owner/repo GH_TOKEN=ghp_xxx bash bootstrap.sh --harden-ssh
#   bash bootstrap.sh --skip-runner        # 只装工具链与加固，不注册 runner
#
# GH_TOKEN 只在**注册那一刻**用一次（换取 registration token），脚本不会把它写到任何文件里。
# 建议用 fine-grained PAT，只给目标仓库的 Administration: read&write。用完即撤销。
#
# ⚠️ --harden-ssh 默认**不做**。它是唯一可能把你锁在门外的动作，
#    不该在无人值守的脚本里默认发生。见文末 harden_ssh 的注释。
set -euo pipefail

# ──────────────────────────── 参数（全部可用环境变量覆盖）────────────────────────────
GH_REPO="${GH_REPO:?必须设 GH_REPO，形如 owner/repo}"
RUNNER_NAME="${RUNNER_NAME:-ci-$(hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,ci}"   # 建议再加一个项目专属标签
RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_HOME="${RUNNER_HOME:-/opt/actions-runner}"
NODE_MAJOR="${NODE_MAJOR:-22}"
PNPM_VERSION="${PNPM_VERSION:-}"          # 留空则不预装 pnpm，交给 workflow 的 action 处理
RUNNER_MEM_MAX="${RUNNER_MEM_MAX:-6G}"    # 按「单 job 实测峰值 × 1.3」定
BUILDKIT_RESERVED="${BUILDKIT_RESERVED:-10GB}"
BUILDKIT_MAX_USED="${BUILDKIT_MAX_USED:-20GB}"
BUILDKIT_MIN_FREE="${BUILDKIT_MIN_FREE:-20GB}"
CI_LABEL="${CI_LABEL:-com.ci.selfhosted=1}"   # 必须与 workflow 里 docker run --label 的值一致
CI_APP_PORTS="${CI_APP_PORTS:-}"          # e2e 等会在**宿主**上监听的端口，清理时要杀孤儿。例：3100 3101
CI_FIXEDWORK_BASELINE="${CI_FIXEDWORK_BASELINE:-0}"   # preflight --with-load 给的 p50；0 = 只记录不告警
METADATA_IP="${METADATA_IP:-169.254.169.254}"

HARDEN_SSH=0; SKIP_RUNNER=0
for a in "$@"; do
  case "$a" in
    --harden-ssh)  HARDEN_SSH=1 ;;
    --skip-runner) SKIP_RUNNER=1 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "必须 root 运行" >&2; exit 1; }

SVC=""   # runner 的 systemd 单元名，注册后填
step(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
info(){ printf '  %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────── 1. 基础工具链 ────────────────────────────
step "1/8 基础工具"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg jq git tar unzip zstd psmisc python3 >/dev/null
info "ca-certificates curl gnupg jq git tar unzip zstd psmisc python3 ✓"
# psmisc 提供 fuser —— 清理孤儿进程要用

step "2/8 Docker CE（官方源）"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
info "$(docker --version | cut -d, -f1) / buildx $(docker buildx version | awk '{print $2}')"

step "3/8 Node ${NODE_MAJOR} + pnpm + gh"
# Node 用官方 tarball 装到 /opt/node —— 与 actions/setup-node 拿的是同一份构建，
# 避免发行版包管理器的版本漂移。setup-node 之后仍会自己管版本，这份是给 runner 自身与脚本用的。
if ! command -v node >/dev/null || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" != "$NODE_MAJOR" ]; then
  NV=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r --arg m "v${NODE_MAJOR}." '[.[]|select(.version|startswith($m))][0].version')
  curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/${NV}/node-${NV}-linux-x64.tar.xz"
  rm -rf /opt/node && mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 && rm -f /tmp/node.tar.xz
  for b in node npm npx corepack; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
fi
info "node $(node -v)"
if [ -n "$PNPM_VERSION" ]; then
  corepack enable >/dev/null 2>&1 || true
  corepack prepare "pnpm@${PNPM_VERSION}" --activate >/dev/null 2>&1 && info "pnpm $(pnpm -v)" || info "pnpm 预装失败，交给 workflow 的 action 处理"
fi
# gh：托管 runner 预装了它，自建的什么都没有。仓库里任何一处没有 || 兜底的 `gh api` 都会硬失败。
if ! command -v gh >/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq && apt-get install -y -qq gh >/dev/null
fi
info "gh $(gh --version | head -1 | awk '{print $3}')"

# ──────────────────────────── 4. Docker 守护进程 ────────────────────────────
step "4/8 Docker 守护进程配置"
# 两件事：
#  ① BuildKit GC 硬上限。出厂默认在小盘上太松（实测 Max Used 55.88GiB / Min Free 13.97GiB），
#     而 build cache 是自建 runner 上最大的磁盘增长源（实测每次镜像构建 +1GB 量级）。
#     ⚠️ 必须用 policy 数组写全三个参数 —— `defaultKeepStorage` 只映射到 Reserved Space，
#        会把 Min Free 保护丢掉（实测踩过）。
#  ② live-restore：不开的话一次 dockerd 重启（比如 unattended-upgrades 触发的）
#     会把当前 job 的 services 容器**当场全灭**，而报错会指向业务代码。
NEW_DAEMON=$(cat <<EOF
{
  "builder": {
    "gc": {
      "enabled": true,
      "policy": [
        { "all": true, "reservedSpace": "${BUILDKIT_RESERVED}", "maxUsedSpace": "${BUILDKIT_MAX_USED}", "minFreeSpace": "${BUILDKIT_MIN_FREE}" }
      ]
    }
  },
  "live-restore": true
}
EOF
)
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ] || ! diff -q <(printf '%s\n' "$NEW_DAEMON") /etc/docker/daemon.json >/dev/null 2>&1; then
  printf '%s\n' "$NEW_DAEMON" > /etc/docker/daemon.json
  python3 -c "import json;json.load(open('/etc/docker/daemon.json'))"
  systemctl restart docker; sleep 4
  info "daemon.json 已更新并重启 docker"
else
  info "daemon.json 已是目标状态，跳过重启"
fi
systemctl enable docker containerd >/dev/null 2>&1 || true
info "live-restore=$(docker info 2>/dev/null | grep -ci 'live restore enabled: true')  BuildKit 上限已设"

# needrestart：Ubuntu 的 APT 钩子默认会自动重启受影响的服务。
# docker 在出厂免打扰名单里，但 containerd **不在** —— 而 Docker 29 的镜像与容器都由它承载。
if [ -d /etc/needrestart ]; then
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/90-ci-containerd.conf <<'EOF'
# CI 机：别在 job 跑到一半时重启容器运行时。
# docker 已在出厂名单（needrestart.conf 的 override_rc 里有 qr(^docker) => 0），containerd 没有。
$nrconf{override_rc}->{qr(^containerd)} = 0;
EOF
  info "needrestart 已豁免 containerd"
fi

# ──────────────────────────── 5. runner 用户与注册 ────────────────────────────
step "5/8 runner 用户与注册"
id "$RUNNER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RUNNER_USER"
usermod -aG docker "$RUNNER_USER"
info "用户 $RUNNER_USER（在 docker 组 —— 注意：docker 组 ≈ 免密宿主 root）"
mkdir -p "$RUNNER_HOME"; chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

if [ "$SKIP_RUNNER" = 0 ]; then
  if [ ! -f "$RUNNER_HOME/config.sh" ]; then
    : "${GH_TOKEN:?注册 runner 需要 GH_TOKEN（用完即撤销），或加 --skip-runner 跳过}"
    RV=$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
    info "下载 runner $RV"
    curl -fsSLo /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RV}/actions-runner-linux-x64-${RV}.tar.gz"
    tar xzf /tmp/runner.tar.gz -C "$RUNNER_HOME"; rm -f /tmp/runner.tar.gz
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
    "$RUNNER_HOME/bin/installdependencies.sh" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$RUNNER_HOME/.runner" ]; then
    : "${GH_TOKEN:?注册 runner 需要 GH_TOKEN}"
    REG=$(curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${GH_REPO}/actions/runners/registration-token" | jq -r .token)
    sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_HOME' && ./config.sh --unattended \
      --url 'https://github.com/${GH_REPO}' --token '$REG' \
      --name '$RUNNER_NAME' --labels '$RUNNER_LABELS' --work _work --replace" >/dev/null
    info "已注册：$RUNNER_NAME  labels=$RUNNER_LABELS"
    # ⚠️ 刻意**不加** --ephemeral：它跑完一个 job 会自己注销并**停掉服务**
    #    （bin/RunnerService.js：exit with 0 return code, stop the service, no retry needed），
    #    要回来必须在机器上常驻管理员凭据 —— 与「用完撤销 token」直接冲突，
    #    而一次没被发现的注销 = 最长 24 小时全员 CI 停摆。
  else
    info "runner 已注册，跳过"
  fi
  ( cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER" >/dev/null 2>&1 || true; ./svc.sh start >/dev/null 2>&1 || true )
  SVC=$(systemctl list-units --type=service --all --no-legend 'actions.runner.*' 2>/dev/null | awk '{print $1}' | head -1)
  [ -z "$SVC" ] && SVC=$(basename "$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)" 2>/dev/null || echo "")
  info "服务单元：${SVC:-<未找到>}"
fi

# ──────────────────────────── 6. systemd 加固 ────────────────────────────
step "6/8 runner systemd 加固"
if [ -n "$SVC" ]; then
  D="/etc/systemd/system/${SVC}.d"; mkdir -p "$D"
  cat > "$D/override.conf" <<EOF
# CI runner 加固（由 bootstrap.sh 生成）
[Unit]
# 出厂 unit 不写 docker 依赖。实测 runner 就绪比 dockerd 只晚 1.3 秒且完全无序，
# 重启后可能先接到 job 再有 docker。
After=docker.service docker.socket
Wants=docker.service
# 必需：systemd 默认 StartLimitBurst=5 / Interval=10s。不关掉的话 Restart=always
# 在连续失败 5 次后会被打成 failed 并**停止重试**，等于白写。
StartLimitIntervalSec=0

[Service]
# 出厂 unit 是 Restart=no —— listener 一死就永久死着，而 GitHub 侧的 online 状态
# 有分钟级延迟，你不会立刻发现。
Restart=always
RestartSec=10
# swap=0 的机器上 OOM 是 kill 不是变慢，而内核按 RSS 挑受害者、不知道谁是客人。
# 这一行让 CI 先死，别把 sshd 或别的东西带走。
OOMScoreAdjust=800
MemoryAccounting=yes
MemoryMax=${RUNNER_MEM_MAX}
EOF
  systemctl daemon-reload
  systemctl restart "$SVC" || true
  sleep 3
  info "Restart=$(systemctl show "$SVC" -p Restart --value)  MemoryMax=${RUNNER_MEM_MAX}  StartLimitInterval=$(systemctl show "$SVC" -p StartLimitIntervalUSec --value)"
else
  info "未找到 runner 服务单元，跳过（--skip-runner 时正常）"
fi

# ──────────────────────────── 7. 清理与监控 ────────────────────────────
step "7/8 清理钩子 + 每日 timer + 健康监控"
mkdir -p "$RUNNER_HOME/hooks"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/ci-cleanup.sh" ]; then
  sed -e "s#__CI_APP_PORTS__#${CI_APP_PORTS}#" -e "s#__CI_LABEL__#${CI_LABEL}#" "$SELF_DIR/ci-cleanup.sh" > "$RUNNER_HOME/hooks/ci-cleanup.sh"
else
  echo "缺少 $SELF_DIR/ci-cleanup.sh" >&2; exit 1
fi
chmod 0755 "$RUNNER_HOME/hooks/ci-cleanup.sh"; chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/hooks/ci-cleanup.sh"

# ⚠️ 装完必须**按 runner 的真实调用方式跑一次**，跑不过就拒绝接线。
#
# 2026-09-07 的事故正是死在这里：钩子装好了、`.env` 挂好了、timer 起来了、
# 文件也可执行 —— 但没有任何一处**执行过它**。runner 调钩子时强加 `-e`，
# 脚本里一条管道返回非零就中止，于是每个 job 都红，连续 7 天 21 个 job 无一幸免，
# 而 systemctl / verify.sh / ci-health.sh 三处全部显示正常。
#
# 这一道门禁的全部价值：把「装上了」和「真能用」区分开。多花 0.2 秒。
if ! sudo -u "$RUNNER_USER" /usr/bin/bash -e "$RUNNER_HOME/hooks/ci-cleanup.sh"; then
  echo "钩子以 runner 的真实调用方式（bash -e）执行失败，拒绝接线 —— 接了就是每个 job 全红" >&2
  echo "复现：sudo -u $RUNNER_USER /usr/bin/bash -ex $RUNNER_HOME/hooks/ci-cleanup.sh" >&2
  exit 1
fi
# 占位符必须全部替换掉。只看赋值行：守卫那行**故意**保留 __CI_ 前缀做判据，不是残留。
if grep -qE '^(L|APP_PORTS)=.*__CI_' "$RUNNER_HOME/hooks/ci-cleanup.sh"; then
  echo "钩子仍含未替换的占位符（赋值行），sed 替换失败" >&2; exit 1
fi
info "钩子已按 runner 的调用方式试跑通过"

# 两个钩子都挂：JOB_STARTED 是主力（对「上一个 job 被 cancel-in-progress 取消」免疫），
# JOB_COMPLETED 顺手。二者都不覆盖「runner 被杀」，所以还要一个每日 timer 兜底。
touch "$RUNNER_HOME/.env"
for k in ACTIONS_RUNNER_HOOK_JOB_STARTED ACTIONS_RUNNER_HOOK_JOB_COMPLETED; do
  grep -q "^$k=" "$RUNNER_HOME/.env" || echo "$k=$RUNNER_HOME/hooks/ci-cleanup.sh" >> "$RUNNER_HOME/.env"
done
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/.env"
info "钩子已挂：$(grep -c ACTIONS_RUNNER_HOOK "$RUNNER_HOME/.env") 个"

cat > /etc/systemd/system/ci-cleanup.service <<EOF
[Unit]
Description=CI docker cleanup (fallback: hooks do not run when a job is cancelled or the runner is killed)
After=docker.service
[Service]
Type=oneshot
ExecStart=$RUNNER_HOME/hooks/ci-cleanup.sh
EOF
cat > /etc/systemd/system/ci-cleanup.timer <<'EOF'
[Unit]
Description=Daily CI docker cleanup
[Timer]
OnCalendar=*-*-* 04:17:00
RandomizedDelaySec=600
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload; systemctl enable --now ci-cleanup.timer >/dev/null 2>&1
info "ci-cleanup.timer $(systemctl is-active ci-cleanup.timer)"

if [ -f "$SELF_DIR/ci-health.sh" ]; then
  sed "s#__RUNNER_SVC__#${SVC:-none}#" "$SELF_DIR/ci-health.sh" > /usr/local/bin/ci-health.sh
  chmod 0755 /usr/local/bin/ci-health.sh
  printf 'CI_FIXEDWORK_BASELINE=%s\n13 * * * * root /usr/local/bin/ci-health.sh\n' "$CI_FIXEDWORK_BASELINE" > /etc/cron.d/ci-health
  chmod 0644 /etc/cron.d/ci-health
  info "健康监控已装（每小时 13 分）"
fi

# ──────────────────────────── 8. 网络加固 ────────────────────────────
step "8/8 挡住 CI 读云 metadata"
# 云 metadata 服务对 CI job 与容器都是可达的，里面常有初始 root 口令、公钥、网络配置。
# 两条规则：容器侧走 DOCKER-USER，宿主侧按 uid 拦 runner 用户。root 仍可读（cloud-init 要用）。
RU_UID=$(id -u "$RUNNER_USER")
iptables -C DOCKER-USER -d "$METADATA_IP" -j DROP 2>/dev/null \
  || iptables -I DOCKER-USER -d "$METADATA_IP" -j DROP
iptables -C OUTPUT -d "$METADATA_IP" -m owner --uid-owner "$RU_UID" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null \
  || iptables -I OUTPUT -d "$METADATA_IP" -m owner --uid-owner "$RU_UID" -j REJECT --reject-with icmp-port-unreachable
if ! dpkg -l iptables-persistent >/dev/null 2>&1; then
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
  apt-get install -y -qq iptables-persistent >/dev/null
fi
netfilter-persistent save >/dev/null 2>&1
info "metadata 拦截规则已生效并持久化（$(grep -c "$METADATA_IP" /etc/iptables/rules.v4 2>/dev/null) 条）"

# ──────────────────────────── 可选：SSH 加固 ────────────────────────────
harden_ssh(){
  step "可选 SSH 加固"
  # 这是唯一可能把人锁在门外的动作。前置条件必须满足，否则拒绝执行。
  local keys; keys=$(grep -cve '^\s*$' -e '^\s*#' /root/.ssh/authorized_keys 2>/dev/null || echo 0)
  if [ "$keys" -lt 1 ]; then
    echo "  ✗ /root/.ssh/authorized_keys 里没有可用公钥 —— 拒绝关闭口令登录（那会把你锁在门外）" >&2
    return 1
  fi
  info "root 已配 $keys 个公钥"
  # 文件名必须以 00- 开头：sshd_config.d 是**首次出现者胜**，
  # 必须排在 cloud-init 写的 50-cloud-init.conf（里面是 PasswordAuthentication yes）之前。
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
EOF
  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    echo "  ✗ sshd 配置校验失败，已回滚" >&2; return 1
  fi
  systemctl reload ssh || systemctl reload sshd
  sleep 1
  info "$(sshd -T | grep -E '^(passwordauthentication|permitrootlogin)' | tr '\n' ' ')"
  cat <<'EOF'

  ⚠️ 现在**另开一个终端**验证能登进来，再关掉当前会话：
       ssh -o PasswordAuthentication=no root@<本机IP>
     进不去就在当前这条还活着的会话里回滚：
       rm -f /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh
EOF
}
[ "$HARDEN_SSH" = 1 ] && harden_ssh

# ──────────────────────────── 收尾 ────────────────────────────
cat <<EOF

$(printf '\033[1m装机完成\033[0m')

接下来（顺序不能反）：
  1. 跑 verify.sh 自检：       bash "$SELF_DIR/verify.sh"
  2. 改 workflow 的 runs-on：  见 playbook/05-workflow改造.md 与 06-接线与回退.md
     —— **在改完 workflow 之前不要设 CI_RUNNER 变量**，否则第 2 个 PR 就会红
  3. 打开开关：
     gh variable set CI_RUNNER --repo $GH_REPO --body '["${RUNNER_LABELS//,/\",\"}"]'
  4. 开一个空改动的测试 PR，确认 check 都出现、都落到 $RUNNER_NAME、都绿

还没做、需要你在云控制台做的：
  · 云防火墙：入方向只放行 22（SSH）。这一层在虚拟机外面，是**唯一**挡得住
    「docker 自建 DNAT 绕过宿主 ufw」的地方，也是覆盖 CI 里宿主进程监听端口的正确层次。
EOF
