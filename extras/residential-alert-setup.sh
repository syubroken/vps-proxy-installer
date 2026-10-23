#!/bin/bash
# 住宅 IP 失效邮件提醒：安装。先把检测程序放到 /root/residential-alert-check.py，然后在服务器上以 root 运行：
#   bash /root/residential-alert-setup.sh [发信服务器]   第一次安装或换授权码：要在交互终端里运行，并输入邮箱地址和授权码。
#     发信服务器不写时按邮箱推断，例如 xxx@163.com 用 smtp.163.com，xxx@qq.com 用 smtp.qq.com（都用 465 端口）
#   bash /root/residential-alert-setup.sh --update       只更新检测程序和定时器，沿用已保存的邮件设置，不用交互
# 作用：每 10 分钟检测一次 AI 网站是否还走住宅 IP。连续 2 次失败发邮件，之后每 24 小时提醒一次，恢复时再发一封。
# 每次检测约用几 KB 流量，访问的是 challenges.cloudflare.com，不碰 AI 账号，也不重启代理。
# 邮件用你自己的邮箱发给你自己，不经过其他第三方服务。授权码只存在服务器 /etc/residential-alert/mail.conf（仅 root 可读）。
# 卸载：bash /root/residential-alert-remove.sh
set -euo pipefail
umask 077
SRC=/root/residential-alert-check.py
LIB=/usr/local/lib/residential-alert
CONF=/etc/residential-alert/mail.conf
UPDATE=0
[[ ${1:-} == --update ]] && { UPDATE=1; shift; }
HOST="${1:-}"

[[ $EUID == 0 ]] || { echo '停止：需要 root。'; exit 2; }
[[ -x /opt/senyz-proxy-simple/bin/v2ray ]] || { echo '停止：没有找到本方案的代理。'; exit 2; }
[[ -f $SRC ]] || { echo "停止：没有找到 $SRC，请先上传检测程序。"; exit 2; }
python3 -m py_compile "$SRC" || { echo '停止：检测程序有错误，未改动。'; exit 2; }
if (( UPDATE )); then
    [[ -f $CONF ]] || { echo '停止：还没有安装过（没有邮件设置），请不带 --update 运行。'; exit 2; }
else
    [[ -t 0 ]] || { echo '停止：需要在交互终端里运行（要输入授权码）。'; exit 2; }
    read -rp '请输入你的邮箱地址（提醒从这个邮箱发给它自己）：' ADDR
    [[ $ADDR =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo '邮箱地址格式不对，未改动。'; exit 1; }
    [[ -n $HOST ]] || HOST="smtp.${ADDR##*@}"
    echo "发信服务器：$HOST（465 端口）"
    read -rsp '请输入邮箱的授权码（不是登录密码；输入时不显示，输完按回车）：' CODE
    echo
    [[ -n $CODE ]] || { echo '没有输入，未改动。'; exit 1; }
fi

mkdir -p /etc/residential-alert "$LIB" /var/lib/residential-alert
chmod 700 /etc/residential-alert "$LIB" /var/lib/residential-alert
if (( ! UPDATE )); then
    # 授权码经环境变量传给 Python，不出现在命令行或屏幕上。
    ALERT_ADDR="$ADDR" ALERT_CODE="$CODE" ALERT_HOST="$HOST" python3 - <<'EOF'
import json, os
c = {'host': os.environ['ALERT_HOST'], 'port': 465, 'user': os.environ['ALERT_ADDR'],
     'to': os.environ['ALERT_ADDR'], 'pass': os.environ['ALERT_CODE']}
fd = os.open('/etc/residential-alert/mail.conf', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f)
EOF
    unset CODE
fi
install -m 700 "$SRC" "$LIB/check.py"

cat > /etc/systemd/system/residential-alert.service <<'EOF'
[Unit]
Description=Residential IP alert check
After=network-online.target sps-proxy.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/residential-alert/check.py check
EOF
cat > /etc/systemd/system/residential-alert.timer <<'EOF'
[Unit]
Description=Residential IP alert check every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF
chmod 644 /etc/systemd/system/residential-alert.service /etc/systemd/system/residential-alert.timer
systemctl daemon-reload

if (( UPDATE )); then
    systemctl enable residential-alert.timer >/dev/null 2>&1
    systemctl restart residential-alert.timer
    echo '已更新检测程序和定时器（沿用原来的邮件设置）：每 10 分钟检测一次。'
    exit 0
fi
echo '发一封测试邮件……'
if ! python3 "$LIB/check.py" test-mail; then
    echo '提醒还没有开启。请核对邮箱地址、授权码，以及邮箱里 SMTP 服务是否开着，然后重新运行本脚本。'
    exit 1
fi
echo '先检测一次（不会发信，除非已经连续失败）：'
python3 "$LIB/check.py" check
systemctl enable --now residential-alert.timer >/dev/null 2>&1
echo '已开启：每 10 分钟检测一次。'
