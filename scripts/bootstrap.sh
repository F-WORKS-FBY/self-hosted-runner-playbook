#!/usr/bin/env bash
# bootstrap.sh：把一台干净的 Ubuntu 机器装成 GitHub Actions 自建 CI runner。
#
# 适用范围：x86_64 的 Ubuntu（测过 24.04），一台机器一个 runner 实例。写法不绑定云厂商，实测都在同一家厂商的云主机上。
#   别的架构在开头就退出（Node 和 runner 下载的都是 x64 的包）。同机多实例要先改脚本，前提见 10 章 10.6。
#   Debian 要先把第 2 步 Docker 源地址里的 linux/ubuntu 换成 linux/debian（两处），没有实测过；
#   不用 apt 的发行版要自己改装包的几步。换厂商要核对的事见 02 章 2.9。
# 幂等：重复跑不会破坏已有配置，只补齐缺的。已在一台配置完成的机器上重跑验证过。
# 必须 root 运行。
#
# 用法：
#   read -rsp 'PAT: ' GH_TOKEN; echo; export GH_TOKEN   # 别把 token 写在命令行上，会进 shell 历史
#   GH_REPO=owner/repo bash bootstrap.sh
#   GH_REPO=owner/repo bash bootstrap.sh --harden-ssh
#   GH_REPO=owner/repo bash bootstrap.sh --skip-runner   # 只装工具链与加固，不注册 runner，不需要 token
# 新机器建议先 --skip-runner，回放最慢的 job 确认机器够快，再带 token 重跑一次完成注册（03 章 3.0）。
#
# GH_TOKEN 只在注册时用：查 runner 的最新版本、换取 registration token。两处都经标准输入交给 curl，
# 不进命令行参数（本机其他用户用 ps 看得到参数）；脚本也不会把它写到任何文件里。
# 建议用 fine-grained PAT，只给目标仓库的 Administration: read&write。用完即撤销。
# 从别的机器传过来时，写进 0600 的临时文件，source 后立刻删掉，再跑本脚本：runner 一启动就可能接 job。
#
# 可选：
#   CI_HEALTH_GH_TOKEN=...   job 产出采样用的只读 token（fine-grained，只授权这个仓库，Actions: read）。不要用注册用的 PAT
#   CI_ALERT_WEBHOOK=...     告警推送到飞书自定义机器人；开了签名校验再加 CI_ALERT_SECRET=...
#   RUNNER_UID=1000          新建 runner 用户时用的 uid，所有 runner 机器保持一致（03 章 3.3）
#   METADATA_IP=169.254.169.254   云 metadata 地址，阿里云、腾讯云等不是这个（04 章 4.5）
#   APT_LOCK_WAIT=600        apt/dpkg 锁被占用时最多等几秒，0 表示不等
#   FORCE_REPLACE=1          GitHub 上已有同名 runner、确认那条注册已经作废时才加（03 章 3.4）
#
# 参数会落盘到 /etc/ci-runner.env（无密钥，0644）。重跑时没显式传的参数从那里读，
# 所以在已部署的机器上重跑只需 `bash bootstrap.sh`，不必记得当初传过什么。
# 重跑前先等机器空闲，用 systemctl stop 停掉 runner 服务：这里只在开头查一次有没有 job，
# 跑的几分钟里接到的 job 会被末尾的重启打断（08 章 8.7）。脚本最后会重新启动 runner。
#
# --harden-ssh 默认不做。它是唯一可能把你锁在门外的动作，
# 不该在无人值守的脚本里默认发生。见文末 harden_ssh 的注释。
set -euo pipefail

# ──────────────────────────── 参数（全部可用环境变量覆盖）────────────────────────────
# 先读上次落盘的参数，再套默认值。顺序：本次显式传入 > /etc/ci-runner.env > 下面的默认值。
#    不这么做的后果：机器实际用的 CI_LABEL、CI_APP_PORTS、基线和默认值不同，又没存在任何地方，
#    有人哪天直接重跑 bootstrap.sh，清理钩子就换成默认标签（按标签清理全部落空）、
#    孤儿端口清理被关掉、争抢告警归零，而且什么都不报错。
CI_RUNNER_ENV="${CI_RUNNER_ENV:-/etc/ci-runner.env}"
PERSIST_VARS="GH_REPO RUNNER_NAME RUNNER_LABELS RUNNER_USER RUNNER_UID RUNNER_HOME RUNNER_MEM_MAX RUNNER_OOM_ADJ BUILDKIT_RESERVED BUILDKIT_MAX_USED BUILDKIT_MIN_FREE CI_LABEL CI_APP_PORTS CI_FIXEDWORK_BASELINE CI_DISK_WARN_MB CI_DISK_CRIT_MB METADATA_IP"
if [ -r "$CI_RUNNER_ENV" ]; then
  # 「显式传入」按变量是否设置过判断（${!k+x}），所以 CI_APP_PORTS= 这样的空值也能覆盖文件里的值
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; k=${line%%=*}; v=${line#*=}
    case " $PERSIST_VARS " in *" $k "*) [ -z "${!k+x}" ] && printf -v "$k" '%s' "$v" ;; esac
  done < "$CI_RUNNER_ENV"
  # METADATA_IP 是后来才落盘的。旧版写的文件里没有它，这次又没显式传，就会按默认地址再加一套规则（提示在下面）。
  [ -n "${METADATA_IP+x}" ] || METADATA_LEGACY=1
fi
GH_REPO="${GH_REPO:?必须设 GH_REPO，形如 owner/repo}"
# 每台机器必须唯一：注册带 --replace，同名会顶掉另一台的注册。云上主机名可能重复，有多台时显式传。
RUNNER_NAME="${RUNNER_NAME:-ci-$(hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,ci}"   # 建议再加一个项目专属标签
RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_UID="${RUNNER_UID:-1000}"          # 只在新建 runner 用户时用；所有 runner 机器一致（03 章 3.3）
RUNNER_HOME="${RUNNER_HOME:-/opt/actions-runner}"
NODE_MAJOR="${NODE_MAJOR:-22}"
PNPM_VERSION="${PNPM_VERSION:-}"          # 留空则不预装 pnpm，交给 workflow 的 action 处理
# 不低于 runner 进程树实测峰值的 1.3 倍。峰值用 step.sh 或 runner 单元 memory.stat 的 anon+shmem 量，
# 不含容器（容器不在这个 cgroup 里），也别用含页缓存的 MemoryPeak。上限见 10 章 10.3。只跟 job 有关，换大机器不用调大。
RUNNER_MEM_MAX="${RUNNER_MEM_MAX:-6G}"
# runner 的 OOM 优先级。800 = 比系统服务先死。机器上还开着开发工具（VS Code、Claude Code、Codex 等）、
# 又想让它们比 CI 先死时，光把它们设成 1000 不够：内核按「RSS 页数 + adj × 总页数/1000」挑，
# 8G 机器上差 200 只抵约 1.5 GiB，大的 CI 进程（打包、类型检查等）照样排在前面。要保证就得满足
# (1000 − 本值) / 1000 × 总内存 > RUNNER_MEM_MAX。RUNNER_MEM_MAX=6G 时，约 7.6 / 15.6 / 31 GiB 的机器
# 分别取 200 / 600 / 800（04 章 4.3、10 章 10.3）。
RUNNER_OOM_ADJ="${RUNNER_OOM_ADJ:-800}"
# BuildKit GC 的三个值。默认值对应 75 GB 的盘（参考项目），盘大了要放宽，比如 150 GB 盘用 10GB / 40GB / 30GB。
# 按盘大小怎么取见 10 章 10.4。
BUILDKIT_RESERVED="${BUILDKIT_RESERVED:-10GB}"
BUILDKIT_MAX_USED="${BUILDKIT_MAX_USED:-20GB}"
BUILDKIT_MIN_FREE="${BUILDKIT_MIN_FREE:-20GB}"
CI_LABEL="${CI_LABEL:-com.ci.selfhosted=1}"   # 必须与 workflow 里 docker run --label 的值一致
CI_APP_PORTS="${CI_APP_PORTS:-}"          # e2e 等会在宿主上监听的端口，清理时要杀孤儿。例：3100 3101
CI_FIXEDWORK_BASELINE="${CI_FIXEDWORK_BASELINE:-0}"   # preflight --with-load 给的 p50；0 = 只记录不告警
METADATA_IP="${METADATA_IP:-169.254.169.254}"
APT_LOCK_WAIT="${APT_LOCK_WAIT:-600}"     # apt/dpkg 锁被占用时最多等几秒（新机器刚开机时常见）
# 磁盘告警阈值从 BuildKit 的 Min Free 推出来。缓存长到 Max Used 就停（参考机上此时可用约 23 GiB，
# 那是设计稳态，不该告警）；可用空间被 Docker 以外的增长挤到 Min Free 附近时，GC 开始为保底而驱逐缓存，
# 这才值得看一眼。WARN = Min Free + 1 GiB，CRIT = 10 GiB。
# （改了 BUILDKIT_MIN_FREE 就把 /etc/ci-runner.env 里这两行一起改掉或删掉，否则沿用旧值。）
to_mib(){ local v n; v=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]'); n=${v%%[!0-9]*}
  [ -n "$n" ] || return 0
  case "${v#"$n"}" in G|GB|GIB) echo $((10#$n * 1024)) ;; M|MB|MIB) echo $((10#$n)) ;; T|TB|TIB) echo $((10#$n * 1048576)) ;; esac; }
MINFREE_MIB=$(to_mib "$BUILDKIT_MIN_FREE")
[ -n "$MINFREE_MIB" ] || echo "注意：解析不了 BUILDKIT_MIN_FREE=$BUILDKIT_MIN_FREE（只认整数 + GB/GiB/MB/TB），磁盘 WARN 阈值按 20 GiB 推算" >&2
CI_DISK_WARN_MB="${CI_DISK_WARN_MB:-$(( ${MINFREE_MIB:-20480} + 1024 ))}"
CI_DISK_CRIT_MB="${CI_DISK_CRIT_MB:-10240}"

HARDEN_SSH=0; SKIP_RUNNER=0
for a in "$@"; do
  case "$a" in
    --harden-ssh)  HARDEN_SSH=1 ;;
    --skip-runner) SKIP_RUNNER=1 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "必须 root 运行" >&2; exit 1; }
# Node 和 runner 下载的都是 linux-x64 的包，别的架构上装出来跑不起来
[ "$(uname -m)" = x86_64 ] || { echo "只支持 x86_64，这台机器是 $(uname -m)" >&2; exit 1; }
# runner 用户的 uid 要和其他 runner 机器一致（03 章 3.3）。还没建这个用户、uid 又被别人占了时就停下，
# 不让 useradd 悄悄换一个：换了的话，CI 容器以这个 uid 写进工作区的文件 runner 删不掉，checkout 会报 EACCES。
case "$RUNNER_UID" in ''|*[!0-9]*) echo "RUNNER_UID 要是数字，现在是：$RUNNER_UID" >&2; exit 2 ;; esac
case "$APT_LOCK_WAIT" in ''|*[!0-9]*) echo "APT_LOCK_WAIT 要是秒数，现在是：$APT_LOCK_WAIT" >&2; exit 2 ;; esac
if ! id "$RUNNER_USER" >/dev/null 2>&1 && uid_owner=$(getent passwd "$RUNNER_UID" | cut -d: -f1) && [ -n "$uid_owner" ]; then
  echo "uid $RUNNER_UID 已被用户 $uid_owner 占用。先把它删掉或改到别的 uid，或者用 RUNNER_UID= 指定一个所有 runner 机器都一致的 uid（03 章 3.3）" >&2
  exit 1
fi
# 有 job 在跑就别动：第 4 步可能重启 docker、第 8 步末尾一定重启 runner，都会当场打断它；
# 第 7 步试跑钩子时，钩子也会因为「有别的 job」而跳过，门禁就形同虚设。
if pgrep -x Runner.Worker >/dev/null 2>&1 && [ "${FORCE_WHILE_BUSY:-0}" != 1 ]; then
  echo "有 job 正在运行（Runner.Worker），等它跑完再执行；确实要强行执行就加 FORCE_WHILE_BUSY=1" >&2; exit 1
fi
# 只在第一次用新版重跑时出现一次，这次跑完文件里就有了
if [ "${METADATA_LEGACY:-0}" = 1 ]; then
  echo "注意：$CI_RUNNER_ENV 里没有 METADATA_IP（旧版 bootstrap 写的），这次按默认的 $METADATA_IP 拦截。" >&2
  echo "  这台机器的云用别的地址时（04 章 4.5），10 秒内按 Ctrl-C 停下，带上 METADATA_IP= 重跑。" >&2
  sleep 10
fi

# 把这次实际生效的参数落盘（不含任何密钥）
{ echo "# 由 bootstrap.sh 写入：本机实际生效的部署参数。重跑 bootstrap 时作为默认值读回。"
  echo "# 不含密钥。要改某个值：改这里再重跑，或重跑时用环境变量覆盖。"
  for k in $PERSIST_VARS; do printf '%s=%s\n' "$k" "${!k}"; done
} > "$CI_RUNNER_ENV"
chmod 0644 "$CI_RUNNER_ENV"

SVC=""   # runner 的 systemd 单元名，注册后填
step(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
info(){ printf '  %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# 新机器刚开机时，cloud-init 和自动升级常占着 dpkg 锁，apt-get 默认不等锁、直接失败。
# install 认 DPkg::Lock::Timeout，update 不认（它要的是 lists 锁，apt 2.8 上实测立刻失败），所以再包一层：
# 报「Could not get lock」就每 5 秒重试一次，总共最多等 APT_LOCK_WAIT 秒，别的错误照常失败。
# stdout 丢掉（原来各处也是 -qq 或 >/dev/null），stderr 先收起来，结束后照样打印。
# LC_ALL=C 是为了让锁的报错固定是英文，好匹配。
apt_get(){
  local t0=$SECONDS rc err said=0
  while :; do
    rc=0
    err=$(LC_ALL=C apt-get -o DPkg::Lock::Timeout="$APT_LOCK_WAIT" "$@" 2>&1 >/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -z "$err" ] || printf '%s\n' "$err" >&2
      return 0
    fi
    case "$err" in
      *'Could not get lock'*)
        if [ $((SECONDS - t0)) -lt "$APT_LOCK_WAIT" ]; then
          [ "$said" = 1 ] || { info "apt/dpkg 锁被别的进程占着，等它释放（最多 ${APT_LOCK_WAIT} 秒）"; said=1; }
          sleep 5; continue
        fi ;;
    esac
    printf '%s\n' "$err" >&2
    return "$rc"
  done
}
# debconf-set-selections 也会撞锁：dpkg 正在配置包时，debconf 锁着 config.dat，它直接报错退出。
# 和 apt_get 一样，报 locked 就每 5 秒重试，最多等 APT_LOCK_WAIT 秒。
debconf_set(){
  local t0=$SECONDS err
  until err=$(printf '%s\n' "$1" | LC_ALL=C debconf-set-selections 2>&1); do
    case "$err" in
      *locked*) [ $((SECONDS - t0)) -lt "$APT_LOCK_WAIT" ] && { sleep 5; continue; } ;;
    esac
    printf '%s\n' "$err" >&2
    return 1
  done
  [ -z "$err" ] || printf '%s\n' "$err" >&2
}

# ──────────────────────────── 1. 基础工具链 ────────────────────────────
step "1/8 基础工具"
# cloud-init 还在装包时会占着 dpkg 锁，先等它跑完。只在它报 running 时等：
# 已部署的机器上是 done，直接跳过；没启用的机器上 --wait 可能一直等，所以不碰它。
# APT_LOCK_WAIT=0 时不等：`timeout 0` 的意思是不限时，不能直接传进去。
if command -v cloud-init >/dev/null 2>&1 && [ "$APT_LOCK_WAIT" -gt 0 ]; then
  case "$(timeout 30 cloud-init status 2>/dev/null || true)" in
    *'status: running'*)
      info "等 cloud-init 跑完（最多 ${APT_LOCK_WAIT} 秒）"
      timeout "$APT_LOCK_WAIT" cloud-init status --wait >/dev/null 2>&1 || true ;;
  esac
fi
apt_get update -qq
apt_get install -y -qq ca-certificates curl gnupg jq git tar unzip zstd psmisc python3
info "已装：ca-certificates curl gnupg jq git tar unzip zstd psmisc python3"
# psmisc 提供 fuser，清理孤儿进程要用

step "2/8 Docker CE（官方源）"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  # 源地址按 Ubuntu 写。Debian 把这里和下面 echo 里的 linux/ubuntu 都换成 linux/debian（未测）。
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_get update -qq
  apt_get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
info "$(docker --version | cut -d, -f1) / buildx $(docker buildx version | awk '{print $2}')"

step "3/8 Node ${NODE_MAJOR} + pnpm + gh"
# Node 用官方 tarball 装到 /opt/node，与 actions/setup-node 拿的是同一份构建，
# 避免发行版包管理器的版本漂移。setup-node 之后仍会自己管版本，这份是给 runner 自身与脚本用的。
if ! command -v node >/dev/null || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" != "$NODE_MAJOR" ]; then
  NV=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r --arg m "v${NODE_MAJOR}." '[.[]|select(.version|startswith($m))][0].version')
  curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/${NV}/node-${NV}-linux-x64.tar.xz"
  # --no-same-owner：官方包里的文件属主是 uid 1001，root 解压默认照搬。机器上谁恰好是 1001，
  # 谁就能改 CI 和 root 都会执行的 node（09 章 A16）。
  # 分成几行写：用 && 串起来时，中间一步失败 set -e 管不到，脚本会带着装坏的 Node 往下走。
  rm -rf /opt/node
  mkdir -p /opt/node
  tar --no-same-owner -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
  rm -f /tmp/node.tar.xz
  for b in node npm npx corepack; do ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; done
fi
# Node 大版本没变时上面整段跳过，旧版脚本解压留下的 uid 1001 属主还在，所以每次都查一遍
if [ -d /opt/node ] && [ -n "$(find /opt/node \( ! -user 0 -o ! -group 0 \) -print -quit 2>/dev/null)" ]; then
  chown -R root:root /opt/node
  info "已把 /opt/node 的属主收回 root（09 章 A16）"
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
  # 分两行：写成 update && install 时，update 失败（比如等锁超时）set -e 不退出，最后机器上没有 gh
  apt_get update -qq
  apt_get install -y -qq gh
fi
info "gh $(gh --version | head -1 | awk '{print $3}')"

# ──────────────────────────── 4. Docker 守护进程 ────────────────────────────
step "4/8 Docker 守护进程配置"
# 两件事：
#  ① BuildKit GC 硬上限。出厂默认在小盘上太松（实测 Max Used 55.88GiB / Min Free 13.97GiB），
#     而 build cache 是自建 runner 上最大的磁盘增长源（实测每次镜像构建 +1GB 量级）。
#     必须用 policy 数组写全三个参数。`defaultKeepStorage` 只映射到 Reserved Space，
#     会把 Min Free 保护丢掉（实测踩过）。
#  ② live-restore：不开的话一次 dockerd 重启（比如 unattended-upgrades 触发的）
#     会把当前 job 的 services 容器当场全部停掉，而报错会指向业务代码。
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
# docker 在出厂免打扰名单里，containerd 不在，而 Docker 29 的镜像与容器都由它承载。
# runner 服务也不在：2026-10-02 06:06 一次 libssl 自动安全更新把 runner 在 job 中途重启，
# 那个 job 被当场打断（GitHub 上记为 Failed），只能重跑。豁免之后 runner 继续用旧库，直到下次重启（见 08 章「每月空闲时重启」）。
# 文件名保留旧的 90-ci-containerd.conf，已部署的机器原地覆盖，不会留下两份。
if [ -d /etc/needrestart ]; then
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/90-ci-containerd.conf <<'EOF'
# CI 机：别在 job 跑到一半时重启容器运行时，也别重启 runner。
# docker 已在出厂名单（needrestart.conf 的 override_rc 里有 qr(^docker) => 0），containerd 没有。
$nrconf{override_rc}->{qr(^containerd)} = 0;
# runner：自动重启会直接杀掉正在跑的 job（2026-10-02 实际发生过）。
$nrconf{override_rc}->{qr(^actions\.runner\.)} = 0;
EOF
  info "needrestart 已豁免 containerd 与 runner"
fi

# ──────────────────────────── 5. runner 用户与注册 ────────────────────────────
step "5/8 runner 用户与注册"
# 新建时固定 uid（开头已查过没被别人占用）。已有的用户不改 uid，不一致只提示。
id "$RUNNER_USER" >/dev/null 2>&1 || useradd -m -u "$RUNNER_UID" -s /bin/bash "$RUNNER_USER"
usermod -aG docker "$RUNNER_USER"
RU_UID=$(id -u "$RUNNER_USER")
info "用户 $RUNNER_USER（uid $RU_UID，在 docker 组。注意：docker 组约等于免密的宿主 root）"
[ "$RU_UID" = "$RUNNER_UID" ] || info "注意：$RUNNER_USER 的 uid 是 $RU_UID，不是 RUNNER_UID=$RUNNER_UID。和其他 runner 机器不一致时，CI 容器写进工作区的文件可能删不掉（03 章 3.3）"
mkdir -p "$RUNNER_HOME"; chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

# token 经标准输入交给 curl（-H @-），不进命令行参数：参数对本机所有用户可见（ps、/proc/<pid>/cmdline）。
# printf 是 bash 内建命令，不单独起进程。
gh_auth_header(){ printf 'Authorization: Bearer %s\n' "$GH_TOKEN"; }

if [ "$SKIP_RUNNER" = 0 ]; then
  if [ ! -f "$RUNNER_HOME/config.sh" ]; then
    : "${GH_TOKEN:?注册 runner 需要 GH_TOKEN（用完即撤销），或加 --skip-runner 跳过}"
    RV=$(gh_auth_header | curl -fsSL -H @- https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
    info "下载 runner $RV"
    curl -fsSLo /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RV}/actions-runner-linux-x64-${RV}.tar.gz"
    tar xzf /tmp/runner.tar.gz -C "$RUNNER_HOME"; rm -f /tmp/runner.tar.gz
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
    "$RUNNER_HOME/bin/installdependencies.sh" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$RUNNER_HOME/.runner" ]; then
    : "${GH_TOKEN:?注册 runner 需要 GH_TOKEN}"
    # 注册前先查同名。--replace 会悄悄顶掉同名的已有注册：那台从此接不到 job，
    # 按名字查状态却还是 online（在线的是本机），很难发现（09 章 A18）。
    # 本机还没有 .runner，所以查到的同名注册不会是本机正在用的那条。
    # 列 runner 和换 registration token 要的是同一个权限（Administration），注册用的 PAT 够用。
    RN_Q=$(jq -rn --arg n "$RUNNER_NAME" '$n|@uri')
    RUNNERS=$(gh_auth_header | curl -fsS -H @- -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${GH_REPO}/actions/runners?name=${RN_Q}&per_page=100") \
      || { echo "查不到 $GH_REPO 已有的 runner：网络不通，或者 PAT 没有这个仓库的 Administration 权限" >&2; exit 1; }
    SAME=$(printf '%s' "$RUNNERS" | jq -r --arg n "$RUNNER_NAME" \
          '.runners[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | "id \(.id)，\(.status)"')
    if [ -n "$SAME" ] && [ "${FORCE_REPLACE:-0}" != 1 ]; then
      echo "GitHub 上已经有叫 $RUNNER_NAME 的 runner（$SAME）。注册带 --replace，会把它顶掉（03 章 3.4）。" >&2
      echo "  它是另一台在用的机器：用 RUNNER_NAME=<新名字> 重跑。" >&2
      echo "  确认那条注册已经作废（这台机器重装前留下的，或者机器已经撤掉）：先在仓库 Settings → Actions → Runners 里删掉它，或者加 FORCE_REPLACE=1 重跑。" >&2
      exit 1
    fi
    REG=$(gh_auth_header | curl -fsS -X POST -H @- -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${GH_REPO}/actions/runners/registration-token" | jq -r .token)
    sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_HOME' && ./config.sh --unattended \
      --url 'https://github.com/${GH_REPO}' --token '$REG' \
      --name '$RUNNER_NAME' --labels '$RUNNER_LABELS' --work _work --replace" >/dev/null
    info "已注册：$RUNNER_NAME  labels=$RUNNER_LABELS"
    # 刻意不加 --ephemeral：它跑完一个 job 会自己注销并停掉服务
    #    （bin/RunnerService.js：exit with 0 return code, stop the service, no retry needed），
    #    要回来必须在机器上常驻管理员凭据，与「用完撤销 token」直接冲突，
    #    而一次没被发现的注销会造成最长 24 小时全员 CI 停摆。
    # --replace 会顶掉同名的已有注册，所以 RUNNER_NAME 每台必须不同（03 章 3.4）。
  else
    info "runner 已注册，跳过"
  fi
  # 这里只装服务不启动，等加固、钩子、metadata 拦截都就位后在第 8 步末尾统一启动。
  # 原来在这里就 start：新注册的 runner 一上线就去接排队的 job，第 6 步紧接着 restart 会把它打断；
  # 而且钩子要到第 7 步才写进 .env，runner 只在启动时读 .env，那一轮跑的 job 没有清理钩子（09 章 A17）。
  ( cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER" >/dev/null 2>&1 || true )
  # --plain：不加的话，failed 状态的单元前面会多一列「●」，awk 取到的就是它
  SVC=$(systemctl list-units --type=service --all --no-legend --plain 'actions.runner.*' 2>/dev/null | awk '{print $1}' | head -1)
  [ -z "$SVC" ] && SVC=$(basename "$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)" 2>/dev/null || echo "")
  info "服务单元：${SVC:-<未找到>}"
  # config.sh 生成的 .credentials / .runner 是 0664（只有 RSA 私钥文件是 0600）。收紧到属主可读写。
  chmod 0600 "$RUNNER_HOME/.credentials" "$RUNNER_HOME/.runner" "$RUNNER_HOME/.runner_migrated" 2>/dev/null || true
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
# 在连续失败 5 次后会被打成 failed 并停止重试，等于白写。
StartLimitIntervalSec=0

[Service]
# 出厂 unit 是 Restart=no，listener 一死就永久死着，而 GitHub 侧的 online 状态
# 有分钟级延迟，你不会立刻发现。
Restart=always
RestartSec=10
# swap=0 的机器上 OOM 是 kill 不是变慢，而内核按 RSS 挑受害者、不知道谁是客人。
# 这一行让 CI 先死，别把 sshd 或别的东西带走。
OOMScoreAdjust=${RUNNER_OOM_ADJ}
MemoryAccounting=yes
MemoryMax=${RUNNER_MEM_MAX}
EOF
  systemctl daemon-reload
  info "Restart=$(systemctl show "$SVC" -p Restart --value)  MemoryMax=${RUNNER_MEM_MAX}  StartLimitInterval=$(systemctl show "$SVC" -p StartLimitIntervalUSec --value)"
else
  info "未找到 runner 服务单元，跳过（--skip-runner 时正常）"
fi

# ──────────────────────────── 7. 清理与监控 ────────────────────────────
step "7/8 清理钩子 + 每日 timer + 健康监控"
mkdir -p "$RUNNER_HOME/hooks"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 先渲染到 .new，试跑通过再替换。.env 里挂的是正式路径，runner 每个 job 现读现跑：
# 直接覆盖正式文件的话，在已部署的机器上试跑失败时坏钩子已经生效，「拒绝接线」就是空话。
HOOK="$RUNNER_HOME/hooks/ci-cleanup.sh"
if [ -f "$SELF_DIR/ci-cleanup.sh" ]; then
  sed -e "s#__CI_APP_PORTS__#${CI_APP_PORTS}#" -e "s#__CI_LABEL__#${CI_LABEL}#" "$SELF_DIR/ci-cleanup.sh" > "$HOOK.new"
else
  echo "缺少 $SELF_DIR/ci-cleanup.sh" >&2; exit 1
fi
chmod 0755 "$HOOK.new"; chown "$RUNNER_USER:$RUNNER_USER" "$HOOK.new"

# 装完必须按 runner 的真实调用方式跑一次，跑不过就拒绝接线。
#
# 2026-09-07 的事故就出在这里：钩子装好了、`.env` 挂好了、timer 起来了、
# 文件也可执行，但没有任何一处执行过它。runner 调钩子时强加 `-e`，
# 脚本里一条管道返回非零就中止，于是每个 job 都红，连续 7 天 21 个 job 全部失败，
# 而 systemctl / verify.sh / ci-health.sh 三处全部显示正常。
#
# 多花 0.2 秒执行一次，就能区分「装上了」和「真能用」（09 章 B10）。
if ! sudo -u "$RUNNER_USER" /usr/bin/bash -e "$HOOK.new"; then
  echo "钩子以 runner 的真实调用方式（bash -e）执行失败，拒绝接线：接上的话每个 job 都会失败" >&2
  echo "复现：sudo -u $RUNNER_USER /usr/bin/bash -ex $HOOK.new（正式钩子没动）" >&2
  exit 1
fi
# 占位符必须全部替换掉。只看赋值行：守卫那行故意保留 __CI_ 前缀做判据，不是残留。
if grep -qE '^(L|APP_PORTS)=.*__CI_' "$HOOK.new"; then
  echo "钩子仍含未替换的占位符（赋值行），sed 替换失败（正式钩子没动）" >&2; exit 1
fi
mv -f "$HOOK.new" "$HOOK"
info "钩子已按 runner 的调用方式试跑通过"

# 两个钩子都挂：JOB_STARTED 是主力（在下一个 job 开始前跑，不管上一个 job 是怎么结束的），
# JOB_COMPLETED 顺手。二者都不覆盖「runner 被杀」，所以还要一个每日 timer 兜底。
touch "$RUNNER_HOME/.env"
for k in ACTIONS_RUNNER_HOOK_JOB_STARTED ACTIONS_RUNNER_HOOK_JOB_COMPLETED; do
  grep -q "^$k=" "$RUNNER_HOME/.env" || echo "$k=$RUNNER_HOME/hooks/ci-cleanup.sh" >> "$RUNNER_HOME/.env"
done
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/.env"; chmod 0600 "$RUNNER_HOME/.env"
info "钩子已挂：$(grep -c ACTIONS_RUNNER_HOOK "$RUNNER_HOME/.env") 个"

# User=：钩子脚本归 runner 所有、runner 可写，原来这个 unit 却以 root 执行它。
# 这挡不住 CI job（runner 在 docker 组里，本来就约等于 root），这一行的意义是：
# 不以 root 运行低权限账户可写的脚本这条基本卫生，以及让 timer 与钩子两条路径的身份一致
# （同样的文件权限、同样的 docker 访问，不会出现「钩子路径能跑、timer 路径因为身份不同而行为不同」）。
# 撞上正在跑的 job 时钩子会自己跳过（见 ci-cleanup.sh 开头的守卫）。
cat > /etc/systemd/system/ci-cleanup.service <<EOF
[Unit]
Description=CI docker cleanup (fallback: hooks do not run when a job is cancelled or the runner is killed)
After=docker.service
[Service]
Type=oneshot
User=$RUNNER_USER
Group=$RUNNER_USER
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
  printf 'CI_FIXEDWORK_BASELINE=%s\nCI_DISK_WARN_MB=%s\nCI_DISK_CRIT_MB=%s\n13 * * * * root /usr/local/bin/ci-health.sh\n' \
    "$CI_FIXEDWORK_BASELINE" "$CI_DISK_WARN_MB" "$CI_DISK_CRIT_MB" > /etc/cron.d/ci-health
  chmod 0644 /etc/cron.d/ci-health
  # 凭据与推送地址放 0600 的 /etc/ci-health.env。cron.d 是 0644，不能放密钥。
  # 按键原地更新，不整个覆盖：原来的版本每次重跑都会重写整个文件，把手工加的推送地址冲掉。
  set_kv(){ local f=/etc/ci-health.env tmp; ( umask 077; touch "$f" ); tmp=$(umask 077; mktemp)
    # 值经 ENVIRON 传入而不是 awk -v：-v 会解释反斜杠转义，密钥里有 \ 就被改掉
    K="$1" V="$2" awk -F= '$1==ENVIRON["K"]{print ENVIRON["K"]"="ENVIRON["V"]; d=1; next} {print} END{if(!d) print ENVIRON["K"]"="ENVIRON["V"]}' "$f" > "$tmp"
    mv "$tmp" "$f"; chmod 0600 "$f"; }
  set_kv GH_REPO "$GH_REPO"
  [ -n "${CI_HEALTH_GH_TOKEN:-}" ] && set_kv CI_HEALTH_GH_TOKEN "$CI_HEALTH_GH_TOKEN"
  [ -n "${CI_ALERT_WEBHOOK:-}" ]   && set_kv CI_ALERT_WEBHOOK "$CI_ALERT_WEBHOOK"
  [ -n "${CI_ALERT_SECRET:-}" ]    && set_kv CI_ALERT_SECRET "$CI_ALERT_SECRET"
  info "健康监控已装（每小时 13 分；磁盘 WARN<${CI_DISK_WARN_MB}MB CRIT<${CI_DISK_CRIT_MB}MB）"
  grep -qE '^(CI_HEALTH_GH_TOKEN|GH_TOKEN)=.+' /etc/ci-health.env || info "  未配 CI_HEALTH_GH_TOKEN：job 产出采样为 skip"
  grep -qE '^GH_TOKEN=' /etc/ci-health.env && info "  注意：/etc/ci-health.env 里有旧版写入的 GH_TOKEN（通常是注册用的管理员 token，CI job 读得到），换成只读的 CI_HEALTH_GH_TOKEN 后删掉那一行"
  grep -qE '^CI_ALERT_WEBHOOK=.+' /etc/ci-health.env || info "  未配 CI_ALERT_WEBHOOK：告警只写本机 journal，没有接收方"
fi

# journald 显式上限：默认是文件系统的 10%（最多 4 GiB），在 75 GB 的 CI 盘上不该给它这么多
mkdir -p /etc/systemd/journald.conf.d
NEW_JD=$'[Journal]\nSystemMaxUse=1G'
if [ "$(cat /etc/systemd/journald.conf.d/50-ci-runner.conf 2>/dev/null)" != "$NEW_JD" ]; then
  printf '%s\n' "$NEW_JD" > /etc/systemd/journald.conf.d/50-ci-runner.conf
  systemctl restart systemd-journald
fi
info "journald 上限 1G"

# ──────────────────────────── 8. 网络加固 ────────────────────────────
step "8/8 挡住 CI 读云 metadata"
# 云 metadata 服务对 CI job 与容器都是可达的，里面常有初始 root 口令、公钥、网络配置。
# 两条规则：容器侧走 DOCKER-USER，宿主侧按 uid 拦 runner 用户。root 仍可读（cloud-init 要用）。
RU_UID=$(id -u "$RUNNER_USER")
iptables -C DOCKER-USER -d "$METADATA_IP" -j DROP 2>/dev/null \
  || iptables -I DOCKER-USER -d "$METADATA_IP" -j DROP
iptables -C OUTPUT -d "$METADATA_IP" -m owner --uid-owner "$RU_UID" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null \
  || iptables -I OUTPUT -d "$METADATA_IP" -m owner --uid-owner "$RU_UID" -j REJECT --reject-with icmp-port-unreachable
# 不能用 `dpkg -l` 判断：全新的 24.04 上 ufw 的 Breaks 让 dpkg 记着这个包名（状态 un），
# `dpkg -l` 照样返回 0，于是跳过安装，下一行 netfilter-persistent 找不到命令，脚本在这里退出（09 章 A15）。
if ! dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q 'install ok installed'; then
  debconf_set "iptables-persistent iptables-persistent/autosave_v4 boolean false"
  debconf_set "iptables-persistent iptables-persistent/autosave_v6 boolean false"
  apt_get install -y -qq iptables-persistent
fi
netfilter-persistent save >/dev/null 2>&1
info "metadata 拦截规则已生效并持久化（$(grep -c "$METADATA_IP" /etc/iptables/rules.v4 2>/dev/null) 条）"

# runner 只在这里（重新）启动一次：加固（第 6 步）、钩子（第 7 步）、metadata 拦截（第 8 步）都已就位
if [ -n "$SVC" ]; then
  systemctl restart "$SVC" || true
  sleep 3
  info "runner 服务 $SVC：$(systemctl is-active "$SVC")"
fi

# ──────────────────────────── 可选：SSH 加固 ────────────────────────────
harden_ssh(){
  step "可选 SSH 加固"
  # 这是唯一可能把人锁在门外的动作。前置条件必须满足，否则拒绝执行。
  # 只查 root 的公钥。用厂商默认用户登录的，那个用户的公钥要自己先确认（04 章 4.6）；
  # 后续项：同时检查 SUDO_USER 的 authorized_keys。
  local keys; keys=$(grep -cve '^\s*$' -e '^\s*#' /root/.ssh/authorized_keys 2>/dev/null || echo 0)
  if [ "$keys" -lt 1 ]; then
    echo "  失败：/root/.ssh/authorized_keys 里没有可用公钥，拒绝关闭口令登录（那会把你锁在门外）" >&2
    return 1
  fi
  info "root 已配 $keys 个公钥"
  # 文件名必须以 00- 开头：sshd_config.d 是首次出现者胜，
  # 必须排在 cloud-init 写的 50-cloud-init.conf 之前（有的厂商在里面写 PasswordAuthentication yes）。
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
EOF
  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    echo "  失败：sshd 配置校验失败，已回滚" >&2; return 1
  fi
  systemctl reload ssh || systemctl reload sshd
  sleep 1
  info "$(sshd -T | grep -E '^(passwordauthentication|permitrootlogin)' | tr '\n' ' ')"
  cat <<'EOF'

  注意：现在另开一个终端验证能登进来，再关掉当前会话：
       ssh -o PasswordAuthentication=no <登录用户>@<本机IP>    # root 或厂商的默认用户
     进不去就在当前这条还活着的会话里回滚：
       rm -f /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh
EOF
}
[ "$HARDEN_SSH" = 1 ] && harden_ssh

# ──────────────────────────── 收尾 ────────────────────────────
if [ "$SKIP_RUNNER" = 1 ]; then
cat <<EOF

$(printf '\033[1m工具链与加固已装好，runner 没有注册\033[0m')

接下来：
  1. 以 $RUNNER_USER 用户把最慢的那个 job 回放一遍，和现有机器比耗时（02 章 2.7）
  2. 通过了再注册，参数已存在 $CI_RUNNER_ENV，不用再传：
     read -rsp 'PAT: ' GH_TOKEN; echo; export GH_TOKEN
     bash "$SELF_DIR/bootstrap.sh"
     unset GH_TOKEN
EOF
else
cat <<EOF

$(printf '\033[1m装机完成\033[0m')

接下来（顺序不能反）：
  1. 跑 verify.sh 自检：       bash "$SELF_DIR/verify.sh"
  仓库里已经有别的自建 runner 在接 job 时（这是第二台及以后），跳过 2、3，
  按本仓库 07 章 7.5、08 章 8.7 核对这台领到了 job。
  2. 改 workflow 的 runs-on：  见本仓库的 05-workflow改造.md 与 06-接线与回退.md
     在改完 workflow 之前不要设 CI_RUNNER 变量，否则第 2 个 PR 就会红
  3. 打开开关：
     gh variable set CI_RUNNER --repo $GH_REPO --body '["${RUNNER_LABELS//,/\",\"}"]'
  4. 开一个空改动的测试 PR，确认 check 都出现、都绿。只有这一台时，job 应该都落在 $RUNNER_NAME 上；
     有多台时 job 会分到各台，确认 $RUNNER_NAME 出现在 job 的 runner_name 里
EOF
fi
cat <<EOF

还没做、需要你自己做的：
  · 入方向防火墙：只放行 SSH 端口（默认 22，建议限来源 IP），IPv4 和 IPv6 都要覆盖。云上配在厂商的
    云防火墙或安全组里，它在虚拟机外面，docker 自建的 DNAT 绕不过它，CI 在宿主上监听的端口也一并挡住。
    裸金属或者厂商没有云防火墙时，按本仓库 04 章 4.7「没有云防火墙时」做。
EOF
