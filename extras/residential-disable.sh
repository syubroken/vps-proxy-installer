#!/bin/bash
# 住宅 IP 分流：撤销。在服务器上以 root 运行：bash /root/residential-disable.sh
# 换回启用前备份的原配置并重启代理（几秒钟）。之后 AI 网站恢复走 WARP，服务器上也不再保存住宅代理的密码。
set -euo pipefail
C=/etc/senyz-proxy-simple/v2ray.json
BK=/etc/senyz-proxy-simple/v2ray.json.before-residential
B=/opt/senyz-proxy-simple/bin/v2ray

[[ $EUID == 0 ]] || { echo '停止：需要 root。'; exit 2; }
[[ -f $BK ]] || { echo '没有找到启用前的备份，说明从未启用过，无需撤销。'; exit 0; }
"$B" test -format json -config "$BK" >/dev/null 2>&1 || { echo '停止：备份文件没通过 V2Ray 检查，未改动，请保留现场。'; exit 1; }
cp -p "$BK" "$C"
systemctl restart sps-proxy.service
for _ in $(seq 1 45); do systemctl is-active --quiet sps-proxy.service && break; sleep 2; done
systemctl is-active --quiet sps-proxy.service && echo '已撤销：AI 网站恢复走 WARP。' || { echo '代理没有正常启动，请保留现场并查看 status。'; exit 1; }
