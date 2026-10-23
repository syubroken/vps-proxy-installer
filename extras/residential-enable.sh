#!/bin/bash
# 住宅 IP 分流：启用。在服务器上以 root 运行：
#   bash /root/residential-enable.sh                    第一次启用或换密码：在交互终端里输入代理密码（不显示）
#   bash /root/residential-enable.sh --keep-password    只更新规则或名单，沿用服务器上已有的密码
#   bash /root/residential-enable.sh --dry-run          只生成并检查，不改任何东西（用假密码）
#   以上都可以再加 --with-emergency：同时开“应急入口”（见下）。开过一次后，以后每次运行都会自动保留它。
# 服务商参数（第一次启用时 --server 和 --user 必须写；以后不写，就沿用上次保存的）：
#   --server 地址:端口       住宅代理服务商给的接入地址，例如 proxy.example.com:10000
#   --protocol http|socks    代理协议（必须支持用户名 + 密码登录）
#   --user 用户名            代理用户名
#   --expected-ip IP         网站应该看到的住宅出口 IP；换了服务商或端口又不知道时可以不写，提醒程序第一次检测时自动记下
#   旧写法 [端口] [用户名] 仍然可用。
# 这些设置（不含密码）保存在 /etc/senyz-proxy-simple/residential.json，预检、自测和邮件提醒都从这里读。
# 作用：让 AI 网站改走静态住宅 IP，其他网站照旧走 WARP。
# 应急入口：同一个入口里的第二个用户（UUID 存在 /etc/senyz-proxy-simple/emergency.json，仅 root 可读）。
#   用它连上来时一律走 WARP、不走住宅 IP；住宅 IP 出问题时，在客户端切到应急节点就能继续用 AI（例如联系 Claude）。
#   不改防火墙、Nginx 和路径，客户端只多一个节点。
# 连接住宅代理的仍是代理程序本身，按服务器安全规则只能经 WARP 发出；WARP、nft、证书、SSH 都不改。
# 每次都从备份的原配置重新生成，可以重复运行。撤销：bash /root/residential-disable.sh（应急入口也一起撤掉）
set -euo pipefail
umask 077
C=/etc/senyz-proxy-simple/v2ray.json
BK=/etc/senyz-proxy-simple/v2ray.json.before-residential
EM=/etc/senyz-proxy-simple/emergency.json
SET=/etc/senyz-proxy-simple/residential.json
B=/opt/senyz-proxy-simple/bin/v2ray
KEEP=0; DRY=0; EMERG=0; ARGS=()
SERVER=''; PROTO=''; RUSER=''; EXPECT=''
while (( $# )); do
    case $1 in
        --keep-password) KEEP=1 ;;
        --dry-run) DRY=1 ;;
        --with-emergency) EMERG=1 ;;
        --server) SERVER=${2:-}; shift ;;
        --protocol) PROTO=${2:-}; shift ;;
        --user) RUSER=${2:-}; shift ;;
        --expected-ip) EXPECT=${2:-}; shift ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done
[[ -f $EM ]] && EMERG=1
PORT_ARG="${ARGS[0]:-}"
[[ -z $RUSER && -n ${ARGS[1]:-} ]] && RUSER=${ARGS[1]}

[[ $EUID == 0 ]] || { echo '停止：需要 root。'; exit 2; }
[[ -f $C && -x $B ]] || { echo '停止：没有找到本方案的 V2Ray 配置，未改动。'; exit 2; }
[[ -z $PORT_ARG || $PORT_ARG =~ ^[0-9]+$ ]] || { echo '停止：端口不对。'; exit 2; }
(( KEEP || DRY )) || [[ -t 0 ]] || { echo '停止：需要在交互终端里运行（要输入密码）。'; exit 2; }

# 解析服务商设置：命令行 > 上次保存的。脚本里不带任何人的默认值，第一次启用要写 --server 和 --user。只输出不含密码的设置。
NEWSET=$(python3 - "$SET" "$SERVER" "$PROTO" "$RUSER" "$EXPECT" "$PORT_ARG" <<'EOF'
import ipaddress, json, os, sys
path, server, proto, user, expect, port = sys.argv[1:7]
s = {'server': '', 'port': 0, 'protocol': 'http', 'user': '', 'expected_ip': ''}
if os.path.exists(path):
    s.update(json.load(open(path)))
endpoint = (s['server'], int(s['port']))
if server:
    host, _, p = server.rpartition(':')
    if not host or not p.isdigit():
        sys.exit('停止：--server 要写成 地址:端口，例如 proxy.example.com:10000。')
    s['server'], s['port'] = host, int(p)
if port:
    s['port'] = int(port)
if (s['server'], int(s['port'])) != endpoint and not expect:
    s['expected_ip'] = ''  # a different endpoint usually means a different exit IP: learn it on the first check
if proto:
    s['protocol'] = proto
if user:
    s['user'] = user
if expect:
    s['expected_ip'] = expect
if not s['server'] or not int(s['port']):
    sys.exit('停止：还没有保存过住宅代理的设置，第一次启用要写 --server 地址:端口（服务商给的接入地址）。')
if not s['user']:
    sys.exit('停止：第一次启用要写 --user 用户名（住宅代理的用户名）。')
if s['protocol'] not in ('http', 'socks'):
    sys.exit('停止：--protocol 只能是 http 或 socks。')
if s['expected_ip']:
    try:
        ipaddress.ip_address(s['expected_ip'])
    except ValueError:
        sys.exit('停止：--expected-ip 不是有效的 IP 地址。')
print(json.dumps(s, ensure_ascii=False))
EOF
)
read -r HOST PORT PROTO RUSER EXPECT < <(python3 -c 'import json, sys; s = json.loads(sys.argv[1]); print(s["server"], s["port"], s["protocol"], s["user"], s["expected_ip"] or "-")' "$NEWSET")
echo "住宅代理：$HOST:$PORT（$PROTO），用户名 $RUSER，预期出口 ${EXPECT/#-/未设定（提醒程序第一次检测时自动记下）}"

if (( DRY )); then
    SRC=$BK; [[ -f $BK ]] || SRC=$C
else
    if [[ ! -f $BK ]]; then
        (( KEEP )) && { echo '停止：还没启用过，不能沿用密码；请不带 --keep-password 运行。'; exit 2; }
        cp -p "$C" "$BK"
        echo "已备份原配置：$BK"
    else
        echo "沿用已有的原配置备份：$BK"
    fi
    SRC=$BK
    if (( EMERG )) && [[ ! -f $EM ]]; then
        python3 -c 'import json, os, sys, uuid
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"uuid": str(uuid.uuid4())}, f)' "$EM"
        echo "已生成应急入口：$EM（仅 root 可读）"
    fi
fi

PW=dry-run-dummy
if (( ! KEEP && ! DRY )); then
    read -rsp "请输入代理用户 $RUSER（$HOST）的密码（输入时不显示，输完按回车）：" PW
    echo
    [[ -n $PW ]] || { echo '没有输入，未改动。'; exit 1; }
fi

TMP=$(mktemp /etc/senyz-proxy-simple/.v2ray.json.XXXXXX)
trap 'rm -f "$TMP"' EXIT
# 密码经环境变量传给 Python，不出现在命令行或屏幕上；--keep-password 时在 Python 内部从当前配置取出，也不显示。
RESI_PW="$PW" python3 - "$SRC" "$C" "$TMP" "$NEWSET" "$KEEP" "$DRY" "$EMERG" "$EM" <<'EOF'
import json, os, sys, uuid
src, cur, dst, newset, keep, dry, emerg, em = sys.argv[1:9]
s = json.loads(newset)
c = json.load(open(src))  # always start from the original config

if keep == '1':
    old = [o for o in json.load(open(cur)).get('outbounds', []) if o.get('tag') == 'residential']
    if not old:
        sys.exit('停止：当前配置里没有住宅出口，不能沿用密码；请不带 --keep-password 运行。')
    users = old[0]['settings']['servers'][0]['users']
    if users[0].get('user') != s['user']:
        sys.exit('停止：用户名变了，要重新输入密码；请不带 --keep-password 运行。')
else:
    users = [{'user': s['user'], 'pass': os.environ['RESI_PW']}]
# The http and socks outbounds take the same server/user structure in V2Ray 5.
servers = [{'address': s['server'], 'port': int(s['port']), 'users': users}]

# Sniffing: recover the domain from TLS/HTTP/QUIC when a client hands over only an IP (v2rayN's sing-box TUN does,
# measured 2026-10-21). v2fly ignores routeOnly, so the sniffed domain also replaces the destination for all traffic.
for i in c['inbounds']:
    i['sniffing'] = {'enabled': True, 'destOverride': ['http', 'tls', 'quic']}

rules = []
if emerg == '1':
    # Emergency entrance: a second VMess user on the same inbound. Its traffic always leaves via WARP, so the
    # user can still reach AI sites (and Claude) when the residential exit is down. A dry run uses a dummy id.
    em_id = json.load(open(em))['uuid'] if os.path.exists(em) else str(uuid.uuid4())
    clients = c['inbounds'][0]['settings']['clients']
    clients[:] = [x for x in clients if x.get('email') != 'emergency@local']
    clients.append({'id': em_id, 'alterId': 0, 'email': 'emergency@local'})
    rules.append({'type': 'field', 'user': ['emergency@local'], 'outboundTag': 'warp-only'})

c['outbounds'] = [o for o in c['outbounds'] if o.get('tag') not in ('residential', 'block')]
# domainStrategy: resolve the provider's address with V2Ray's own DoH. The proxy UID cannot use the system resolver
# (127.0.2.x is blocked by nft); without this every AI request fails with "lookup ... 127.0.2.3:53" (precheck 2026-10-21).
c['outbounds'].append({'tag': 'residential', 'protocol': s['protocol'], 'domainStrategy': 'UseIPv4',
                       'settings': {'servers': servers}})
c['outbounds'].append({'tag': 'block', 'protocol': 'blackhole'})

AI = [
    # Anthropic / Claude: site, app, docs, console, API, artifacts, short links, MCP docs
    'domain:anthropic.com', 'domain:claude.ai', 'domain:claude.com', 'domain:claudeusercontent.com',
    'domain:claude.site', 'domain:clau.de', 'domain:modelcontextprotocol.io',
    # OpenAI / ChatGPT / Codex / Sora, plus the login captcha provider
    'domain:openai.com', 'domain:chatgpt.com', 'domain:oaistatic.com', 'domain:oaiusercontent.com',
    'domain:sora.com', 'domain:chat.com', 'domain:arkoselabs.com',
    # Cloudflare Turnstile: the human check on AI login pages must see the same IP as the site
    'full:challenges.cloudflare.com',
    # Google services except YouTube (user, 2026-10-21 evening): Google treats the shared WARP exits as mainland
    # China plus "unusual traffic" (google.com -> google.cn / hkredirect / sorry page), so search, login, Gmail
    # and Gemini (all under google.com) use the residential IP. Static files (gstatic, googleapis) stay on WARP.
    # YouTube stays on WARP as a whole: video traffic is heavy, and its stream URLs are bound to the page's IP.
    'domain:google.com', 'domain:google.com.hk',
    # Left on WARP on purpose: Grok (does not restrict by IP; add only when the user asks).
    # Stripe left out: it is shared by all shops.
]
rules += [
    # QUIC cannot go through the residential proxy and may escape sniffing; block it so browsers fall back to TCP/TLS.
    {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'},
    {'type': 'field', 'domain': AI, 'outboundTag': 'residential'},
]
c['routing'] = {'domainStrategy': 'AsIs', 'rules': rules}
json.dump(c, open(dst, 'w'), indent=2)
if dry == '1':
    print('outbounds:', [(o['tag'], o['protocol']) for o in c['outbounds']], '| default:', c['outbounds'][0]['tag'])
    print('sniffing:', [i.get('sniffing') for i in c['inbounds']])
    print('clients:', len(c['inbounds'][0]['settings']['clients']), '| emergency entrance:', emerg == '1')
    print('rules:', [(r['outboundTag'], r.get('user') or len(r.get('domain', [])) or r.get('network')) for r in c['routing']['rules']])
EOF
unset PW

if ! "$B" test -format json -config "$TMP" >/dev/null 2>&1; then
    echo '停止：新配置没有通过 V2Ray 检查，原配置未改动。'
    exit 1
fi
if (( DRY )); then
    echo '空跑：新配置通过 V2Ray 检查，没有改动任何东西。'
    exit 0
fi
chown root:sps-proxy "$TMP"
chmod 640 "$TMP"
mv -f "$TMP" "$C"
trap - EXIT
# Save the provider settings (no password) for the precheck, the self-test and the mail alert.
printf '%s\n' "$NEWSET" > "$SET.tmp" && chmod 600 "$SET.tmp" && mv -f "$SET.tmp" "$SET"

echo '重启代理（几秒钟）……'
systemctl restart sps-proxy.service
for _ in $(seq 1 45); do systemctl is-active --quiet sps-proxy.service && break; sleep 2; done
if systemctl is-active --quiet sps-proxy.service; then
    echo "已启用：AI 网站改走住宅 IP（$HOST:$PORT），其他网站照旧走 WARP。"
    (( EMERG )) && echo '应急入口已开：用应急节点连上来时一律走 WARP。'
    exit 0
else
    echo '代理没有正常启动，自动换回原配置……'
    cp -p "$BK" "$C"
    systemctl restart sps-proxy.service
    exit 1
fi
