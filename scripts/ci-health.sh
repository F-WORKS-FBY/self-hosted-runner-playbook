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

# job 产出采样需要一个**只读** PAT（scope: repo 的 actions:read 即可）。
# 单独放一个 0600 的文件，不写进 /etc/cron.d/（那是 0644，全局可读）。
# 轮换 PAT 时只改这一个文件。文件不存在就退化成 jobs=skip，不报错、也不伪装成绿。
CI_HEALTH_ENV="${CI_HEALTH_ENV:-/etc/ci-health.env}"
# shellcheck disable=SC1090
[ -r "$CI_HEALTH_ENV" ] && . "$CI_HEALTH_ENV"

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

# ── job 产出采样（2026-09-07 事故后补）──────────────────────────────────
#
# ⚠️ 上面那个 `run=active` 是**存活**指标，不是**产出**指标。事故期间它连续
#    170 个小时报 active —— 完全正确，服务确实活着，只是它接到的每个 job 都红。
#    「服务活着」和「CI 可用」是两件事，只测前者就是又一盏假绿灯。
#
# 判据取最近 10 次 run 的 conclusion：连续 3 次及以上 failure 才告警。
# 单次红是正常的开发活动，连续三次红一定是机器侧或流水线塌了。
#
# 没有 token 就记 jobs=skip —— **不伪装成绿**。查不到 ≠ 没问题。
jobs="skip"
if [ -n "${GH_REPO:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  concl=$(curl -fsSL --max-time 20 \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${GH_REPO}/actions/runs?per_page=10&status=completed" 2>/dev/null \
          | python3 -c "import sys,json;print(' '.join(r['conclusion'] or '?' for r in json.load(sys.stdin).get('workflow_runs',[])))" 2>/dev/null)
  if [ -n "$concl" ]; then
    # 从最近一次往回数连续 failure
    streak=0
    for c in $concl; do
      [ "$c" = "failure" ] && streak=$((streak+1)) || break
    done
    jobs="streak=${streak}"
  fi
fi

echo "$(date -Is) fixedwork=${t}s root_avail=${avail}M containerd=${ctr}M volumes=${vol}M runner=${run} jobs=${jobs}" >> "$LOG"

warn(){ echo "$(date -Is) $*" >> "$LOG"; logger -t ci-health "$*" 2>/dev/null || true; }
# 争抢：超过基线 1.4 倍
awk -v t="${t:-0}" -v b="$BASELINE_S" 'BEGIN{ if (b+0 > 0 && t+0 > b*1.4) exit 1 }' \
  || warn "WARN vCPU 争抢：定长任务 ${t}s（基线 ${BASELINE_S}s）"
[ "${avail:-999999}" -lt 40000 ] && warn "WARN 根分区可用 ${avail}MB < 40G"
[ "${avail:-999999}" -lt 20000 ] && warn "CRIT 根分区可用 ${avail}MB < 20G"
[ "$run" != "n/a" ] && [ "$run" != "active" ] && warn "CRIT runner 服务不是 active（当前 $run）"
# 产出告警：服务 active 但 job 连红，正是 2026-09-07 那种「假绿」的唯一信号
case "$jobs" in
  streak=[3-9]|streak=[0-9][0-9]*)
    warn "CRIT 最近 ${jobs#streak=} 次 run 连续 failure —— 服务 active 不代表 CI 可用，先跑 verify.sh 看清理钩子那条" ;;
esac
exit 0
