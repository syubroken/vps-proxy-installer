#!/bin/bash
# 纯代理：不用 WARP，也不用住宅 IP。所有网站都从这台服务器自己的 IPv4 出去。
# 用于 WARP 和住宅 IP 都用不了时，在一台全新的 Debian 13 服务器上单独安装。不能和 WARP 方案装在同一台服务器上。
#
# 协议和现在的节点一样：VMess + WebSocket + TLS。Nginx 守在 443 端口，证书来自 Let's Encrypt，客户端的填法也一样。
#
# 用法（在服务器的 root 终端里）：
#   bash pure-proxy.sh install [--domain 域名] [--email 邮箱]   安装；中途停了，再运行一次会接着做
#   bash pure-proxy.sh status                                   查看状态，并做一次完整自测
#   bash pure-proxy.sh node                                     显示节点链接和二维码（只给你自己看）
#   bash pure-proxy.sh uninstall                                卸载本方案装的服务和配置
#
# 用到的组件：
#   - V2Ray 5.53.0：从官方下载固定版本，核对指纹后才用。
#   - Nginx、certbot、qrencode：Debian 自带的软件包，跟着系统自动更新。
#   - 证书由 certbot 自带的定时任务自动续期，续期后自动重载 Nginx。
# 重复运行 install 时，UUID 和路径保持不变，客户端不用重新配置。
set -euo pipefail
umask 022

APP=/opt/pure-proxy
ETC=/etc/pure-proxy
WEBROOT=/var/www/pure-proxy
NODE_FILE=/root/pure-proxy-node.txt
SERVICE=pure-proxy.service
USER_NAME=pure-proxy
LISTEN_PORT=10000
V2RAY_URL=https://github.com/v2fly/v2ray-core/releases/download/v5.53.0/v2ray-linux-64.zip
V2RAY_SHA=6bbb8aee65a57d0b12599b4b7c842b3ad0daca4436e661d94015c447cb31b4fa

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
die() { printf '停止：%s\n' "$*" >&2; exit 1; }

# Retry only apt/dpkg lock contention (fresh cloud images often run apt in the background at first boot).
apt_wait() {
    local log status started=$SECONDS
    log=$(mktemp)
    while true; do
        if LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get \
            -o DPkg::Lock::Timeout=0 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold -o APT::Update::Error-Mode=any "$@" >"$log" 2>&1; then
            rm -f -- "$log"; return 0
        else
            status=$?
        fi
        if ! grep -Eq '^E: (Could not get lock |Unable to acquire .*lock|Unable to lock directory )' "$log"; then
            cat "$log" >&2; rm -f -- "$log"; return "$status"
        fi
        if (( SECONDS - started >= 600 )); then
            cat "$log" >&2; rm -f -- "$log"; die '等待软件安装锁超过 10 分钟。稍后再运行一次。'
        fi
        say '系统后台正在安装软件，自动等待 5 秒后继续（最多 10 分钟）。'
        sleep 5
    done
}

setting() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$ETC/settings.json" "$1"; }

node_link() {
    python3 - "$ETC/settings.json" <<'EOF'
import base64, json, sys
s = json.load(open(sys.argv[1]))
node = {'v': '2', 'ps': s['domain'] + '-纯代理', 'add': s['domain'], 'port': '443', 'id': s['uuid'], 'aid': '0',
        'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': s['domain'], 'path': s['path'], 'tls': 'tls', 'sni': s['domain']}
print('vmess://' + base64.b64encode(json.dumps(node, ensure_ascii=False, separators=(',', ':')).encode()).decode())
EOF
}

write_node_file() {
    local link domain uuid path
    link=$(node_link); domain=$(setting domain); uuid=$(setting uuid); path=$(setting path)
    (umask 077; cat >"$NODE_FILE" <<EOF
纯代理节点（等同于密码，不要发给别人）
节点链接：
$link

手动填写时：地址 $domain，端口 443，UUID $uuid，alterId 0，加密 auto，
传输 websocket，路径 $path，Host $domain，TLS 打开，SNI $domain，不允许不安全。

Clash 节点（粘贴到配置的 proxies: 下面，并把名字加进 PROXY 分组）：
  - name: $domain-纯代理
    type: vmess
    server: $domain
    port: 443
    uuid: $uuid
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: $domain
    skip-cert-verify: false
    network: ws
    ws-opts:
      path: $path
      headers:
        Host: $domain
EOF
)
}

show_node() {
    # Secrets go only to a real terminal, never into logs or a captured output.
    if [[ -t 1 ]]; then
        say '下面是节点信息，等同于密码：只在自己屏幕上看，看完关掉窗口。'
        cat "$NODE_FILE"
        say ''
        say '二维码（用 Shadowrocket 首页左上角的扫码图标扫）：'
        node_link | qrencode -t ANSIUTF8
    else
        say "节点信息已保存到 $NODE_FILE（只有 root 能读）。在终端里运行 bash pure-proxy.sh node 可以直接显示。"
    fi
}

# Full self-test: a throwaway local client connects to https://域名 like a real client, then fetches a trace page.
self_test() {
    local d port ip trace code domain path
    domain=$(setting domain); path=$(setting path)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$domain/" || true)
    [[ $code == 404 ]] && say "  网页入口：正常（https://$domain/ 返回 404，证书有效）" || { say "  网页入口：不正常（返回 ${code:-无响应}）"; return 1; }
    d=$(mktemp -d); port=$(( 20000 + RANDOM % 10000 ))
    python3 - "$ETC/settings.json" "$d/client.json" "$port" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
cfg = {'log': {'loglevel': 'none'},
       'inbounds': [{'listen': '127.0.0.1', 'port': int(sys.argv[3]), 'protocol': 'socks', 'settings': {'udp': False}}],
       'outbounds': [{'protocol': 'vmess', 'settings': {'vnext': [{'address': s['domain'], 'port': 443,
                      'users': [{'id': s['uuid'], 'alterId': 0, 'security': 'auto'}]}]},
                      'streamSettings': {'network': 'ws', 'security': 'tls',
                                         'tlsSettings': {'serverName': s['domain'], 'allowInsecure': False},
                                         'wsSettings': {'path': s['path'], 'headers': {'Host': s['domain']}}}}]}
open(sys.argv[2], 'w').write(json.dumps(cfg))
EOF
    "$APP/bin/v2ray" run -config "$d/client.json" >/dev/null 2>&1 &
    local pid=$!
    sleep 2
    trace=$(curl -s --max-time 20 --socks5-hostname "127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace || true)
    kill "$pid" 2>/dev/null || true; rm -rf "$d"
    ip=$(sed -n 's/^ip=//p' <<<"$trace")
    if [[ -n $ip ]]; then
        say "  完整链路：正常，经代理访问网站时看到的出口是 $ip（$(sed -n 's/^loc=//p' <<<"$trace")，warp=$(sed -n 's/^warp=//p' <<<"$trace")）"
    else
        say '  完整链路：不正常，经代理打不开网站'; return 1
    fi
}

do_install() {
    local domain='' email=''
    while (( $# )); do
        case $1 in
            --domain) domain=${2:-}; shift ;;
            --email) email=${2:-}; shift ;;
            *) die "不认识的参数 $1" ;;
        esac
        shift
    done

    step '1/7 检查这台服务器'
    [[ $EUID == 0 ]] || die '要用 root 运行。'
    . /etc/os-release
    [[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || die "只支持 Debian 13，这台是 ${PRETTY_NAME:-未知系统}。"
    [[ $(dpkg --print-architecture) == amd64 ]] || die '只支持 x86_64（amd64）的服务器。'
    [[ -d /run/systemd/system ]] || die '需要 systemd。'
    if [[ -d /opt/senyz-proxy-simple || -d /etc/senyz-proxy-simple ]]; then
        die '这台服务器装着 WARP 方案。纯代理只能装在全新的服务器上，请先在服务商面板里重装系统。'
    fi
    if [[ -f $ETC/settings.json ]]; then
        domain=${domain:-$(setting domain)}; email=${email:-$(setting email)}
        say "接着上次的安装，域名 $domain。"
    fi
    if [[ -z $domain ]]; then
        [[ -t 0 ]] || die '没有写域名。用法：bash pure-proxy.sh install --domain 你的域名'
        while [[ -z $domain ]]; do read -rp '代理域名（例如 proxy.example.com）：' domain; done
    fi
    [[ $domain =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "域名格式不对：$domain"
    if [[ -z $email && ! -f $ETC/settings.json && -t 0 ]]; then
        read -rp '证书联系邮箱（可以直接回车跳过）：' email
    fi
    apt_wait update
    apt_wait install -y ca-certificates curl python3 unzip nginx certbot qrencode
    local myip dnsip
    myip=$(curl -4 -s --max-time 15 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')
    [[ -n $myip ]] || die '查不到这台服务器的公网 IPv4，可能网络还没通。'
    dnsip=$(getent ahostsv4 "$domain" | awk 'NR==1{print $1}')
    say "这台服务器的公网 IP：$myip；域名 $domain 解析到：${dnsip:-（查不到）}"
    [[ $dnsip == "$myip" ]] || die "域名还没有指向这台服务器。在 Cloudflare 里给 $domain 加一条 A 记录，填 $myip，关掉橙色云朵（DNS only），等一两分钟再运行。"
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != yes ]]; then
        say '提醒：这台服务器的时间还没有和网络同步。VMess 要求两边时间相差不超过 2 分钟，装好后如果连不上，先查时间。'
    fi
    if ss -Hltnp '( sport = :80 or sport = :443 )' | grep -v nginx | grep -q .; then
        die '80 或 443 端口被别的程序占用了，这不是一台干净的服务器。'
    fi

    step '2/7 下载 V2Ray 5.53.0（核对指纹）'
    mkdir -p "$APP/bin"
    if [[ -x $APP/bin/v2ray ]] && "$APP/bin/v2ray" version 2>/dev/null | grep -q '^V2Ray 5.53.0'; then
        say '已经装好，跳过。'
    else
        local tmp; tmp=$(mktemp -d)
        curl --proto '=https' --tlsv1.2 -fsSL --max-time 180 -o "$tmp/v2ray.zip" "$V2RAY_URL"
        printf '%s  %s\n' "$V2RAY_SHA" "$tmp/v2ray.zip" | sha256sum -c --quiet - || { rm -rf "$tmp"; die 'V2Ray 下载文件的指纹不对，没有使用它。'; }
        unzip -q -o "$tmp/v2ray.zip" v2ray -d "$tmp"
        install -m 755 "$tmp/v2ray" "$APP/bin/v2ray"
        rm -rf "$tmp"
        say "已安装：$("$APP/bin/v2ray" version | head -1)"
    fi

    step '3/7 生成配置（重复运行时保持原来的 UUID 和路径）'
    mkdir -p "$ETC"; chmod 755 "$ETC"
    id -u "$USER_NAME" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
    python3 - "$ETC/settings.json" "$domain" "$email" <<'EOF'
import json, os, secrets, sys, uuid
path, domain, email = sys.argv[1:4]
s = json.load(open(path)) if os.path.exists(path) else {}
s.setdefault('uuid', str(uuid.uuid4()))
s.setdefault('path', '/' + secrets.token_hex(8))
s['domain'], s['email'] = domain, email
fd = os.open(path + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(s, f, indent=2)
os.replace(path + '.tmp', path)
EOF
    python3 - "$ETC/settings.json" "$ETC/v2ray.json" "$LISTEN_PORT" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
private = ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
           '192.168.0.0/16', '224.0.0.0/4', '::1/128', 'fc00::/7', 'fe80::/10']
cfg = {
    'log': {'loglevel': 'warning'},
    'inbounds': [{'listen': '127.0.0.1', 'port': int(sys.argv[3]), 'protocol': 'vmess',
                  'settings': {'clients': [{'id': s['uuid'], 'alterId': 0}]},
                  'streamSettings': {'network': 'ws', 'wsSettings': {'path': s['path']}}}],
    # Direct exit over IPv4 only. Private and local addresses are refused, so a client cannot reach the server's own
    # services or the cloud metadata address through the proxy.
    'outbounds': [{'tag': 'direct', 'protocol': 'freedom', 'settings': {'domainStrategy': 'UseIPv4'}},
                  {'tag': 'block', 'protocol': 'blackhole'}],
    'routing': {'domainStrategy': 'IPIfNonMatch',
                'rules': [{'type': 'field', 'ip': private, 'outboundTag': 'block'}]},
}
open(sys.argv[2], 'w').write(json.dumps(cfg, indent=2))
EOF
    chown root:"$USER_NAME" "$ETC/v2ray.json"; chmod 640 "$ETC/v2ray.json"
    "$APP/bin/v2ray" test -format json -config "$ETC/v2ray.json" >/dev/null || die 'V2Ray 配置检查没通过。'
    cat >/etc/systemd/system/$SERVICE <<EOF
[Unit]
Description=Pure proxy (V2Ray behind Nginx, no WARP)
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$USER_NAME
ExecStart=$APP/bin/v2ray run -config $ETC/v2ray.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    step '4/7 网页入口和证书'
    local path; path=$(setting path)
    mkdir -p "$WEBROOT"
    rm -f /etc/nginx/sites-enabled/default
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
        say '服务器自带的 UFW 防火墙开着，已放行 80 和 443（SSH 原来的规则不动）。'
    fi
    cat >/etc/nginx/conf.d/pure-proxy-http.conf <<EOF
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 301 https://$domain\$request_uri; }
}
EOF
    nginx -t -q && systemctl enable --now nginx >/dev/null 2>&1 && systemctl reload nginx
    local cert=/etc/letsencrypt/live/$domain/fullchain.pem
    if [[ -f $cert ]]; then
        say '证书已经有了，跳过申请（certbot 会自动续期）。'
    else
        local mail=(--register-unsafely-without-email)
        [[ -n $email ]] && mail=(--email "$email")
        certbot certonly --webroot -w "$WEBROOT" -d "$domain" --agree-tos --non-interactive "${mail[@]}" \
            --key-type ecdsa --deploy-hook 'systemctl reload nginx' \
            || die '证书没申请下来。常见原因：域名开了橙色云朵、服务商面板防火墙没放行 80 端口、域名刚改还没生效。修好后再运行一次。'
    fi
    cat >/etc/nginx/conf.d/pure-proxy-https.conf <<EOF
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:pureproxy:10m;
    location = $path {
        if (\$http_upgrade !~* "^websocket\$") { return 404; }
        proxy_pass http://127.0.0.1:$LISTEN_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
    location / { return 404; }
}
EOF
    nginx -t -q || die 'Nginx 配置检查没通过。'
    systemctl reload nginx

    step '5/7 启动代理'
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE"
    sleep 2
    systemctl is-active --quiet "$SERVICE" || die "代理没有启动，查看原因：journalctl -u $SERVICE -n 30"
    # BBR helps long-distance links; it only changes how TCP paces sending.
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >/etc/sysctl.d/90-pure-proxy.conf
    sysctl -q --system >/dev/null 2>&1 || true
    say "已启动。TCP 拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"

    step '6/7 自测（像真实客户端一样连一次）'
    self_test || die '自测没通过，看上面哪一项不正常。'

    step '7/7 节点信息'
    write_node_file
    show_node
    say ''
    say '完成。客户端填法和平时一样，见手册。以后查看状态：bash pure-proxy.sh status'
}

status() {
    [[ $EUID == 0 ]] || die '要用 root 运行。'
    [[ -f $ETC/settings.json ]] || die '这台服务器还没装纯代理。'
    local domain; domain=$(setting domain)
    say "域名：$domain"
    say "代理服务：$(systemctl is-active $SERVICE)；Nginx：$(systemctl is-active nginx)；证书自动续期定时器：$(systemctl is-active certbot.timer)"
    say "证书到期：$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/$domain/fullchain.pem 2>/dev/null | cut -d= -f2)"
    say "需要系统重启：$([[ -f /run/reboot-required ]] && echo 是 || echo 否)"
    say '自测：'
    self_test || true
}

uninstall() {
    [[ $EUID == 0 ]] || die '要用 root 运行。'
    local domain=''
    [[ -f $ETC/settings.json ]] && domain=$(setting domain)
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/$SERVICE /etc/nginx/conf.d/pure-proxy-http.conf /etc/nginx/conf.d/pure-proxy-https.conf \
          /etc/sysctl.d/90-pure-proxy.conf "$NODE_FILE"
    systemctl daemon-reload
    [[ -n $domain ]] && certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
    rm -rf "$APP" "$ETC" "$WEBROOT"
    id -u "$USER_NAME" >/dev/null 2>&1 && userdel "$USER_NAME" || true
    [[ -e /etc/nginx/sites-available/default ]] && ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    nginx -t -q 2>/dev/null && systemctl reload nginx || true
    say '已卸载纯代理。Nginx、certbot 等系统软件包保留着，不影响别的东西。'
}

case ${1:-install} in
    install) shift || true; do_install "$@" ;;
    status) status ;;
    node) [[ -f $NODE_FILE ]] || die '还没有节点信息，先运行 install。'; show_node ;;
    uninstall) uninstall ;;
    *) die "不认识的命令：$1（可用：install、status、node、uninstall）" ;;
esac
