#!/bin/bash
# 住宅 IP 失效邮件提醒：卸载。在服务器上以 root 运行：bash /root/residential-alert-remove.sh
# 停掉定时检测，删除检测程序、状态和邮件设置。之后服务器上不再保存邮箱授权码。
set -u
[[ $EUID == 0 ]] || { echo '停止：需要 root。'; exit 2; }
systemctl disable --now residential-alert.timer >/dev/null 2>&1
rm -f /etc/systemd/system/residential-alert.service /etc/systemd/system/residential-alert.timer
systemctl daemon-reload
rm -rf /etc/residential-alert /usr/local/lib/residential-alert /var/lib/residential-alert /run/residential-alert.lock
echo '已卸载邮件提醒，服务器上不再保存邮箱授权码。'
