#!/usr/bin/env bash
# SSH 加固的安全网：只有在「确认文件还在」且「一条 SSH 会话都不剩」时才回滚。
# 后者是唯一真正危险的情形——你被踢下线且可能进不来了。
# 你确认能连上之后，删掉 /root/.ssh-hardening-unconfirmed 即可让它永久生效。
MARK=/root/.ssh-hardening-unconfirmed
[ -f "$MARK" ] || exit 0
if [ "$(ss -tn state established '( sport = :22 )' 2>/dev/null | tail -n +2 | wc -l)" -eq 0 ]; then
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf "$MARK"
  systemctl reload ssh 2>/dev/null
  logger -t ci-ssh-guard "SSH 加固已自动回滚：检测到零活跃会话"
  echo "$(date -Is) SSH hardening auto-reverted (no active sessions)" >> /var/log/ci-health.log
fi
