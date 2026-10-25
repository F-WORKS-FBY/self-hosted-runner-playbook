#!/usr/bin/env bash
# machine-check.sh —— 新开的云主机能不能当 CI runner：一分钟出结论。只读，不装任何东西，只要 python3。
#
# 用法：
#   bash machine-check.sh                       只测、打印分数（没有参考值时不判快慢）
#   REF=4.6 bash machine-check.sh               和参考机比：分数 ≤ REF×1.2 合格，≤ REF×1.4 有保留，再慢不合格
#   curl -fsSL <仓库 raw 地址>/scripts/machine-check.sh | REF=4.6 bash
#
# REF 怎么来：在你现有的、跑得好好的 runner 上用同一个脚本跑一次，取它打印的「单核分数」。
# 它在跑 CI 时测出来的数偏大（偏保守），没关系。
#
# 可调阈值（默认值和 preflight.sh 一致）：MIN_CORES=4 MIN_MEM_MIB=7000 MIN_DISK_GB=40
#   PASS_RATIO=1.2 WARN_RATIO=1.4（分数 ÷ REF）  SCALE_WARN=1.3（全核满载时单核掉速倍数）
#   PAR=0 跳过全核满载那一项（在正跑着 CI 的机器上量 REF 时用，别和 CI 抢核）
#
# 为什么要测单核：共享 vCPU 的云主机，同一个套餐每次开出来的 CPU 型号可能不同，单核能差一倍。
# CI 里被限成 1 个 CPU 的测试、单线程的类型检查，核再多也不会变快，单核慢多少耗时就涨多少，
# 最后撞上 timeout-minutes。见 02 章 2.7。
#
# 为什么不用 sha256 比：有 SHA 指令扩展（sha_ni）的 CPU 算 sha256 快约 5 倍，和跑 JS、Python 的快慢对不上。
# preflight.sh 的 sha256 基线只用来和同一台机器自己比（看争抢），不能跨机比。
#
# 退出码：0 合格，1 不合格，2 有保留（或没给 REF、只打印分数）。
set -uo pipefail
MIN_CORES="${MIN_CORES:-4}"; MIN_MEM_MIB="${MIN_MEM_MIB:-7000}"; MIN_DISK_GB="${MIN_DISK_GB:-40}"
PASS_RATIO="${PASS_RATIO:-1.2}"; WARN_RATIO="${WARN_RATIO:-1.4}"; SCALE_WARN="${SCALE_WARN:-1.3}"
REF="${REF:-}"
FAILS=(); WARNS=()
say(){ printf '%s\n' "$*"; }

command -v python3 >/dev/null || { say "没有 python3，测不了（Ubuntu 默认自带）"; exit 1; }
[ -z "$REF" ] || [[ "$REF" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { say "REF 要是一个数字（参考机的单核分数），现在是：$REF"; exit 1; }

arch=$(uname -m)
cores=$(nproc)
mem=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
disk=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
model=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo)
sha=$(grep -qw sha_ni /proc/cpuinfo && echo 有 || echo 无)
swap=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo)

say "== 硬件"
say "  CPU：$model（$cores 核，SHA 指令：$sha）"
say "  内存：${mem} MiB   根分区可用：${disk} GB   swap：${swap} MiB   架构：$arch"
[ "$arch" = x86_64 ] || FAILS+=("架构是 $arch，不是 x86_64")
[ "$cores" -ge "$MIN_CORES" ] || FAILS+=("只有 $cores 核，要求至少 $MIN_CORES")
[ "$mem" -ge "$MIN_MEM_MIB" ] || FAILS+=("内存 ${mem} MiB，要求至少 $MIN_MEM_MIB")
[ "$disk" -ge "$MIN_DISK_GB" ] || FAILS+=("根分区可用 ${disk} GB，要求至少 $MIN_DISK_GB")

# 三种单核负载，各跑 3 次取最快的一次（最快的那次最接近这台机器的真实能力，慢的那几次多半是被抢了）
BENCH=$(cat <<'PY'
import json, math, re, sys, time
def loop():
    sum(i % 7 for i in range(3 * 10**7))
def alloc():
    # 大量建小对象、排序、序列化：和 JS/TS 的测试、构建类似，吃内存分配和缓存
    d = {}
    for i in range(300000):
        o = {"id": i, "name": "item" + str(i), "v": math.sin(i) * 1000, "tags": [i % 7, i % 11]}
        d[o["name"]] = o
    a = sorted(d.values(), key=lambda o: o["v"])
    json.loads(json.dumps(a[:50000]))
def text():
    s = "".join(chr(97 + i % 26) for i in range(2 * 10**6))
    len(re.findall(r"([a-e]+)(f|g)", s))
    s.upper().replace("A", "z").split("Q")
def best(f, n=3):
    t = []
    for _ in range(n):
        t0 = time.perf_counter(); f(); t.append(time.perf_counter() - t0)
    return min(t), max(t)
mode = sys.argv[1]
if mode == "single":
    r = {k: best(f) for k, f in (("loop", loop), ("alloc", alloc), ("text", text))}
    print(json.dumps({k: v[0] for k, v in r.items()} | {"spread": max(v[1] / v[0] for v in r.values())}))
else:  # 一次 loop，给全核并发用
    print(best(loop, 1)[0])
PY
)

say "== 单核速度（三种负载各 3 次取最快）"
single=$(python3 -c "$BENCH" single) || { say "单核测试失败"; exit 1; }
read -r t_loop t_alloc t_text spread score < <(python3 -c '
import json,sys; d=json.loads(sys.argv[1])
print("%.2f %.2f %.2f %.2f %.2f" % (d["loop"], d["alloc"], d["text"], d["spread"], d["loop"]+d["alloc"]+d["text"]))' "$single")
say "  纯循环 ${t_loop}s   建对象+排序 ${t_alloc}s   字符串+正则 ${t_text}s"
say "  单核分数 ${score}（三项相加，越小越快）   同一项最慢/最快 ${spread}"

scale="未测"
if [ "${PAR:-1}" != 0 ]; then
  say "== 全核同时满载（$cores 个进程一起跑纯循环）"
  par=$(for i in $(seq 1 "$cores"); do python3 -c "$BENCH" par & done; wait)
  pmax=$(printf '%s\n' $par | sort -n | tail -1 | xargs printf '%.2f')
  scale=$(python3 -c "print('%.2f' % ($pmax / $t_loop))")
  say "  最慢的进程 ${pmax}s，是单独跑时的 ${scale} 倍"
  python3 -c "import sys; sys.exit(0 if $scale <= $SCALE_WARN else 1)" \
    || WARNS+=("全核满载时单核掉速 ${scale} 倍（> $SCALE_WARN），可能有邻居在抢 CPU，隔一会儿再测一次")
fi
python3 -c "import sys; sys.exit(0 if $spread <= 1.3 else 1)" \
  || WARNS+=("同一项测试快慢差 ${spread} 倍，测的时候有波动，隔一会儿再测一次")

verdict_speed=""
if [ -n "$REF" ]; then
  ratio=$(python3 -c "print('%.2f' % ($score / $REF))")
  say "== 和参考机比：分数 $score ÷ 参考 $REF = ${ratio}（合格线 ≤ $PASS_RATIO，有保留 ≤ $WARN_RATIO）"
  if python3 -c "import sys; sys.exit(0 if $ratio <= $PASS_RATIO else 1)"; then verdict_speed="单核是参考机的 ${ratio} 倍耗时"
  elif python3 -c "import sys; sys.exit(0 if $ratio <= $WARN_RATIO else 1)"; then WARNS+=("单核比参考机慢（耗时 ${ratio} 倍），单核受限的 job 会明显变慢，核对一下超时余量（02 章 2.7）")
  else FAILS+=("单核比参考机慢太多（耗时 ${ratio} 倍，上限 $WARN_RATIO），删掉重开一台")
  fi
fi

say ""
say "== 结论"
for f in "${FAILS[@]}"; do say "  ✗ $f"; done
for w in "${WARNS[@]}"; do say "  ! $w"; done
summary="$(hostname -s) | $model | ${cores}核 ${mem}MiB ${disk}GB | 单核分数 $score${REF:+ (参考 $REF，${ratio:-?} 倍)} | 满载掉速 ${scale}"
if [ ${#FAILS[@]} -gt 0 ]; then
  say "  不合格"; say ""; say "摘要：不合格 | $summary"; exit 1
elif [ -z "$REF" ]; then
  say "  没给 REF，只测不判快慢。在现有 runner 上跑一次拿到参考分数，再用 REF=<分数> 重跑。"
  say ""; say "摘要：未判定 | $summary"; exit 2
elif [ ${#WARNS[@]} -gt 0 ]; then
  say "  有保留（看上面的 ! 行）"; say ""; say "摘要：有保留 | $summary"; exit 2
else
  say "  合格：$verdict_speed"; say ""; say "摘要：合格 | $summary"; exit 0
fi
