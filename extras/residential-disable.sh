#!/bin/bash
# 住宅 IP 分流：撤销。在服务器上以 root 运行：bash /root/residential-disable.sh
# 换回启用前备份的原配置并重启代理（几秒钟）。之后 AI 网站恢复走 WARP，服务器上也不再保存住宅代理的密码。
# 同时在设置文件里记下“这是有意撤销的”，邮件提醒就不会把它当成故障；设置本身留着，以后再启用时沿用。
set -euo pipefail
C=/etc/senyz-proxy-simple/v2ray.json
BK=/etc/senyz-proxy-simple/v2ray.json.before-residential
SET=/etc/senyz-proxy-simple/residential.json
B=/opt/senyz-proxy-simple/bin/v2ray

[[ $EUID == 0 ]] || { echo '停止：需要 root。'; exit 2; }
[[ -f $BK ]] || { echo '没有找到启用前的备份，说明从未启用过，无需撤销。'; exit 0; }
"$B" test -format json -config "$BK" >/dev/null 2>&1 || { echo '停止：备份文件没通过 V2Ray 检查，未改动，请保留现场。'; exit 1; }
cp -p "$BK" "$C"
if [[ -f $SET ]]; then
    python3 - "$SET" <<'EOF'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path))
s['enabled'] = False  # switched off on purpose: the mail alert stops checking until the enable script runs again
fd = os.open(path + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(s, f, ensure_ascii=False)
    f.write('\n')
os.replace(path + '.tmp', path)
EOF
fi
systemctl restart sps-proxy.service || true
for _ in $(seq 1 45); do systemctl is-active --quiet sps-proxy.service && break; sleep 2; done
systemctl is-active --quiet sps-proxy.service && echo '已撤销：AI 网站恢复走 WARP，邮件提醒也不再检测住宅 IP。' || { echo '代理没有正常启动，请保留现场并查看 status。'; exit 1; }
