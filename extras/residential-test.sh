#!/bin/bash
# 住宅 IP 分流：自测（只看不改）。在服务器上以 root 运行：bash /root/residential-test.sh
# 做法与安装程序的“完整链路检查”相同：在本机临时起一个模拟客户端，经 Nginx/TLS/VMess 进入代理，
# 再看不同网站看到的出口。脚本会在服务器内部读取节点参数，但不显示 UUID、密码或配置内容。
# 开了应急入口（/etc/senyz-proxy-simple/emergency.json）时，再用应急用户测一组：应该全部走 WARP。
set -euo pipefail
B=/opt/senyz-proxy-simple/bin/v2ray
EM=/etc/senyz-proxy-simple/emergency.json
DIR=$(mktemp -d /run/sps-residential-test.XXXXXX)
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true; rm -rf "$DIR"' EXIT
PORT=18453
EPORT=18454
client() {  # $1 = output file, $2 = socks port, $3 = uuid source ("main" or "emergency")
python3 - "$1" "$2" "$3" "$EM" <<'EOF'
import json, sys
s = json.load(open('/var/lib/senyz-proxy-simple/state.json'))
p = json.load(open('/etc/senyz-proxy-simple/private.json'))
uid = p['uuid'] if sys.argv[3] == 'main' else json.load(open(sys.argv[4]))['uuid']
cfg = {'log': {'loglevel': 'none'},
       'inbounds': [{'listen': '127.0.0.1', 'port': int(sys.argv[2]), 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': False}}],
       'outbounds': [{'protocol': 'vmess', 'settings': {'vnext': [{'address': s['ssh']['server'], 'port': 443,
                      'users': [{'id': uid, 'alterId': 0, 'security': 'auto'}]}]},
                      'streamSettings': {'network': 'ws', 'security': 'tls',
                                         'tlsSettings': {'serverName': s['domain'], 'allowInsecure': False},
                                         'wsSettings': {'path': p['path'], 'headers': {'Host': s['domain']}}}}]}
open(sys.argv[1], 'w').write(json.dumps(cfg))
EOF
"$B" run -config "$1" >/dev/null 2>&1 &
PIDS+=($!)
}
trace() {  # $1 = curl socks option, $2 = port, $3 = site
    out=$(curl -s --max-time 25 "$1" "127.0.0.1:$2" "https://$3/cdn-cgi/trace" || true)
    ip=$(printf '%s\n' "$out" | sed -n 's/^ip=//p'); loc=$(printf '%s\n' "$out" | sed -n 's/^loc=//p'); warp=$(printf '%s\n' "$out" | sed -n 's/^warp=//p')
    printf '%-20s ip=%s loc=%s warp=%s\n' "$3" "${ip:-（无响应）}" "${loc:-?}" "${warp:-?}"
}
client "$DIR/client.json" "$PORT" main
[[ -f $EM ]] && client "$DIR/client-em.json" "$EPORT" emergency
# Expected residential exit, from the settings the enable script saved (no password in that file).
echo "预期住宅出口：$(python3 -c 'import json, sys
try: s = json.load(open(sys.argv[1]))
except OSError: s = None
print("未知（没有保存的设置，可能是用旧版脚本启用的）" if s is None else
      (s.get("expected_ip") or "未设定（提醒程序第一次检测时自动记下）") + "，经 %s:%s" % (s.get("server"), s.get("port")))' /etc/senyz-proxy-simple/residential.json)"
sleep 2
# 加参数 timing：每个网站连续连 10 次，列出每次建立连接用的秒数，用来查偶发卡顿。
if [[ ${1:-} == timing ]]; then
    for mode in 发域名 只发IP; do
        [[ $mode == 发域名 ]] && opt=--socks5-hostname || opt=--socks5
        echo "--- 客户端$mode（每次建立连接的秒数）："
        for url in https://www.google.com/generate_204 https://www.youtube.com/generate_204 https://chatgpt.com/cdn-cgi/trace https://www.cloudflare.com/cdn-cgi/trace; do
            t=$(for _ in $(seq 1 10); do curl -s -o /dev/null --max-time 20 -w '%{time_appconnect}\n' "$opt" "127.0.0.1:$PORT" "$url" || echo 20; done | awk '{printf "%.1f ", $1}')
            printf '%-42s %s\n' "$url" "$t"
        done
    done
    exit 0
fi
# 两种情形：客户端把域名交给服务器（多数客户端），以及客户端先自己解析、只交 IP（部分软件自带 DNS 时）。
for mode in 发域名 只发IP; do
    [[ $mode == 发域名 ]] && opt=--socks5-hostname || opt=--socks5
    echo "--- 客户端$mode："
    for site in claude.ai chatgpt.com grok.com www.cloudflare.com; do trace "$opt" "$PORT" "$site"; done
done
if [[ -f $EM ]]; then
    echo "--- 应急入口（应该全部是 warp=on）："
    for site in claude.ai chatgpt.com grok.com; do trace --socks5-hostname "$EPORT" "$site"; done
fi
