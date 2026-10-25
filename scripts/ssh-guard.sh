#!/usr/bin/env bash
# SSH 加固的安全网（04 章 4.6）：只有在「还没确认」的标记文件还在、而且一条 SSH 会话都不剩时，才回滚加固。
# 后一种情况才真正危险：你被踢下线，可能进不来了。
# 确认能登入之后，删掉 /root/.ssh-hardening-unconfirmed，再停掉跑它的 timer，加固就永久生效。
MARK=/root/.ssh-hardening-unconfirmed
[ -f "$MARK" ] || exit 0

# 数会话前先弄清 sshd 实际监听哪些端口，不假定是 22。SSH 改过端口的机器上，数 22 端口永远是 0 个会话，
# 第一次运行就会把加固误回滚。端口从 sshd -T 读（Port 和 ListenAddress 两项），再并上 sshd 进程
# 正在监听的端口；两边都读不到才退回 22。
ports=$( { sshd -T 2>/dev/null | awk '$1=="port"{print $2} $1=="listenaddress"{n=split($2,a,":"); print a[n]}'
           ss -Htlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}'; } | grep -E '^[0-9]+$' | sort -un)
[ -n "$ports" ] || ports=22
filter=""
for p in $ports; do filter="${filter:+$filter or }sport = :$p"; done
plist=$(echo $ports)

if [ "$(ss -Htn state established "( $filter )" 2>/dev/null | wc -l)" -eq 0 ]; then
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf "$MARK"
  # Ubuntu、Debian 的服务名是 ssh，别的发行版多是 sshd
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  logger -t ci-ssh-guard "SSH 加固已自动回滚：端口 $plist 上没有已建立的会话"
  echo "$(date -Is) SSH hardening auto-reverted (no established sessions on port(s) $plist)" >> /var/log/ci-health.log
  # 04 章 4.6 用 systemd-run 建的临时 timer 叫 ssh-guard。回滚之后不用再跑；timer 叫别的名字时这一行什么也不做。
  systemctl stop ssh-guard.timer 2>/dev/null || true
fi
