#!/usr/bin/env bash
# verify.sh —— 装完 / 重启后自检。
#
# 除了一处之外都只读：「清理钩子能否正常退出」那条会**真的执行一次钩子**（删 CI 容器、杀 e2e 端口）。
# 所以有 job 正在跑时，那条和「无残留容器」都会自动 SKIP —— 结果里出现 SKIP 就说明当时机器在忙，
# 想要完整结果就等空闲再跑一次。（钩子自己也有同样的守卫，双保险。）
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
# 有 job 在跑吗？按进程名精确匹配（-f 会被任何含这个词的命令行误触发）
BUSY=0; pgrep -x Runner.Worker >/dev/null 2>&1 && BUSY=1

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
#
# ⚠️ 这条会真的执行钩子。有 job 在跑时执行 = 删掉那个 job 的 minio、杀掉它的 e2e 进程，所以必须跳过。
#    （2026-10-16 发现：本脚本原来自称「只读」，08 章又把它列为日常自检，两者叠在一起就是定时炸弹。）
if [ "$BUSY" = 1 ]; then
  sk "有 job 正在运行，跳过钩子实跑（它会删掉那个 job 的容器）—— 空闲时再跑一次 verify.sh"
elif sudo -u "$RUNNER_USER" /usr/bin/bash -e "$RUNNER_HOME/hooks/ci-cleanup.sh" >/dev/null 2>&1; then
  ok "清理钩子按 runner 的调用方式（bash -e）可正常退出"
else
  no "清理钩子在 bash -e 下非零退出 —— 每个 job 都会红（2026-09-07 事故的完整形态）。复现：sudo -u $RUNNER_USER /usr/bin/bash -ex $RUNNER_HOME/hooks/ci-cleanup.sh"
fi
grep -q 'pgrep -x Runner.Worker' "$RUNNER_HOME/hooks/ci-cleanup.sh" 2>/dev/null \
  && ok "钩子带「有 job 在跑就不动」的守卫（每日 timer 不会误杀 job）" \
  || no "钩子缺少运行中 job 的守卫 —— 每日 timer 撞上 job 时会删掉它的容器（重新部署 scripts/ci-cleanup.sh）"
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
grep -q '^CI_DISK_WARN_MB=' "/etc/cron.d/$CRON" 2>/dev/null \
  && ok "磁盘告警阈值与 BuildKit GC 对齐（$(grep -h '^CI_DISK_WARN_MB=' "/etc/cron.d/$CRON")）" \
  || no "磁盘告警阈值没跟 GC 对齐 —— 旧版写死 WARN<40G，会在设计稳态下每小时误报"
grep -qE '^CI_ALERT_WEBHOOK=.+' /etc/ci-health.env 2>/dev/null \
  && ok "告警会推送到飞书（CI_ALERT_WEBHOOK 已配）" \
  || sk "告警只写本机 journal（/etc/ci-health.env 里没配 CI_ALERT_WEBHOOK）—— 等于没人看"
U=$(systemctl show ci-cleanup.service -p User --value 2>/dev/null)
[ "$U" = "$RUNNER_USER" ] && ok "每日清理以 $RUNNER_USER 身份运行" \
  || no "每日清理以 ${U:-root} 身份运行一个 $RUNNER_USER 可写的脚本 —— runner 能借此拿到 root"

hdr "部署参数与系统更新"
# bootstrap 的参数（CI_LABEL / CI_APP_PORTS / 基线 …）必须落盘：
# 不落盘的话，任何一次重新部署都会用默认值静默覆盖，把按标签清理、孤儿端口清理和争抢告警一起关掉。
if [ -r /etc/ci-runner.env ]; then
  ok "部署参数已落盘（/etc/ci-runner.env）"
  pl=$(sed -n 's/^CI_LABEL=//p' /etc/ci-runner.env)
  hl=$(sed -n 's/^L="\${CI_LABEL:-\(.*\)}".*/\1/p' "$RUNNER_HOME/hooks/ci-cleanup.sh" 2>/dev/null)
  [ -n "$pl" ] && [ "$pl" = "$hl" ] && ok "钩子的 CI 标签与落盘参数一致（$pl）" \
    || no "钩子的 CI 标签（$hl）与 /etc/ci-runner.env（$pl）不一致 —— 有人用别的参数重新部署过"
else
  no "部署参数没有落盘（缺 /etc/ci-runner.env）—— 下次重新部署会用默认值静默覆盖现有配置"
fi
cat /etc/needrestart/conf.d/*.conf 2>/dev/null | grep -qF 'actions\.runner\.' \
  && ok "needrestart 不会在 job 中途重启 runner" \
  || no "needrestart 会在安全更新时重启 runner —— 正在跑的 job 直接被杀（2026-10-02 丢过一个）"
if [ -f /var/run/reboot-required ]; then
  sk "有待生效的更新需要重启（$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | cut -c1-80)）—— 找个没有 job 的时候重启"
else ok "没有待重启的更新"; fi

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
if [ "$BUSY" = 1 ]; then sk "有 job 正在运行，容器属于它，跳过残留检查"
else [ "$(docker ps -aq 2>/dev/null | wc -l)" -eq 0 ] && ok "无残留容器" || no "有 $(docker ps -aq | wc -l) 个残留容器"; fi
[ "$(docker volume ls -q 2>/dev/null | wc -l)" -le 6 ] && ok "匿名卷没有累积（$(docker volume ls -q | wc -l) 个；每个 job 会短暂产生约 3 个）" \
  || no "有 $(docker volume ls -q | wc -l) 个卷 —— 清理钩子的 volume prune 可能没在跑"
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
