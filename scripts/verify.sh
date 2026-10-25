#!/usr/bin/env bash
# verify.sh：装完、重启后的自检。
#
# 除了一处都只读。「清理钩子按 bash -e 实跑」那一项会真的执行一次钩子（删带 CI 标签的容器、
# 杀 CI_APP_PORTS 端口上的进程、删没有容器在用的匿名卷）。所以有 job 正在跑时，这一项和「无残留容器」
# 都自动 SKIP。结果里出现这两项的 SKIP，说明当时机器在忙，想要完整结果就等空闲再跑一次。
# 钩子自己也有同样的守卫。
#
# 用法：
#   bash verify.sh
#   read -rsp 'token: ' GH_TOKEN; echo; export GH_TOKEN; bash verify.sh; unset GH_TOKEN
#     多查一组 GitHub 侧的在线状态。token 只要目标仓库的 Administration: read，别用注册用的读写 token。
#     这一项最好在 CI 机以外用 gh api 查，token 就不用上 CI 机（07 章 7.1）。
#
# 部署参数（RUNNER_HOME、RUNNER_USER、RUNNER_UID、磁盘阈值、GH_REPO 等）从 /etc/ci-runner.env 读回，
# 和 bootstrap.sh 用同一份。环境变量里显式给的值优先。
#
# 重启之后跑这一条就够了，它逐项核对开机恢复路径是否真的自愈了。
set -uo pipefail

# 读法和 bootstrap.sh 相同：逐行按 KEY=VALUE 解析，只认下面这些键，不 source（值里有 $ ` 之类字符时
# source 会把它们当代码执行）。优先级：本次显式传入的环境变量 > 文件 > 默认值。
# 不读回的话，用了非默认 RUNNER_HOME 的机器会报一串假 FAIL。
# METADATA_IP 由 bootstrap 落盘，但旧版 bootstrap 写的文件里没有这一行，这样的机器重跑 bootstrap 之前要显式传（07 章开头）。
# CI_MAX_VOLUMES 也列在这里，文件里有这一行就认。bootstrap 不落盘它，重跑 bootstrap 会把文件重写掉，
# 所以取值不是默认的机器要在运行时显式传（07 章 7.1）。
CI_RUNNER_ENV="${CI_RUNNER_ENV:-/etc/ci-runner.env}"
ENV_KEYS="GH_REPO RUNNER_NAME RUNNER_USER RUNNER_UID RUNNER_HOME RUNNER_OOM_ADJ CI_LABEL CI_DISK_WARN_MB CI_DISK_CRIT_MB METADATA_IP CI_MAX_VOLUMES"
declare -A FILE_KV=()   # 文件里的原值，「和落盘参数一致」这类检查只拿它比
if [ -r "$CI_RUNNER_ENV" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}; k=${line%%=*}; v=${line#*=}
    case " $ENV_KEYS " in *" $k "*) FILE_KV[$k]=$v; [ -z "${!k+x}" ] && printf -v "$k" '%s' "$v" ;; esac
  done < "$CI_RUNNER_ENV"
fi
RUNNER_HOME="${RUNNER_HOME:-/opt/actions-runner}"
RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_UID="${RUNNER_UID:-1000}"
MD_HINT=""   # 用的是默认 metadata 地址时，拦截规则的 FAIL 里多提醒一句
[ -z "${METADATA_IP:-}" ] && MD_HINT="。这台的云 metadata 地址不是 169.254.169.254 的话，用 METADATA_IP=<地址> 重跑 verify（04 章 4.5）"
METADATA_IP="${METADATA_IP:-169.254.169.254}"
GH_REPO="${GH_REPO:-}"

P=0; F=0
ok(){ printf '  \033[32mPASS\033[0m  %s\n' "$*"; P=$((P+1)); }
no(){ printf '  \033[31mFAIL\033[0m  %s\n' "$*"; F=$((F+1)); }
sk(){ printf '  \033[90mSKIP\033[0m  %s\n' "$*"; }
hdr(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

SVC=$(basename "$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)" 2>/dev/null || echo "")
NSVC=$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | wc -l)
# 有 job 在跑吗？按进程名精确匹配（-f 会被任何含这个词的命令行误触发）
BUSY=0; pgrep -x Runner.Worker >/dev/null 2>&1 && BUSY=1
# 本机的注册名和注册 ID。路径经环境变量传给 python，不拼进代码。
RN=""; RID=""
{ IFS= read -r RN; IFS= read -r RID; } < <(RUNNER_FILE="$RUNNER_HOME/.runner" python3 -c '
import json, os
d = json.load(open(os.environ["RUNNER_FILE"], encoding="utf-8-sig"))
print(d.get("agentName", "")); print(d.get("agentId", ""))' 2>/dev/null)

hdr "服务与开机自启（重启后这一段最要紧）"
for u in docker containerd ${SVC:-}; do
  [ -z "$u" ] && continue
  a=$(systemctl is-active "$u" 2>/dev/null); e=$(systemctl is-enabled "$u" 2>/dev/null)
  [ "$a" = "active" ] && [ "$e" = "enabled" ] && ok "$u  active + enabled" || no "$u  active=$a enabled=$e"
done
[ -n "$SVC" ] || no "找不到 runner 服务单元。还没注册？用 --skip-runner 装的机器注册前就是这样，注册后再跑一次"
[ "$NSVC" -gt 1 ] && sk "本机有 $NSVC 个 runner 服务，本脚本只检查第一个（$SVC）。同机多实例的前提见 10 章 10.6"

hdr "runner 加固"
if [ -n "$SVC" ]; then
  r=$(systemctl show "$SVC" -p Restart --value)
  s=$(systemctl show "$SVC" -p StartLimitIntervalUSec --value)
  m=$(systemctl show "$SVC" -p MemoryMax --value)
  o=$(systemctl show "$SVC" -p OOMScoreAdjust --value)
  [ "$r" = "always" ] && ok "Restart=always" || no "Restart=$r（应为 always，否则进程一死就一直停着）"
  [ "$s" = "0" ] && ok "StartLimitIntervalSec=0" || no "StartLimitIntervalUSec=$s（应为 0，否则 10 秒内失败 5 次后 systemd 停止重试）"
  [ "$m" != "infinity" ] && ok "MemoryMax=$m" || no "MemoryMax 未设"
  # 期望值是 /etc/ci-runner.env 里的 RUNNER_OOM_ADJ（机器上跑开发工具时会调低，见 04 章 4.3），没写就是默认 800
  want=${RUNNER_OOM_ADJ:-800}
  [ "$o" = "$want" ] && [ "$o" -gt 0 ] 2>/dev/null && ok "OOMScoreAdjust=$o" || no "OOMScoreAdjust=$o（应为 $want，且大于 0，让 CI 先于系统服务被 OOM 挑中）"
  systemctl show "$SVC" -p After --value | grep -q docker.service && ok "After=docker.service" || no "缺 After=docker.service（重启后可能先接到 job 再有 docker）"
else sk "无 runner 单元，跳过加固检查"; fi
# runner 用户的 uid 要和其他 runner 机器一致，也要和 CI 容器往工作区写文件的 uid 对得上（03 章 3.3）。
# 容器以什么身份写文件因项目而异，所以不一致只提示，不算 FAIL。
RU=$(id -u "$RUNNER_USER" 2>/dev/null || echo "")
if [ -z "$RU" ]; then no "没有 $RUNNER_USER 用户"
elif [ "$RU" = "$RUNNER_UID" ]; then ok "$RUNNER_USER 用户 uid=$RU，与 RUNNER_UID 一致（几台 runner 机器之间也要一致）"
else sk "$RUNNER_USER 用户 uid=$RU，不是 RUNNER_UID=$RUNNER_UID。CI 容器以别的 uid 写进工作区的文件 runner 删不掉，checkout 会报 EACCES（03 章 3.3、09 章 A19）。先确认你的容器以什么身份写文件"
fi

hdr "Docker 守护进程"
docker info 2>/dev/null | grep -qi 'live restore enabled: true' && ok "live-restore=true" || no "live-restore 未开（dockerd 重启会杀掉当前 job 的服务容器）"
GC=$(docker buildx inspect default 2>/dev/null | grep -A6 'GC Policy rule#0' | tr -d ' ')
echo "$GC" | grep -q 'MaxUsedSpace' && ok "BuildKit GC 有 Max Used 上限" || no "BuildKit GC 没有 Max Used 上限（defaultKeepStorage 只设 Reserved，会丢 Min Free 保护）"
echo "$GC" | grep -q 'MinFreeSpace' && ok "BuildKit GC 有 Min Free 底线" || no "BuildKit GC 没有 Min Free 底线"

hdr "清理与监控"
[ -x "$RUNNER_HOME/hooks/ci-cleanup.sh" ] && ok "清理脚本就位" || no "缺 $RUNNER_HOME/hooks/ci-cleanup.sh"

# 下面这一项是本组唯一执行钩子的检查，2026-09-07 事故后补。
#
# 那次事故里，上一行的「就位」、后面的「两个钩子都挂了」和「timer active」三项全部 PASS，
# 整表 24 PASS / 0 FAIL，而机器上连续 7 天每个 job 都红。这些检查只看结构：文件在不在、
# 变量挂没挂、timer 起没起，没有一项问过它到底能不能正常退出。
#
# runner 调钩子时强加 -e，钩子非零退出就把 job 判失败。所以这里用完全相同的方式跑一次，
# 才能区分「装上了」和「真能用」。
#
# 这一项会真的执行钩子。有 job 在跑时执行，会删掉那个 job 的容器、杀掉它在宿主上的进程，所以必须跳过。
# 2026-10-16 发现：本脚本原来自称「只读」，08 章又把它列为日常巡检，两者叠在一起就会打断 job（09 章 B14）。
if [ "$BUSY" = 1 ]; then
  sk "有 job 正在运行，跳过钩子实跑（它会删掉那个 job 的容器），空闲时再跑一次 verify.sh"
elif sudo -u "$RUNNER_USER" /usr/bin/bash -e "$RUNNER_HOME/hooks/ci-cleanup.sh" >/dev/null 2>&1; then
  ok "清理钩子按 runner 的调用方式（bash -e）可正常退出"
else
  no "清理钩子在 bash -e 下非零退出，每个 job 都会红（09 章 A11）。复现：sudo -u $RUNNER_USER /usr/bin/bash -ex $RUNNER_HOME/hooks/ci-cleanup.sh"
fi
grep -qE 'pgrep -c?x Runner\.Worker' "$RUNNER_HOME/hooks/ci-cleanup.sh" 2>/dev/null \
  && ok "钩子带「有 job 在跑就不动」的守卫（每日 timer 不会误删 job 的容器）" \
  || no "钩子缺少运行中 job 的守卫，每日 timer 撞上 job 时会删掉它的容器（按 04 章 4.4 重新部署 scripts/ci-cleanup.sh）"
# 只看赋值行：守卫那行故意保留 __CI_ 前缀做判据，不是残留（09 章 A12）。
grep -qE '^(L|APP_PORTS)=.*__CI_' "$RUNNER_HOME/hooks/ci-cleanup.sh" 2>/dev/null \
  && no "钩子赋值行仍含未替换的占位符：bootstrap 的 sed 没生效，按标签的清理全部落空" \
  || ok "钩子占位符已全部替换"

n=$(grep -c '^ACTIONS_RUNNER_HOOK_JOB_' "$RUNNER_HOME/.env" 2>/dev/null || echo 0)
[ "$n" -ge 2 ] && ok "两个钩子都挂了（STARTED + COMPLETED）" || no "只挂了 $n 个钩子（JOB_COMPLETED 在 job 初始化阶段就被取消、或 runner 服务被停掉时不执行，必须同时挂 JOB_STARTED）"
[ "$(systemctl is-active ci-cleanup.timer 2>/dev/null)" = "active" ] && ok "ci-cleanup.timer active" || no "ci-cleanup.timer 未运行（runner 被杀时钩子不执行，timer 是唯一兜底）"
CRON=$(ls /etc/cron.d/ 2>/dev/null | grep -E '^[a-z0-9-]*ci-health$' | head -1)
[ -x /usr/local/bin/ci-health.sh ] && [ -n "$CRON" ] && ok "健康监控已装（/etc/cron.d/$CRON）" || no "健康监控缺失"
grep -q 'var/lib/containerd' /usr/local/bin/ci-health.sh 2>/dev/null \
  && ok "监控量的是 /var/lib/containerd" || no "监控没量 /var/lib/containerd：Docker 29 的镜像字节大多在那里，只量 /var/lib/docker 会严重低估（09 章 A2）"
grep -q '^CI_DISK_WARN_MB=' "/etc/cron.d/$CRON" 2>/dev/null \
  && ok "磁盘告警阈值与 BuildKit GC 对齐（$(grep -h '^CI_DISK_WARN_MB=' "/etc/cron.d/$CRON")）" \
  || no "磁盘告警阈值没跟 GC 对齐：旧版写死 WARN<40G，会在设计稳态下每小时误报（重跑 bootstrap 会写进 cron.d）"
grep -qE '^CI_ALERT_WEBHOOK=.+' /etc/ci-health.env 2>/dev/null \
  && ok "告警会推送（CI_ALERT_WEBHOOK 已配；脚本目前只实现了飞书自定义机器人的格式）" \
  || sk "告警只写本机 journal（/etc/ci-health.env 里没配 CI_ALERT_WEBHOOK），没有接收方"
U=$(systemctl show ci-cleanup.service -p User --value 2>/dev/null)
[ "$U" = "$RUNNER_USER" ] && ok "每日清理以 $RUNNER_USER 身份运行" \
  || no "每日清理以 ${U:-root} 身份运行一个 $RUNNER_USER 可写的脚本，runner 能借此拿到 root"

hdr "部署参数与系统更新"
# bootstrap 的参数（CI_LABEL、CI_APP_PORTS、基线等）必须落盘。
# 不落盘的话，任何一次重新部署都会用默认值静默覆盖，把按标签清理、孤儿端口清理和争抢告警一起关掉（09 章 B15）。
if [ -r "$CI_RUNNER_ENV" ]; then
  ok "部署参数已落盘（$CI_RUNNER_ENV）"
  pl=${FILE_KV[CI_LABEL]:-}
  hl=$(sed -n 's/^L="\${CI_LABEL:-\(.*\)}".*/\1/p' "$RUNNER_HOME/hooks/ci-cleanup.sh" 2>/dev/null)
  [ -n "$pl" ] && [ "$pl" = "$hl" ] && ok "钩子的 CI 标签与落盘参数一致（$pl）" \
    || no "钩子的 CI 标签（$hl）与 $CI_RUNNER_ENV（$pl）不一致，有人用别的参数重新部署过"
  # 落盘的名字和实际注册名对不上，最常见的原因是这个文件从别的机器拷了过来（09 章 A18）
  fn=${FILE_KV[RUNNER_NAME]:-}
  if [ -n "$fn" ] && [ -n "$RN" ]; then
    [ "$fn" = "$RN" ] && ok "落盘的 RUNNER_NAME 与本机注册名一致（$RN）" \
      || no "落盘的 RUNNER_NAME（$fn）与本机注册名（$RN）不一致：这个文件可能是从别的机器拷来的，或者改了名字没有重新注册（03 章 3.6）"
  fi
else
  no "部署参数没有落盘（缺 $CI_RUNNER_ENV），下次重新部署会用默认值静默覆盖现有配置"
fi
cat /etc/needrestart/conf.d/*.conf 2>/dev/null | grep -qF 'actions\.runner\.' \
  && ok "needrestart 不会在 job 中途重启 runner" \
  || no "needrestart 会在安全更新时重启 runner，正在跑的 job 直接被杀（09 章 A13）"
if [ -f /var/run/reboot-required ]; then
  sk "有待生效的更新需要重启（$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | cut -c1-80)），找个没有 job 的时候重启"
else ok "没有待重启的更新"; fi

hdr "网络加固"
iptables -C DOCKER-USER -d "$METADATA_IP" -j DROP 2>/dev/null \
  && ok "容器读不到 metadata（DOCKER-USER 规则在）" || no "缺 DOCKER-USER 的 metadata 拦截（$METADATA_IP）$MD_HINT"
iptables -C OUTPUT -d "$METADATA_IP" -m owner --uid-owner "${RU:--1}" -j REJECT --reject-with icmp-port-unreachable 2>/dev/null \
  && ok "runner 用户读不到 metadata（OUTPUT 规则在）" || no "缺 OUTPUT 的 metadata 拦截（CI job 的 shell 是宿主进程，DOCKER-USER 管不到它）"
grep -q "$METADATA_IP" /etc/iptables/rules.v4 2>/dev/null && ok "iptables 规则已持久化（重启后仍在）" || no "iptables 规则未持久化，重启就没了"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  c=$(timeout 20 docker run --rm alpine:3.20 sh -c "wget -q -T3 -O- http://$METADATA_IP/ 2>/dev/null | head -c 1" 2>/dev/null || true)
  [ -z "$c" ] && ok "实拨验证：容器确实读不到 metadata" || no "实拨验证：容器仍能读到 metadata"
fi

hdr "SSH"
pa=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
if [ "$pa" = "no" ]; then ok "口令登录已关（authorized_keys 里 $(grep -cve '^\s*$' -e '^\s*#' /root/.ssh/authorized_keys 2>/dev/null || echo 0) 个公钥）"
else sk "口令登录仍开着（bootstrap.sh 默认不动它，要关加 --harden-ssh，见 04 章 4.6）"; fi

hdr "干净度"
if [ "$BUSY" = 1 ]; then sk "有 job 正在运行，容器属于它，跳过残留检查"
else [ "$(docker ps -aq 2>/dev/null | wc -l)" -eq 0 ] && ok "无残留容器" || no "有 $(docker ps -aq | wc -l) 个残留容器"; fi
# 默认 6 是按参考项目定的：三个服务容器，workflow 没挂 tmpfs 时每个 job 会短暂留下约 3 个匿名卷。
# 别的项目取每个 job 的服务容器数乘 2，用 CI_MAX_VOLUMES 传入（07 章 7.1）。
MAX_VOL="${CI_MAX_VOLUMES:-6}"
case "$MAX_VOL" in ''|*[!0-9]*) no "CI_MAX_VOLUMES=$MAX_VOL 不是整数，这里按 6 查"; MAX_VOL=6 ;; esac
nv=$(docker volume ls -q 2>/dev/null | wc -l)
[ "$nv" -le "$MAX_VOL" ] && ok "匿名卷没有累积（$nv 个，上限 $MAX_VOL）" \
  || no "有 $nv 个卷，超过上限 $MAX_VOL：清理钩子的 volume prune 可能没在跑，或者这个项目的服务容器多，要调高 CI_MAX_VOLUMES（07 章 7.1）"
# 阈值和 ci-health 用同一套，从 /etc/ci-runner.env 读（bootstrap 按 BUILDKIT_MIN_FREE + 1 GiB 推算后落盘），
# 盘大小不同的机器不会误报。低于 CRIT 是 FAIL；低于 WARN 说明 GC 已在按 Min Free 驱逐缓存，只提示。
WARN_MB="${CI_DISK_WARN_MB:-21504}"; CRIT_MB="${CI_DISK_CRIT_MB:-10240}"
case "$WARN_MB" in ''|*[!0-9]*) no "CI_DISK_WARN_MB=$WARN_MB 不是 MiB 整数（ci-health 会改用默认值并告警），这里按 21504 查"; WARN_MB=21504 ;; esac
case "$CRIT_MB" in ''|*[!0-9]*) no "CI_DISK_CRIT_MB=$CRIT_MB 不是 MiB 整数（ci-health 会改用默认值并告警），这里按 10240 查"; CRIT_MB=10240 ;; esac
av=$(df --output=avail -BM / 2>/dev/null | tail -1 | tr -dc 0-9)
if [ -z "$av" ]; then no "读不到根分区的可用空间"
elif [ "$av" -lt "$CRIT_MB" ]; then no "根分区只剩 ${av}MB，低于 CRIT 线 ${CRIT_MB}MB：GC 腾不出空间了，是 Docker 以外的东西在吃盘"
elif [ "$av" -lt "$WARN_MB" ]; then sk "根分区可用 ${av}MB，低于 WARN 线 ${WARN_MB}MB：GC 已在按 Min Free 驱逐缓存，看看 Docker 以外是什么在涨"
else ok "根分区可用 ${av}MB（WARN 线 ${WARN_MB}MB，CRIT 线 ${CRIT_MB}MB）"; fi

hdr "GitHub 侧"
if [ -z "$GH_REPO" ] || [ -z "${GH_TOKEN:-}" ]; then
  sk "没有 GH_TOKEN（或 GH_REPO），跳过。建议在 CI 机以外用 gh api 查（07 章 7.1），重启后补查一次"
elif [ -z "$RN$RID" ]; then
  no "读不到 $RUNNER_HOME/.runner，本机还没注册"
else
  # token 经标准输入交给 curl（-H @-），不放进命令行参数：参数对本机所有用户可见（ps、/proc/<pid>/cmdline），
  # runner 和正在跑的 CI job 都读得到（09 章 B19）。printf 是 bash 内建命令，不单独起进程。写法和 bootstrap.sh 相同。
  if J=$(printf 'Authorization: Bearer %s\n' "$GH_TOKEN" \
         | curl -fsS -H @- -H 'Accept: application/vnd.github+json' \
             "https://api.github.com/repos/$GH_REPO/actions/runners?per_page=100" 2>/dev/null); then
    # 按本机 .runner 里的注册 ID（agentId）找自己那一条。只按名字找的话，另一台机器用同名 --replace
    # 顶掉本机的注册之后，同名那条是 online 的（在线的是那一台），这里会误报 PASS（09 章 A18）。
    # .runner 里没有 agentId 时退回按名字找。
    st=$(printf '%s' "$J" | RN="$RN" RID="$RID" python3 -c '
import json, os, sys
rs = json.load(sys.stdin).get("runners") or []
rn, rid = os.environ["RN"], os.environ["RID"]
me = [r for r in rs if str(r.get("id")) == rid] if rid else [r for r in rs if r.get("name") == rn]
if me:
    print(me[0].get("status") or "?")
elif any(r.get("name") == rn for r in rs):
    print("replaced")
else:
    print("missing")' 2>/dev/null)
    case "$st" in
      online)   ok "runner $RN（id ${RID:-?}）在 GitHub 侧 online" ;;
      replaced) no "GitHub 上名为 $RN 的注册不是本机（本机 id $RID）：本机的注册被另一台用同名 --replace 顶掉了（09 章 A18）" ;;
      missing)  no "GitHub 上找不到本机的注册（$RN，id ${RID:-?}）" ;;
      *)        no "runner $RN（id ${RID:-?}）在 GitHub 侧是 ${st:-<返回内容解析失败>}" ;;
    esac
    echo "     注：这个字段有分钟级延迟，刚重启完可能还显示旧值，等 1 到 2 分钟再看。"
  else
    no "查 GitHub 失败：token 无效、没有 $GH_REPO 的 Administration: read 权限，或者网络不通"
  fi
fi

printf '\n\033[1m结果：PASS %d  FAIL %d\033[0m\n' "$P" "$F"
[ "$F" -eq 0 ] && { printf '  \033[32m全部通过\033[0m\n'; exit 0; } || { printf '  \033[31m有 %d 项未通过，排查见 09-踩坑记录.md\033[0m\n' "$F"; exit 1; }
