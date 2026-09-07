#!/usr/bin/env bash
# ci-health.sh —— CI 机每小时采点。由 bootstrap.sh 安装到 /usr/local/bin/。
#
# 两条铁律，都是踩过坑总结的：
#
#  ① **不能采 /proc/stat 的 steal**。很多云的宿主不向 guest 暴露 KVM_FEATURE_STEAL_TIME
#     （CPUID 0x40000001 的 bit5），此时 steal 列**结构性恒为 0** —— 不是「测出来是 0」，
#     是「根本没接线」。基于 %st 的告警在这种机器上是**永久假绿灯**。
#     争抢改用**定长任务墙钟**衡量：同样的活干一遍，被邻居抢核就会变慢。
#     （preflight.sh 会告诉你这台机的 steal 到底能不能用。）
#
#  ② **磁盘要量 /var/lib/containerd**。Docker 29 默认用 containerd 快照器，
#     镜像字节不在 /var/lib/docker 里 —— 实测 containerd 2.6G vs docker 115M，
#     只量后者会低估约 10 倍，是另一种假绿灯。匿名卷在 /var/lib/docker/volumes，要单独量。
set -uo pipefail
LOG="${CI_HEALTH_LOG:-/var/log/ci-health.log}"
SVC="__RUNNER_SVC__"                      # 由 bootstrap.sh 替换
BASELINE_S="${CI_FIXEDWORK_BASELINE:-0}"  # preflight 给的 p50；为 0 则只记录不告警

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
vol=$(du -sBM /var/lib/docker/volumes 2>/dev/null | cut -f1 | tr -dc 0-9)
run="n/a"; [ "$SVC" != "none" ] && [ -n "$SVC" ] && run=$(systemctl is-active "$SVC" 2>/dev/null)

echo "$(date -Is) fixedwork=${t}s root_avail=${avail}M containerd=${ctr}M volumes=${vol}M runner=${run}" >> "$LOG"

warn(){ echo "$(date -Is) $*" >> "$LOG"; logger -t ci-health "$*" 2>/dev/null || true; }
# 争抢：超过基线 1.4 倍
awk -v t="${t:-0}" -v b="$BASELINE_S" 'BEGIN{ if (b+0 > 0 && t+0 > b*1.4) exit 1 }' \
  || warn "WARN vCPU 争抢：定长任务 ${t}s（基线 ${BASELINE_S}s）"
[ "${avail:-999999}" -lt 40000 ] && warn "WARN 根分区可用 ${avail}MB < 40G"
[ "${avail:-999999}" -lt 20000 ] && warn "CRIT 根分区可用 ${avail}MB < 20G"
[ "$run" != "n/a" ] && [ "$run" != "active" ] && warn "CRIT runner 服务不是 active（当前 $run）"
exit 0
