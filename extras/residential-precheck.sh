#!/bin/bash
# 住宅 IP 分流：预检（不用密码，不改配置）。在服务器上以 root 运行：
#   bash /root/residential-precheck.sh [--server 地址:端口] [--protocol http|socks]
# 不写参数时用 /etc/senyz-proxy-simple/residential.json 里保存的设置；还没启用过，就必须写 --server。
# 也接受 --user / --expected-ip（会忽略），方便和启用脚本用同一串参数。
# 目的：启用前确认“以代理用户身份、经 WARP”能连上住宅代理的接入地址。
# 做法：用代理用户身份临时起一个测试用 V2Ray，出口设置和启用后完全一样，但不带密码。
#   对方回“需要认证”（HTTP 是 407）就说明线路是通的；约 30 秒后自动清理，不留任何东西。
# 入口用本机套接字文件而不是 127.0.0.1 端口：nft 只允许代理用户在 10001 端口上回应本机连接。
# 结果：退出码 0 = 能连上；1 = 连不上（会写明原因）。
set -u
C=/etc/senyz-proxy-simple/v2ray.json
SET=/etc/senyz-proxy-simple/residential.json
B=/opt/senyz-proxy-simple/bin/v2ray
U=sps-proxy
SERVER=''; PROTO=''
while (( $# )); do
    case $1 in
        --server) SERVER=${2:-}; shift ;;
        --protocol) PROTO=${2:-}; shift ;;
        --user|--expected-ip) shift ;;
    esac
    shift
done
read -r HOST PORT PROTO < <(python3 - "$SET" "$SERVER" "$PROTO" <<'EOF'
import json, os, sys
path, server, proto = sys.argv[1:4]
s = {'server': '', 'port': 0, 'protocol': 'http'}  # no built-in provider, like the enable script
if os.path.exists(path):
    s.update(json.load(open(path)))
if server:
    host, _, p = server.rpartition(':')
    s['server'], s['port'] = host or server, int(p) if p.isdigit() else s['port']
if proto:
    s['protocol'] = proto
if not s['server'] or not int(s['port']):
    sys.exit('停止：还没有保存过住宅代理的设置，要写 --server 地址:端口。')
print(s['server'], s['port'], s['protocol'])
EOF
)
[[ -n ${HOST:-} ]] || exit 2  # the reason was printed above
echo "测试对象：$HOST:$PORT（$PROTO），不带密码。"
echo "以 root 身份解析：$(timeout 6 getent ahostsv4 "$HOST" | awk '{print $1}' | sort -u | tr '\n' ' ')"
DIR=$(mktemp -d /run/sps-residential-precheck.XXXXXX)
cleanup() { pkill -f "$DIR/t.json" 2>/dev/null; sleep 1; rm -rf "$DIR"; }
trap cleanup EXIT
chown $U "$DIR"; chmod 755 "$DIR"
python3 - "$C" "$DIR/t.json" "$HOST" "$PORT" "$PROTO" <<'EOF'
import json, os, sys
live, dst, host, port, proto = sys.argv[1:6]
d = os.path.dirname(dst)
dns = json.load(open(live)).get('dns')  # same DoH as the live config
cfg = {'log': {'loglevel': 'debug'}, 'dns': dns,
       'inbounds': [{'tag': 'in', 'listen': '127.0.0.1', 'port': 18455, 'protocol': 'socks', 'settings': {'auth': 'noauth'},
                     'streamSettings': {'network': 'domainsocket', 'dsSettings': {'path': d + '/t.sock'}}}],
       # Same outbound as the enable script (domainStrategy UseIPv4), but without credentials on purpose.
       'outbounds': [{'tag': 'res', 'protocol': proto, 'domainStrategy': 'UseIPv4',
                      'settings': {'servers': [{'address': host, 'port': int(port)}]}}]}
open(dst, 'w').write(json.dumps(cfg))
EOF
chmod 644 "$DIR/t.json"
runuser -u $U -- "$B" run -config "$DIR/t.json" >"$DIR/log" 2>&1 &
sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 --proxy "socks5h://localhost$DIR/t.sock" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
sleep 1
fail=$(grep -E 'failed to process outbound' "$DIR/log" | sed -E 's/^[0-9/]+ [0-9:.]+ //; s/\[Info\] \[[0-9]+\] //' | head -1 | cut -c1-220)
echo "V2Ray 记录：${fail:-（没有出错记录）}"
if [[ $code == 200 ]]; then
    echo '结论：能连上，而且对方没要密码就放行了（可能用了 IP 白名单）。本方案要求用户名 + 密码登录，请确认服务商的设置。'
    exit 0
elif [[ -z $fail ]]; then
    echo '结论：没有得到明确结果，请把上面几行告诉 Claude。'
    exit 1
elif grep -qiE 'lookup |i/o timeout|connection refused|no route|network is unreachable|deadline exceeded|connection reset' <<<"$fail"; then
    echo '结论：连不上住宅代理的接入地址（解析失败、超时或被拒绝），先别启用。'
    exit 1
else
    echo '结论：能连上。对方因为没带密码拒绝了我们（HTTP 代理会回 407），这正说明线路是通的。'
    exit 0
fi
