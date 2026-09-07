#!/usr/bin/env bash
# preflight.sh —— 候选机自检，跑在**装任何东西之前**，输出 GO / NO-GO。
#
# 只读：不装包、不改配置、不写任何地方。
# 唯一的例外是可选的 --with-load，它会用 python3 跑几秒定量 CPU 负载（不装任何东西）。
#
# 用法：
#   bash preflight.sh                 # 基础检查（约 40 秒）
#   bash preflight.sh --with-load     # 加做定长任务墙钟基线（多约 60 秒）
#   CI_HOST_PORTS="5433 6379 9000" bash preflight.sh
#
# 判据来源见 playbook/02-选机与验收.md。凡「阈值」都可以按你的项目改，
# 但**别改测法**——尤其是 steal 那条，它在很多云上是结构性不可观测的。
set -uo pipefail

CI_HOST_PORTS="${CI_HOST_PORTS:-5433 6379 9000}"   # CI 会独占的宿主端口，按项目改
MIN_CORES="${MIN_CORES:-4}"
MIN_MEM_MIB="${MIN_MEM_MIB:-7000}"                 # 单 job 实测峰值 ×1.5 起
MIN_DISK_GIB="${MIN_DISK_GIB:-40}"
WITH_LOAD=0; [ "${1:-}" = "--with-load" ] && WITH_LOAD=1

PASS=0; WARN=0; FAIL=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr(){  printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "1. 机器规格"
CORES=$(nproc)
MEM_MIB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
SWAP_MIB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
DISK_GIB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc 0-9)
[ "$CORES" -ge "$MIN_CORES" ] && ok "CPU ${CORES} 核（要求 ≥${MIN_CORES}）" || bad "CPU 只有 ${CORES} 核，要求 ≥${MIN_CORES}"
[ "$MEM_MIB" -ge "$MIN_MEM_MIB" ] && ok "内存 ${MEM_MIB} MiB（要求 ≥${MIN_MEM_MIB}）" || bad "内存只有 ${MEM_MIB} MiB，要求 ≥${MIN_MEM_MIB}"
[ "$DISK_GIB" -ge "$MIN_DISK_GIB" ] && ok "根分区可用 ${DISK_GIB} GiB（要求 ≥${MIN_DISK_GIB}）" || bad "根分区只剩 ${DISK_GIB} GiB"
if [ "$SWAP_MIB" -eq 0 ]; then
  warn "swap = 0 —— 内存超限时是 **OOM kill 而不是变慢**。这不是否决项，但它决定了 MemoryMax 必须设、且 N 只能是 1"
else
  ok "swap ${SWAP_MIB} MiB"
fi

hdr "2. CI 要独占的宿主端口"
BUSY=""
for p in $CI_HOST_PORTS; do
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && BUSY="$BUSY $p"
done
[ -z "$BUSY" ] && ok "端口 $CI_HOST_PORTS 全部空闲" \
  || bad "端口${BUSY} 已被占用 —— CI 的 services 容器起不来，且**撞上业务端口不是 CI 变红，是 CI 连到业务库上去**"

hdr "3. 时间同步"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then ok "已与 NTP 同步"
else warn "时间未同步 —— TLS 与 token 校验会出怪问题"; fi

hdr "4. 出网连通性（四条阈值：成功率≥98% / connect p95<300ms / TTFB p95<1500ms / 抖动比<3）"
ENDPOINTS="https://github.com/ https://api.github.com/ https://ghcr.io/v2/ https://registry.npmjs.org/ https://registry-1.docker.io/v2/ https://auth.docker.io/token?service=registry.docker.io"
if ! command -v curl >/dev/null; then bad "没有 curl，无法测连通性"; else
for url in $ENDPOINTS; do
  host=$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*#\1#')
  cs=""; ts=""; n=0; fail5xx=0; failnet=0
  for i in $(seq 1 12); do
    r=$(curl -s -o /dev/null --max-time 15 --no-keepalive \
        -w "%{http_code} %{time_connect} %{time_starttransfer}" "$url" 2>/dev/null) || { failnet=$((failnet+1)); continue; }
    set -- $r
    [ "${1:0:1}" = "5" ] && fail5xx=$((fail5xx+1))
    cs="$cs $(awk -v v="$2" 'BEGIN{printf "%.1f", v*1000}')"
    ts="$ts $(awk -v v="$3" 'BEGIN{printf "%.1f", v*1000}')"
    n=$((n+1))
  done
  if [ "$n" -eq 0 ]; then bad "$host 完全不通"; continue; fi
  read -r cp95 tp50 tp95 <<EOF
$(printf '%s\n' $cs | sort -n | awk -v c="$n" 'NR==int(0.95*(c-1))+1{printf "%s ", $1}'
  printf '%s\n' $ts | sort -n | awk -v c="$n" 'NR==int(0.5*(c-1))+1{printf "%s ", $1}'
  printf '%s\n' $ts | sort -n | awk -v c="$n" 'NR==int(0.95*(c-1))+1{printf "%s", $1}')
EOF
  succ=$(awk -v a="$n" -v b="$fail5xx" -v f="$failnet" 'BEGIN{printf "%.1f", 100*(a-b)/(a+f)}')
  jit=$(awk -v a="$tp95" -v b="$tp50" 'BEGIN{printf "%.2f", (b>0? a/b : 99)}')
  msg=$(printf '%-22s succ %s%%  conn_p95 %sms  ttfb_p95 %sms  抖动 %s' "$host" "$succ" "$cp95" "$tp95" "$jit")
  if awk -v s="$succ" -v c="$cp95" -v t="$tp95" -v j="$jit" \
       'BEGIN{exit !(s>=98 && c<300 && t<1500 && j<3)}'; then ok "$msg"; else bad "$msg  ← 未过阈值"; fi
done
fi

hdr "5. Docker Hub 拉取配额（每个出口 IP / IPv6 /64 独立计数）"
if command -v curl >/dev/null && command -v python3 >/dev/null; then
  for fam in -4 -6; do
    T=$(curl -s $fam --max-time 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
    [ -z "$T" ] && { warn "IPv${fam#-} 取不到 token（该地址族可能不可用）"; continue; }
    H=$(curl -s $fam --max-time 10 -o /dev/null -D - -H "Authorization: Bearer $T" \
        "https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest" 2>/dev/null)
    L=$(printf '%s' "$H" | tr -d '\r' | awk 'tolower($1)=="ratelimit-limit:"{print $2}')
    R=$(printf '%s' "$H" | tr -d '\r' | awk 'tolower($1)=="ratelimit-remaining:"{print $2}')
    [ -n "$L" ] && ok "IPv${fam#-} 限额 ${L}  余量 ${R}" || warn "IPv${fam#-} 未返回限流头（可能是认证账号或代理）"
  done
  echo "     注：常驻 runner 上**缓存 pull 不扣配额**（只是 version check），稳态消耗接近 0。"
  echo "        真正会把它变回冷拉的只有两件事：清盘脚本写狠了、浮动 tag 被上游重指向。"
else warn "缺 curl/python3，跳过"; fi

hdr "6. CPU 争抢的可观测性（决定用什么仪器，不是决定行不行）"
STEAL_OK=0
if [ -r /dev/cpu/0/cpuid ] || modprobe cpuid 2>/dev/null; then
  EAX=$(python3 - <<'PY' 2>/dev/null
import os,struct
try:
    fd=os.open('/dev/cpu/0/cpuid',os.O_RDONLY)
    print(hex(struct.unpack('<IIII',os.pread(fd,16,0x40000001))[0]))
except Exception: print('')
PY
)
  if [ -n "$EAX" ] && [ "$EAX" != "0x0" ]; then
    if python3 -c "import sys;sys.exit(0 if (int('$EAX',16)>>5)&1 else 1)" 2>/dev/null; then
      STEAL_OK=1; ok "宿主暴露了 KVM_FEATURE_STEAL_TIME（CPUID 0x40000001 eax=$EAX，bit5=1）⇒ /proc/stat 的 steal 列可用"
    else
      warn "宿主**未**暴露 KVM_FEATURE_STEAL_TIME（eax=$EAX，bit5=0）⇒ steal 列**结构性恒 0**"
      echo "     ⚠️ 这意味着任何基于 %st 的监控在这台机上都是**永久假绿灯**。"
      echo "        改用定长任务墙钟衡量争抢（--with-load 会给你基线）。"
    fi
  else warn "读不到 CPUID（非 x86 或无 cpuid 模块），无法判断 steal 是否可用"; fi
else warn "无 /dev/cpu/0/cpuid，跳过"; fi
[ "$STEAL_OK" = 1 ] && awk '/^cpu /{print "     开机至今 steal 累计 = "$9" jiffies"}' /proc/stat

if [ "$WITH_LOAD" = 1 ]; then
  hdr "7. 定长任务墙钟基线（争抢的唯一通用仪器）"
  # ⚠️ 必须是**定量**负载，不能用 `openssl speed`（它是定时的，墙钟恒等于你给的秒数，等于没测）。
  #    这里用固定次数的 sha256，纯 CPU、无 IO、跨机可比。
  if command -v python3 >/dev/null; then
    TS=""
    for i in 1 2 3 4 5 6 7 8; do
      TS="$TS $(python3 - <<'PY'
import hashlib, time
blk = b'x' * 4096
t0 = time.time()
h = hashlib.sha256()
for _ in range(180000):
    h.update(blk)
h.hexdigest()
print("%.3f" % (time.time() - t0))
PY
)"
    done
    printf '%s\n' $TS | sort -n | awk '{v[NR]=$1} END{
      p50=v[int(0.5*NR)+1]; mx=v[NR]; mn=v[1];
      printf "     n=%d  min=%.2fs  p50=%.2fs  max=%.2fs  max/p50=%.2f\n", NR, mn, p50, mx, mx/p50;
      if (mx/p50 < 1.15) print "  \033[32m✓\033[0m 离散度低 ⇒ 本时段无实质 vCPU 争抢";
      else print "  \033[33m!\033[0m 离散度偏高 ⇒ 可能有邻居在抢核，装机后要持续采点"}'
    echo "     把这个 p50 记下来当基线；上线后每小时采一次，超过基线 1.4 倍就是争抢信号。"
  else warn "没有 python3，跳过"; fi
fi

hdr "结论"
printf '  PASS %d   WARN %d   FAIL %d\n\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  \033[31mNO-GO\033[0m —— 有 %d 项硬指标未过，先解决再装。\n' "$FAIL"; exit 1
elif [ "$WARN" -gt 0 ]; then
  printf '  \033[33mGO（有保留）\033[0m —— %d 项提醒，装之前读一遍上面的 ! 行。\n' "$WARN"; exit 0
else
  printf '  \033[32mGO\033[0m —— 可以进入 bootstrap.sh。\n'; exit 0
fi
