#!/usr/bin/env bash
# verify.sh —— 装完 / 重启后自检。只读，不改任何东西。
#
# 用法：
#   bash verify.sh
#   GH_REPO=owner/repo GH_TOKEN=ghp_xxx bash verify.sh    # 多查 GitHub 侧的 runner 在线状态
#
# **重启之后跑这一条就够了** —— 它逐条核对开机恢复路径是否真的自愈了。
set -uo pipefail
RUNNER_HOME="${RUNNER_HOME:-/opt/actions-runner}"
RUNNER_USER="${RUNNER_USER:-runner}"
METADATA_IP="${METADATA_IP:-169.254.169.254}"
GH_REPO="${GH_REPO:-}"

P=0; F=0
ok(){ printf '  \033[32mPASS\033[0m  %s\n' "$*"; P=$((P+1)); }
no(){ printf '  \033[31mFAIL\033[0m  %s\n' "$*"; F=$((F+1)); }
sk(){ printf '  \033[90mSKIP\033[0m  %s\n' "$*"; }
hdr(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

SVC=$(basename "$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)" 2>/dev/null || echo "")

hdr "服务与开机自启（重启后这一段最要紧）"
for u in docker containerd ${SVC:-}; do
  [ -z "$u" ] && continue
  a=$(systemctl is-active "$u" 2>/dev/null); e=$(systemctl is-enabled "$u" 2>/dev/null)
  [ "$a" = "active" ] && [ "$e" = "enabled" ] && ok "$u  active + enabled" || no "$u  active=$a enabled=$e"
done
[ -n "$SVC" ] || no "找不到 runner 服务单元（是否跑过 bootstrap.sh 的注册段？）"

hdr "runner 加固"
if [ -n "$SVC" ]; then
  r=$(systemctl show "$SVC" -p Restart --value)
  s=$(systemctl show "$SVC" -p StartLimitIntervalUSec --value)
  m=$(systemctl show "$SVC" -p MemoryMax --value)
  o=$(systemctl show "$SVC" -p OOMScoreAdjust --value)
  [ "$r" = "always" ] && ok "Restart=always" || no "Restart=$r（应为 always，否则进程一死永久死着）"
  [ "$s" = "0" ] && ok "StartLimitIntervalSec=0" || no "StartLimitIntervalUSec=$s（应为 0，否则 5 次/10 秒后 systemd 停止重试）"
  [ "$m" != "infinity" ] && ok "MemoryMax=$m" || no "MemoryMax 未设"
  [ "$o" -ge 500 ] 2>/dev/null && ok "OOMScoreAdjust=$o" || no "OOMScoreAdjust=$o（应 ≥500，让 CI 先于系统服务被 OOM 挑中）"
  systemctl show "$SVC" -p After --value | grep -q docker.service && ok "After=docker.service" || no "缺 After=docker.service（重启后可能先接到 job 再有 docker）"
else sk "无 runner 单元，跳过加固检查"; fi

hdr "Docker 守护进程"
docker info 2>/dev/null | grep -qi 'live restore enabled: true' && ok "live-restore=true" || no "live-restore 未开（dockerd 重启会杀掉当前 job 的服务容器）"
GC=$(docker buildx inspect default 2>/dev/null | grep -A6 'GC Policy rule#0' | tr -d ' ')
echo "$GC" | grep -q 'MaxUsedSpace' && ok "BuildKit GC 有 Max Used 上限" || no "BuildKit GC 没有 Max Used 上限（defaultKeepStorage 只设 Reserved，会丢 Min Free 保护）"
echo "$GC" | grep -q 'MinFreeSpace' && ok "BuildKit GC 有 Min Free 底线" || no "BuildKit GC 没有 Min Free 底线"

hdr "清理与监控"
[ -x "$RUNNER_HOME/hooks/ci-cleanup.sh" ] && ok "清理脚本就位" || no "缺 $RUNNER_HOME/hooks/ci-cleanup.sh"

# ⚠️ 下面这条是本表里唯一**执行**钩子的检查，2026-09-07 事故后补。
#
# 那次事故里，上一行的「就位」、下一行的「两个钩子都挂了」、再下一行的
# 「timer active」**三条全部 PASS**，整表 24 PASS / 0 FAIL，而机器上
# 连续 7 天每个 job 都红。原因是这些检查只看**结构**：文件在不在、变量挂没挂、
# timer 起没起 —— 没有一条问过「它到底能不能正常退出」。
#
# runner 调钩子时强加 `-e`，钩子非零退出就把 job 判失败。所以这里必须用
# 完全相同的方式跑一次。这是「装上了」与「真能用」之间的唯一分界线。
if sudo -u "$RUNNER_USER" /usr/bin/bash -e "$RUNNER_HOME/hooks/ci-cleanup.sh" >/dev/null 2>&1; then
  ok "清理钩子按 runner 的调用方式（bash -e）可正常退出"
else
  no "清理钩子在 bash -e 下非零退出 —— 每个 job 都会红（2026-09-07 事故的完整形态）。复现：sudo -u $RUNNER_USER /usr/bin/bash -ex $RUNNER_HOME/hooks/ci-cleanup.sh"
fi
# 只看赋值行：守卫那行**故意**保留 __CI_ 前缀做判据，不是残留。
grep -qE '^(L|APP_PORTS)=.*__CI_' "$RUNNER_HOME/hooks/ci-cleanup.sh" 2>/dev/null \
  && no "钩子赋值行仍含未替换的占位符 —— bootstrap 的 sed 没生效，按 label 过滤的清理全部落空" \
  || ok "钩子占位符已全部替换"

n=$(grep -c '^ACTIONS_RUNNER_HOOK_JOB_' "$RUNNER_HOME/.env" 2>/dev/null || echo 0)
[ "$n" -ge 2 ] && ok "两个钩子都挂了（STARTED + COMPLETED）" || no "只挂了 $n 个钩子（JOB_COMPLETED 在 job 被取消时不执行，必须同时挂 JOB_STARTED）"
[ "$(systemctl is-active ci-cleanup.timer 2>/dev/null)" = "active" ] && ok "ci-cleanup.timer active" || no "ci-cleanup.timer 未运行（钩子在 runner 被杀时也不执行，这是唯一兜底）"
CRON=$(ls /etc/cron.d/ 2>/dev/null | grep -E '^[a-z0-9-]*ci-health$' | head -1)
[ -x /usr/local/bin/ci-health.sh ] && [ -n "$CRON" ] && ok "健康监控已装（/etc/cron.d/$CRON）" || no "健康监控缺失"
grep -q 'var/lib/containerd' /usr/local/bin/ci-health.sh 2>/dev/null \
  && ok "监控量的是 /var/lib/containerd（对）" || no "监控没量 containerd —— Docker 29 下 96% 的字节在那里，量 /var/lib/docker 是假绿灯"

hdr "网络加固"
iptables -C DOCKER-USER -d "$METADATA_IP" -j DROP 2>/dev/null \
  && ok "容器读不到 metadata（DOCKER-USER 规则在）" || no "缺 DOCKER-USER 的 metadata 拦截"
RU=$(id -u "$RUNNER_USER" 2>/dev/null || echo -1)
iptables -C OUTPUT -d "$METADATA_IP" -m owner --uid-owner "$RU" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null \
  && ok "runner 用户读不到 metadata（OUTPUT 规则在）" || no "缺 OUTPUT 的 metadata 拦截（CI job 的 shell 是宿主进程，DOCKER-USER 管不到它）"
grep -q "$METADATA_IP" /etc/iptables/rules.v4 2>/dev/null && ok "iptables 规则已持久化（重启后仍在）" || no "iptables 规则未持久化 —— 重启就没了"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  c=$(timeout 20 docker run --rm alpine:3.20 sh -c "wget -q -T3 -O- http://$METADATA_IP/ 2>/dev/null | head -c 1" 2>/dev/null || true)
  [ -z "$c" ] && ok "实拨验证：容器确实读不到 metadata" || no "实拨验证：容器仍能读到 metadata"
fi

hdr "SSH"
pa=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
if [ "$pa" = "no" ]; then ok "口令登录已关（authorized_keys 里 $(grep -cve '^\s*$' -e '^\s*#' /root/.ssh/authorized_keys 2>/dev/null || echo 0) 个公钥）"
else sk "口令登录仍开着（bootstrap.sh 默认不动它，要关加 --harden-ssh）"; fi

hdr "干净度"
[ "$(docker ps -aq 2>/dev/null | wc -l)" -eq 0 ] && ok "无残留容器" || no "有 $(docker ps -aq | wc -l) 个残留容器"
av=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
[ "$av" -ge 20 ] && ok "根分区可用 ${av}G" || no "根分区只剩 ${av}G"

if [ -n "$GH_REPO" ] && [ -n "${GH_TOKEN:-}" ]; then
  hdr "GitHub 侧"
  J=$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GH_REPO/actions/runners" 2>/dev/null || echo '{}')
  st=$(echo "$J" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("runners") or [{}])[0].get("status","?"))' 2>/dev/null)
  [ "$st" = "online" ] && ok "runner 在 GitHub 侧 online" || no "runner 在 GitHub 侧是 $st"
  echo "     注：这个字段有分钟级延迟，刚重启完可能还显示旧值，等 1–2 分钟再看。"
else
  hdr "GitHub 侧"; sk "未提供 GH_REPO/GH_TOKEN，跳过（重启后建议补查一次）"
fi

printf '\n\033[1m结果：PASS %d  FAIL %d\033[0m\n' "$P" "$F"
[ "$F" -eq 0 ] && { printf '  \033[32m全部通过\033[0m\n'; exit 0; } || { printf '  \033[31m有 %d 项未通过，排查见 playbook/09-踩坑记录.md\033[0m\n' "$F"; exit 1; }
