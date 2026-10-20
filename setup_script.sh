#!/usr/bin/env bash
# senyz-proxy-simple 4.0.0-alpha6-dev. Supervised VPS validation candidate.
# The Bash entry embeds its Python standard-library runtime; no pip is used.
set -euo pipefail
set +x
umask 077
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
# BEGIN APT WAIT
# Retry only lock contention. Never delete locks or interrupt their owner.
apt_wait() {
    local log status started=$SECONDS
    log=$(mktemp)
    while true; do
        if LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get \
            -o DPkg::Lock::Timeout=0 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold -o APT::Update::Error-Mode=any "$@" >"$log" 2>&1; then
            cat "$log"; rm -f -- "$log"; return 0
        else
            status=$?
        fi
        if ! grep -Eq '^E: (Could not get lock |Unable to acquire .*lock|Unable to lock directory )' "$log"; then
            cat "$log" >&2; rm -f -- "$log"; return "$status"
        fi
        if (( SECONDS - started >= 600 )); then
            cat "$log" >&2; rm -f -- "$log"
            printf '%s\n' '停止：等待软件安装锁超过 10 分钟。后台任务仍在运行；不要删除锁、杀进程或重装。稍后重跑同一脚本。' >&2
            return "$status"
        fi
        printf '%s\n' '系统后台正在使用 apt/dpkg，自动等待 5 秒后继续（最多 10 分钟）；无需另开窗口运行 apt。'
        sleep 5
    done
}
# END APT WAIT

if [[ "${1:-}" == internal-apt ]]; then
    [[ $EUID == 0 ]] || exit 2
    shift
    apt_wait "$@"
    exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    if [[ "${1:-install}" != install && "${1:-install}" != trial-install ]]; then
        printf '%s\n' '只读检查：缺少 python3；没有安装或修改任何内容。'
        exit 2
    fi
    [[ $EUID == 0 && -r /etc/debian_version && -d /run/systemd/system ]] || exit 2
    [[ "$(cut -d. -f1 /etc/debian_version)" == 13 ]] || exit 2
    for path in /etc/nginx /etc/caddy /etc/v2ray /usr/local/etc/v2ray /etc/warp /var/lib/senyz-warp-one /etc/senyz-warp-one /opt/senyz-warp-one /var/lib/cloudflare-warp /var/lib/senyz-proxy-simple /etc/senyz-proxy-simple /opt/senyz-proxy-simple /var/lib/swo-caddy /usr/local/bin/wgcf /usr/local/bin/v2ray /etc/cloudflared /var/lib/docker; do
        [[ ! -e "$path" ]] || { printf '%s\n' '检测到已有部署，停止；请勿叠加安装。'; exit 2; }
    done
    if [[ -d /etc/wireguard ]] && [[ -n "$(find /etc/wireguard -mindepth 1 -print -quit)" ]]; then
        printf '%s\n' '检测到已有 WireGuard 配置，停止。'; exit 2
    fi
    [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]] || exit 2
    if command -v nft >/dev/null 2>&1 && [[ -n "$(nft list ruleset)" ]]; then
        printf '%s\n' '已有防火墙配置，停止；没有安装依赖。'; exit 2
    fi
    [[ -t 0 ]] || { printf '%s\n' '候选安装需要交互终端。'; exit 2; }
    printf '%s\n' '这是尚未实机验收的候选安装，会安装 Debian 基础依赖。'
    read -r -p '仅在获准的全新测试机上继续；输入 TRIAL：' reply
    [[ "$reply" == TRIAL ]] || exit 2
    apt_wait update
    apt_wait install -y python3 ca-certificates curl
fi
exec python3 - "$SELF" "$@" <<'SWO_PYTHON'
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import zipfile

VERSION = '4.0.0-alpha6-dev'
SELF = Path(sys.argv[1]).resolve()
BASE = Path('/var/lib/senyz-proxy-simple')
ETC = Path('/etc/senyz-proxy-simple')
OPT = Path('/opt/senyz-proxy-simple')
WEBROOT = Path('/var/www/senyz-acme')
ACME_PROD = BASE / 'acme-production'
ACME_STAGE = BASE / 'acme-staging'
STATE = BASE / 'state.json'
PENDING = BASE / 'pending.json'
PROOF = BASE / 'ssh-proof.json'
SCRIPT = OPT / 'setup_script.sh'
SYSTEMD = Path('/etc/systemd/system')
WAN_TABLE = '51881'
BUSINESS_TABLE = '51882'
# Reserved project priorities. WARP chooses an even earlier rule (80 before the
# former 81, 39 before 40). Do not try to win that race: official full exclusions
# are essential so its table falls through to our explicit per-UID routes.
RULE_PREFS = (40, 41, 42, 43)
WARP_IF = 'CloudflareWARP'
PROXY_USER = 'sps-proxy'
NGINX_USER = 'www-data'
PROXY_SERVICE = 'sps-proxy.service'
NGINX_SERVICE = 'sps-nginx.service'
DOWNLOADS = {
    'warp-key': ('https://pkg.cloudflareclient.com/pubkey.gpg', '0f37fc298c98e88ee3c0ee68c95b69f1dba9eb477abe3167e13982105911264d'),
    'warp.deb': ('https://pkg.cloudflareclient.com/pool/trixie/main/c/cloudflare-warp/cloudflare-warp_2026.7.1377.0_amd64.deb', '5afe38d0536b49bd09509264b68018e5440b28538323e1984d8096c512062658'),
    'v2ray.zip': ('https://github.com/v2fly/v2ray-core/releases/download/v5.53.0/v2ray-linux-64.zip', '6bbb8aee65a57d0b12599b4b7c842b3ad0daca4436e661d94015c447cb31b4fa'),
    'acme.sh': ('https://raw.githubusercontent.com/acmesh-official/acme.sh/807da6498377ee5e0cf43a78091f46f12dc59a89/acme.sh', 'c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7'),
}
ACTIVE_TRANSACTION = False
STEPS = {
    'guard': '准备管理路由与业务阻断',
    'service-start': '解除保护性屏蔽并提交 WARP 启动请求',
    'cli-ready': '等待 WARP 本地控制接口（约 45 秒内）',
    'disconnect': '确认注册前处于断开状态',
    'registration-check': '读取已有注册状态',
    'registration-new': '执行本轮唯一一次注册请求（命令上限 45 秒）',
    'registration-verify': '确认注册结果',
    'configure': '设置 WARP 模式与 MASQUE',
    'connect': '提交 WARP 连接请求（命令上限 12 秒）',
    'egress': '等待连接并验证双栈业务出口',
    'transaction-lock': '等待网络事务锁',
    'recovery': '安全停止',
    'recovery-proxy': '停止代理服务',
    'recovery-warp': '停止 WARP 服务',
    'recovery-network': '恢复原生管理网络',
}
EVENTS = {'start', 'done', 'failed', 'waiting', 'acquired', 'timeout'}


class Stop(Exception):
    pass


def say(message):
    try:
        print(message, flush=True)
    except OSError:
        # A closed SSH output must not skip the recovery path.
        pass


def record_step(step, event):
    # Fixed identifiers only: never commands, CLI output, journals or credentials.
    if step not in STEPS or event not in EVENTS or not STATE.is_file():
        return
    row = {'at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
           'pid': os.getpid(), 'step': step, 'event': event}
    try:
        fd = os.open(BASE / 'steps.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND
                     | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0), 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(row, separators=(',', ':')) + '\n')
    except OSError:
        # Logging failure must not prevent fail-closed recovery.
        pass


@contextlib.contextmanager
def step(name):
    record_step(name, 'start')
    say('WARP 步骤：' + STEPS[name])
    try:
        yield
    except BaseException:
        record_step(name, 'failed')
        raise
    record_step(name, 'done')
    say('已完成：' + STEPS[name])


def recent_steps():
    try:
        with open(BASE / 'steps.jsonl', 'rb') as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 16384))
            lines = stream.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
            stamp = row.get('at', '')
            if (row.get('step') in STEPS and row.get('event') in EVENTS
                    and isinstance(row.get('pid'), int) and isinstance(stamp, str)
                    and re.fullmatch(r'[0-9T:+.\-]{19,35}', stamp)):
                rows.append({key: row[key] for key in ('at', 'pid', 'step', 'event')})
        except (ValueError, TypeError, AttributeError):
            continue
    return rows[-40:]


def run(args, *, check=True, timeout=30, data=None, env=None):
    clean_env = {**os.environ, 'LC_ALL': 'C.UTF-8', 'LANG': 'C.UTF-8'}
    for key in ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        clean_env.pop(key, None)
    if env:
        clean_env.update(env)
    try:
        p = subprocess.run([str(a) for a in args], input=data, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=clean_env, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Stop('命令无法完成：' + str(args[0]) + '（' + type(exc).__name__ + '）') from None
    if check and p.returncode:
        if str(args[0]) == 'ip':
            # iproute2 diagnostics contain network addresses, never credentials.
            # Keep the useful parser/kernel reason while hiding literal addresses.
            detail = re.sub(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?:/[0-9]+)?', '<IPv4>', p.stderr)
            detail = re.sub(r'(?<![\w:])[0-9a-fA-F]*:[0-9a-fA-F:]+(?:%[\w.-]+)?(?:/[0-9]+)?', '<IPv6>', detail)
            detail = re.sub(r'[\x00-\x1f\x7f]', ' ', detail).strip()[:400]
            words = {'-4', '-6', '-j', 'address', 'route', 'rule', 'link', 'show', 'get',
                     'add', 'replace', 'del', 'flush'}
            operation = ' '.join(str(a) for a in args[1:] if str(a) in words)
            raise Stop(f'网络命令失败：ip {operation}；退出码 {p.returncode}；{detail or "未提供错误详情"}')
        # Do not echo command arguments, config content or raw service logs.
        raise Stop('检查/操作失败：' + str(args[0]) + '，退出码 ' + str(p.returncode))
    return p


def atomic(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise Stop('拒绝覆盖符号链接：' + path.name)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as f:
            f.write(content.encode('utf-8') if isinstance(content, str) else content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
        dirfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save(path, data):
    atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise Stop('缺少或损坏的本项目状态：' + Path(path).name) from None


def state_update(**changes):
    s = load(STATE)
    s.update(changes)
    save(STATE, s)
    return s


def require_root():
    if os.geteuid() != 0:
        raise Stop('此操作需要 root；未作修改。')


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def ssh_connection(value=None):
    parts = (os.environ.get('SSH_CONNECTION', '') if value is None else value).split()
    if len(parts) != 4:
        raise Stop('需要通过 SSH 登录后操作；不能跳过外部管理连接验证。')
    try:
        client, server = ipaddress.ip_address(parts[0]), ipaddress.ip_address(parts[2])
        ports = [int(parts[1]), int(parts[3])]
        if not all(1 <= p <= 65535 for p in ports):
            raise ValueError
    except ValueError:
        raise Stop('SSH 连接信息格式不正确。') from None
    return {'client': str(client), 'client_port': ports[0], 'server': str(server), 'server_port': ports[1]}


def connection_digest(conn):
    return hashlib.sha256(json.dumps(conn, sort_keys=True).encode()).hexdigest()


def ssh_session_start():
    """Use the connection's sshd ancestor, not the untrusted environment alone."""
    btime = re.search(r'^btime (\d+)$', Path('/proc/stat').read_text(), re.M)
    if not btime:
        raise Stop('无法核对 SSH 会话开始时间。')
    ticks = os.sysconf('SC_CLK_TCK')
    pid = os.getppid()
    for _ in range(24):
        if pid <= 1:
            break
        proc = Path('/proc') / str(pid)
        comm = (proc / 'comm').read_text().strip()
        raw = (proc / 'stat').read_text()
        fields = raw[raw.rfind(')') + 2:].split()
        if comm in ('sshd', 'sshd-session'):
            return int(btime.group(1)) + int(fields[19]) / ticks
        pid = int(fields[1])
    raise Stop('没有找到当前 SSH 连接的服务端会话；不接受伪造的环境变量确认。')


def prompt(label):
    try:
        # Buffered read/write mode (r+) requires seeking, which a Linux tty
        # cannot do. stdin contains the embedded program, not operator input.
        with open('/dev/tty', 'r', encoding='utf-8') as reader, \
                open('/dev/tty', 'w', encoding='utf-8') as writer:
            writer.write(label + '：')
            writer.flush()
            value = reader.readline()
            if not value:
                raise Stop('输入已取消。')
    except OSError as exc:
        raise Stop('无法读写控制终端 /dev/tty（' + type(exc).__name__ +
                   '）；请在带终端的 SSH 会话中运行，保留此错误供排查。') from None
    return value.strip()


def terminal_check():
    if prompt('只读终端检查，请输入 TERMINAL-OK') != 'TERMINAL-OK':
        raise Stop('终端检查已取消；没有安装或修改服务器。')
    say('PASS：终端交互正常；没有安装或修改服务器。')


def validate_inputs(domain, email):
    if len(domain) > 253 or '.' not in domain or not all(
        re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in domain.split('.')
    ):
        raise Stop('域名格式不正确；不带 https:// 或路径。')
    try:
        ipaddress.ip_address(domain)
    except ValueError:
        pass
    else:
        raise Stop('需要域名，不接受 IP 代替域名。')
    if len(email) > 254 or not re.fullmatch(r'[A-Za-z0-9._+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}', email):
        raise Stop('证书联系邮箱格式不正确。')





def server_config(client_uuid, ws_path):
    return {
        'log': {'loglevel': 'error', 'access': 'none'},
        # disableFallback=true skips the only server in V2Ray 5.53 when no domain
        # matcher exists. One explicit DoH server plus the UID firewall provides
        # the intended isolation; no localhost/system resolver is configured.
        'dns': {'servers': ['https+local://1.1.1.1/dns-query'], 'queryStrategy': 'UseIP'},
        'inbounds': [{'listen': '127.0.0.1', 'port': 10001, 'protocol': 'vmess',
                      'settings': {'clients': [{'id': client_uuid, 'alterId': 0}]},
                      'streamSettings': {'network': 'ws', 'wsSettings': {'path': ws_path}}}],
        'outbounds': [{'tag': 'warp-only', 'protocol': 'freedom', 'settings': {'domainStrategy': 'UseIP'}}],
    }


def firewall_text(uid, ssh_port):
    if not isinstance(uid, int) or uid <= 0 or not 1 <= ssh_port <= 65535:
        raise Stop('防火墙参数不正确。')
    return f'''table inet sps {{
 chain input {{
  type filter hook input priority 10; policy drop;
  iifname "lo" accept
  ct state established,related accept
  meta l4proto {{ icmp, ipv6-icmp }} accept
  udp sport 67 udp dport 68 accept
  udp sport 547 udp dport 546 accept
  tcp dport {{ {ssh_port}, 80, 443 }} accept
 }}
 chain output {{
  type filter hook output priority 10; policy accept;
  meta skuid {uid} jump proxy_only
 }}
 chain proxy_only {{
  oifname "lo" ip daddr 127.0.0.1 tcp sport 10001 ct direction reply ct state established accept
  ip daddr {{ 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 224.0.0.0/4 }} counter drop
  ip6 daddr {{ ::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8 }} counter drop
  oifname "{WARP_IF}" counter accept
  counter drop
 }}
}}
'''


def nginx_config(domain, ws_path, tls=True):
    http = f"""user www-data;
worker_processes auto;
pid /run/sps-nginx.pid;
error_log /var/log/nginx/sps-error.log warn;
events {{ worker_connections 1024; }}
http {{
 access_log off;
 server_tokens off;
 server {{
  listen 80;
  server_name {domain};
  location ^~ /.well-known/acme-challenge/ {{ root {WEBROOT}; default_type text/plain; }}
  location / {{ return 404; }}
 }}
"""
    if tls:
        http += f""" server {{
  listen 443 ssl;
  server_name {domain};
  ssl_certificate {ETC}/fullchain.pem;
  ssl_certificate_key {ETC}/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:SPS:1m;
  location = {ws_path} {{
   if ($http_upgrade != "websocket") {{ return 404; }}
   proxy_pass http://127.0.0.1:10001;
   proxy_http_version 1.1;
   proxy_set_header Upgrade $http_upgrade;
   proxy_set_header Connection "upgrade";
   proxy_set_header Host $host;
   proxy_read_timeout 3600s;
   proxy_send_timeout 3600s;
   proxy_buffering off;
  }}
  location / {{ return 404; }}
 }}
"""
    return http + '}\n'


def nft_apply():
    s = load(STATE)
    rules = firewall_text(s['proxy_uid'], s['ssh']['server_port'])
    exists = run(['nft', 'list', 'table', 'inet', 'sps'], check=False).returncode == 0
    batch = ('delete table inet sps\n' if exists else '') + rules
    # Check before replacing; delete+create is one nftables atomic transaction.
    run(['nft', '-c', '-f', '-'], data=batch)
    run(['nft', '-f', '-'], data=batch)


def nft_is_present():
    p = run(['nft', '-j', 'list', 'table', 'inet', 'sps'], check=False)
    if p.returncode:
        return False
    expected = firewall_text(load(STATE)['proxy_uid'], load(STATE)['ssh']['server_port'])
    # Presence is NOT acceptance: rules are reapplied/validated at boot and before start.
    return bool(expected) and all(x in p.stdout for x in ('proxy_only', 'skuid', WARP_IF))


def check_platform():
    if sys.platform != 'linux':
        raise Stop('仅支持全新 Debian 13 amd64；当前环境不适用。没有安装任何内容。')
    release = Path('/etc/os-release').read_text()
    info = dict(re.findall(r'^([A-Z_]+)=[\"\']?([^\n\"\']*)', release, re.M))
    if info.get('ID') != 'debian' or info.get('VERSION_ID') != '13':
        raise Stop('本候选只支持 Debian 13；未作修改。')
    if run(['dpkg', '--print-architecture']).stdout.strip() != 'amd64':
        raise Stop('本候选只验证 amd64 下载基线；未作修改。')
    if not Path('/run/systemd/system').exists():
        raise Stop('需要原生 systemd 虚拟机，不支持容器/WSL。')


def reviewed_ufw_rules(payload):
    """Recognize an isolated UFW/nft backend; never erase or replace its rules."""
    tables = set()
    for entry in payload.get('nftables', []):
        if 'metainfo' in entry:
            continue
        if len(entry) != 1:
            return False
        kind, item = next(iter(entry.items()))
        if kind not in ('table', 'chain', 'rule'):
            return False
        family = item.get('family')
        table = item.get('name') if kind == 'table' else item.get('table')
        if family not in ('ip', 'ip6') or table != 'filter':
            return False
        if kind == 'table':
            tables.add((family, table))
            continue
        chain = item.get('name') if kind == 'chain' else item.get('chain')
        prefix = 'ufw-' if family == 'ip' else 'ufw6-'
        if chain not in ('INPUT', 'OUTPUT', 'FORWARD') and not str(chain).startswith(prefix):
            return False
        if kind == 'rule' and chain in ('INPUT', 'OUTPUT', 'FORWARD'):
            for expr in item.get('expr', []):
                if set(expr) == {'counter'}:
                    continue
                if set(expr) != {'jump'} or not expr['jump'].get('target', '').startswith(prefix):
                    return False
    return tables == {('ip', 'filter'), ('ip6', 'filter')}


def firewall_environment():
    payload = {'nftables': []}
    if shutil.which('nft'):
        payload = json.loads(run(['nft', '-j', 'list', 'ruleset']).stdout)
    populated = any('metainfo' not in row for row in payload['nftables'])
    if populated:
        if not shutil.which('ufw') or not reviewed_ufw_rules(payload):
            raise Stop('已有无法识别的防火墙；停止，不清空或覆盖规则。')
        defaults = Path('/etc/default/ufw').read_text()
        for key, value in [('IPV6', 'yes'), ('MANAGE_BUILTINS', 'no'), ('DEFAULT_OUTPUT_POLICY', 'ACCEPT')]:
            if not re.search(r'^' + key + r'=[\"\']?' + value + r'[\"\']?\s*$', defaults, re.M):
                raise Stop('UFW 使用了未支持的自定义设置；保留原规则，停止。')
        for tool in ('iptables', 'ip6tables'):
            if not shutil.which(tool) or 'nf_tables' not in run([tool, '--version']).stdout:
                raise Stop('已有 UFW 不是 nft 后端；需单独审核。')
        if 'Status: active' not in run(['ufw', 'status']).stdout:
            raise Stop('发现 UFW 残留规则但服务未启用；需单独审核。')
        return 'ufw'
    for tool in ('iptables-save', 'ip6tables-save'):
        if shutil.which(tool):
            old = run([tool], check=False).stdout
            if re.search(r'^-A |^:\S+ (?:DROP|REJECT) ', old, re.M):
                raise Stop('已有独立 iptables 策略；停止，不覆盖未知防火墙。')
    return 'empty'


def clean_check():
    check_platform()
    conflicts = [p for p in ('/etc/nginx', '/etc/caddy', '/etc/v2ray', '/usr/local/etc/v2ray',
                             '/etc/warp', '/var/lib/senyz-warp-one', '/etc/senyz-warp-one', '/opt/senyz-warp-one', '/var/lib/cloudflare-warp', '/var/lib/swo-caddy', '/usr/local/bin/wgcf',
                             '/usr/local/bin/v2ray', '/etc/cloudflared', '/var/lib/docker',
                             str(BASE), str(ETC), str(OPT)) if Path(p).exists()]
    wg = Path('/etc/wireguard')
    if wg.exists() and any(wg.iterdir()):
        conflicts.append('/etc/wireguard')
    if conflicts:
        raise Stop('检测到已有代理、WARP 或本候选状态；停止，不能叠加旧方案。已有本候选请用 status/resume。')
    if Path('/etc/resolv.conf').is_symlink() or not Path('/etc/resolv.conf').is_file():
        raise Stop('此候选暂只支持普通文件形式的 resolv.conf；需另行审核 DNS 管理器。')
    firewall_environment()
    if any(Path('/etc/systemd/system').glob('sps-*')):
        raise Stop('检测到本项目残留服务，请先诊断；不自动清空。')
    if Path('/etc/apt/sources.list.d/sps-cloudflare.list').exists():
        raise Stop('检测到候选软件源残留，请先诊断。')
    conn = ssh_connection()
    if ipaddress.ip_address(conn['server']).version != 4 or not ipaddress.ip_address(conn['server']).is_global:
        raise Stop('此候选要求通过服务器原生公网 IPv4 SSH 登录，不支持 NAT/IPv6 管理入口。')
    for family in ('-4', '-6'):
        rules = json.loads(run(['ip', family, '-j', 'rule', 'show']).stdout)
        if any(x.get('priority') in RULE_PREFS for x in rules):
            raise Stop('本项目策略路由优先级已被占用。')
        for table in (WAN_TABLE, BUSINESS_TABLE):
            p = run(['ip', family, '-j', 'route', 'show', 'table', table], check=False)
            if p.returncode == 0 and json.loads(p.stdout or '[]'):
                raise Stop('本项目路由表号已被占用。')
    listening = run(['ss', '-H', '-lnt']).stdout
    if re.search(r':(?:80|443|10001|18443)\s', listening):
        raise Stop('部署所需端口已占用，停止。')
    if run(['timedatectl', 'show', '-p', 'NTPSynchronized', '--value']).stdout.strip() != 'yes':
        raise Stop('系统尚未完成时间同步；待同步后重新检查，不继续安装。')
    native_route_plan()  # Reject unsupported route forms before installing anything.
    return conn


def initial_network(conn):
    v4 = json.loads(run(['ip', '-4', '-j', 'route', 'show', 'default', 'table', 'main']).stdout)
    if len(v4) != 1 or 'gateway' not in v4[0] or not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}', v4[0].get('dev', '')):
        raise Stop('只支持一条清楚的原生 IPv4 默认路由；没有修改网络。')
    dev = v4[0]['dev']
    addresses = json.loads(run(['ip', '-j', 'address', 'show', 'dev', dev]).stdout)
    if not any(a.get('local') == conn['server'] for row in addresses for a in row.get('addr_info', [])):
        raise Stop('SSH 服务器地址不是网卡原生地址，停止。')
    main = {}
    for family in ('-4', '-6'):
        p = run(['ip', family, 'route', 'show', 'table', 'main'])
        main[family] = [line for line in p.stdout.splitlines() if line.strip()]
    # Text is a diagnostic snapshot only; route installation uses structured JSON.
    return {'dev': dev, 'main': main, 'resolv': Path('/etc/resolv.conf').read_text()}


def verify_dns(domain, server):
    try:
        addresses = set()
        for item in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM):
            address = ipaddress.ip_address(item[4][0])
            if address.version == 6 and address.ipv4_mapped:
                address = address.ipv4_mapped
            addresses.add(str(address))
    except OSError:
        raise Stop('域名尚不能解析；未修改 DNS。') from None
    # Keep the first supported profile simple and deterministic. VPS egress is still dual-stack.
    if addresses != {server}:
        raise Stop('域名必须只解析到这台 VPS 的一个 A 记录，不能有橙云、其他 A 或 AAAA；脚本不修改 DNS。')


def download(name):
    url, expected = DOWNLOADS[name]
    dest = BASE / 'downloads' / name
    if dest.is_file() and hashlib.sha256(dest.read_bytes()).hexdigest() == expected:
        return dest
    if not shutil.which('curl'):
        raise Stop('缺少 curl，请使用当前说明中的完整下载入口准备基础依赖。')
    labels = {5: '代理名称解析失败', 6: 'DNS 解析失败', 7: 'TCP 连接失败',
              18: '下载不完整', 23: '本地文件写入失败', 28: '连接或下载超时',
              35: 'TLS 握手失败', 47: '重定向过多', 56: '连接接收失败',
              60: 'TLS 证书校验失败（检查系统时间、CA 和网络）', 63: '文件超过大小限制'}
    # Only public GETs are retried; registration and ACME have separate policies.
    with tempfile.TemporaryDirectory(prefix='sps-download-') as scratch:
        part = Path(scratch) / name
        ipv4 = False
        for attempt in range(1, 4):
            args = ['curl', '--noproxy', '*', '--proto', '=https', '--proto-redir', '=https',
                    '--tlsv1.2', '--location', '--max-redirs', '5', '--fail', '--silent', '--show-error',
                    '--connect-timeout', '15', '--max-time', '180', '--max-filesize', str(180 * 1024 * 1024),
                    '--output', part, '--write-out', '%{http_code}']
            if ipv4:
                args.append('-4')
            result = run([*args, url], check=False, timeout=195)
            status = result.stdout.strip()
            if result.returncode == 0:
                data = part.read_bytes()
                if len(data) > 180 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
                    raise Stop('官方资源摘要不匹配：' + name + '；停止，不执行下载内容。')
                atomic(dest, data)
                return dest
            reason = labels.get(result.returncode, 'curl 错误')
            if result.returncode == 22 and re.fullmatch(r'[1-5][0-9]{2}', status):
                reason = 'HTTP ' + status
            details = f'{name}：{reason}；curl={result.returncode}；尝试 {attempt}/3'
            retryable = result.returncode in (6, 7, 18, 28, 56) or (
                result.returncode == 22 and status in ('408', '500', '502', '503', '504'))
            # Fail immediately on TLS, 403/404/429, redirects or checksum problems.
            if not retryable or attempt == 3:
                raise Stop('官方资源下载失败：' + details + '。未跳过校验；不需要因此重装。')
            ipv4 = result.returncode in (6, 7, 18, 28, 56)
            say('下载暂未成功，5 秒后重试公开文件：' + details + ('；下一次使用 IPv4' if ipv4 else ''))
            time.sleep(5)


def apt_run(*args):
    # Stream progress and lock-wait notices; arguments are never shell-interpolated.
    env = os.environ.copy()
    for key in ('http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        env.pop(key, None)
    p = subprocess.run(['bash', str(SELF), 'internal-apt', *map(str, args)], check=False, env=env)
    if p.returncode:
        raise Stop('系统软件准备未完成，apt 退出码 ' + str(p.returncode) + '；见上方原因，不需要因此重装。')


def create_user(name, home):
    p = run(['id', '-u', name], check=False)
    if p.returncode == 0:
        raise Stop('专用服务用户名已存在；停止，避免借用未知身份。')
    run(['useradd', '--system', '--user-group', '--home-dir', home, '--no-create-home', '--shell', '/usr/sbin/nologin', name])
    return int(run(['id', '-u', name]).stdout.strip())


@contextlib.contextmanager
def lock(name='operation.lock', nonblocking=True, timeout=30):
    if not STATE.is_file():
        raise Stop('本项目尚未初始化；没有创建目录或锁文件。')
    with open(BASE / name, 'a') as f:
        os.chmod(f.name, 0o600)
        deadline = time.monotonic() + timeout
        waiting = False
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if nonblocking:
                    raise Stop('另一个操作仍在运行；没有并行更改配置。') from None
                if not waiting:
                    record_step('transaction-lock', 'waiting')
                    waiting = True
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    record_step('transaction-lock', 'timeout')
                    raise Stop('网络事务锁等待超时；未删除锁或并行修改。保留状态等待诊断。') from None
                time.sleep(min(0.2, remaining))
        if waiting:
            record_step('transaction-lock', 'acquired')
        yield


def ensure_user(name, home, kind):
    marker = 'senyz-proxy-simple-' + kind
    p = run(['getent', 'passwd', name], check=False)
    if p.returncode == 0:
        fields = p.stdout.strip().split(':')
        if len(fields) != 7 or fields[4] != marker or fields[5] != home or fields[6] != '/usr/sbin/nologin':
            raise Stop('已有同名服务身份不属于本项目；停止。')
        return int(fields[2])
    run(['useradd', '--system', '--user-group', '--comment', marker, '--home-dir', home,
         '--no-create-home', '--shell', '/usr/sbin/nologin', name])
    return int(run(['id', '-u', name]).stdout.strip())


def own_config(path, content, group):
    atomic(path, content, 0o640)
    run(['chown', 'root:' + group, path])


def service_binary_directory():
    # The wrapper's umask is 077. mkdir(mode=0755) alone still produces 0700,
    # which prevents both unprivileged service users from executing their cores.
    for directory in (OPT, OPT / 'bin'):
        directory.mkdir(parents=True, exist_ok=True, mode=0o755)
        os.chmod(directory, 0o755)


def unit_write(name, text):
    atomic(SYSTEMD / name, text, 0o644)


def write_units():
    unit_write('sps-guard.service', f"""[Unit]
Description=Protect proxy egress before WARP or proxy startup
Wants=network-online.target
After=network-online.target ufw.service
Before=warp-svc.service {PROXY_SERVICE} {NGINX_SERVICE}
[Service]
Type=oneshot
ExecStart=/bin/bash {SCRIPT} internal-guard
TimeoutStartSec=60
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
""")
    unit_write(PROXY_SERVICE, f"""[Unit]
Description=VMess WebSocket with required WARP egress
Requires=sps-guard.service
After=sps-guard.service warp-svc.service
StartLimitIntervalSec=120
StartLimitBurst=3
[Service]
User={PROXY_USER}
Group={PROXY_USER}
ExecStartPre=+/bin/bash {SCRIPT} internal-proxy-gate
ExecStart={OPT}/bin/v2ray run -config {ETC}/v2ray.json
TimeoutStartSec=120
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
""")
    unit_write(NGINX_SERVICE, f"""[Unit]
Description=Nginx TLS and webroot certificate validation
Requires=sps-guard.service
After=sps-guard.service network-online.target
[Service]
Type=simple
ExecStartPre=/usr/sbin/nginx -t -c {ETC}/nginx.conf
ExecStart=/usr/sbin/nginx -c {ETC}/nginx.conf -g 'daemon off;'
ExecReload=/usr/sbin/nginx -c {ETC}/nginx.conf -s reload
KillSignal=SIGQUIT
TimeoutStopSec=30
Restart=on-failure
RestartSec=5s
UMask=0077
[Install]
WantedBy=multi-user.target
""")
    for name, command, timeout in [('deadline', 'internal-deadline', 120), ('health', 'internal-health', 90),
                                    ('renew', 'internal-renew', 900)]:
        unit_write(f'sps-{name}.service', f"""[Unit]
Description=Simple proxy {name}
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash {SCRIPT} {command}
TimeoutStartSec={timeout}
""")
    for name, schedule in [('deadline', 'OnBootSec=15s\nOnUnitActiveSec=15s\nAccuracySec=1s'),
                           ('health', 'OnBootSec=90s\nOnUnitActiveSec=60s\nAccuracySec=5s'),
                           ('renew', 'OnCalendar=*-*-* 04:00:00\nRandomizedDelaySec=1h\nPersistent=true')]:
        unit_write(f'sps-{name}.timer', f"""[Unit]
Description=Simple proxy {name} schedule
[Timer]
{schedule}
Unit=sps-{name}.service
[Install]
WantedBy=timers.target
""")
    unit_write('warp-svc.service.d/50-sps-guard.conf',
               '[Unit]\nRequires=sps-guard.service\nAfter=sps-guard.service\n'
               '[Service]\nTimeoutStartSec=45\nTimeoutStopSec=40\n')


def prepare():
    s = load(STATE)
    if s.get('prepared'):
        return
    say('准备官方 WARP、V2Ray、Nginx 和证书工具。')
    # Validate all public downloads before masking services or installing the stack.
    files = {name: download(name) for name in DOWNLOADS}
    policy = Path('/usr/sbin/policy-rc.d')
    owned_policy = '#!/bin/sh\n# senyz-proxy-simple installation guard\nexit 101\n'
    if policy.exists() and policy.read_text() != owned_policy:
        raise Stop('已有软件包启动策略，需要审核。')
    atomic(policy, owned_policy, 0o755)
    try:
        run(['systemctl', 'mask', 'warp-svc.service', 'nginx.service'])
        apt_run('update')
        apt_run('install', '-y', 'ca-certificates', 'curl', 'nftables', 'gnupg', 'nginx',
                'openssl', 'iproute2', 'qrencode', 'unattended-upgrades')
        run(['gpg', '--batch', '--yes', '--dearmor', '--output', '/usr/share/keyrings/sps-cloudflare.gpg', files['warp-key']])
        os.chmod('/usr/share/keyrings/sps-cloudflare.gpg', 0o644)
        atomic('/etc/apt/sources.list.d/sps-cloudflare.list',
               'deb [arch=amd64 signed-by=/usr/share/keyrings/sps-cloudflare.gpg] https://pkg.cloudflareclient.com/ trixie main\n', 0o644)
        apt_run('update')
        say('安装 WARP 包时会暂时阻止自启动；masked 和 policy-rc.d 101 是此阶段的预期提示。')
        apt_run('install', '-y', files['warp.deb'])
    finally:
        if policy.exists() and policy.read_text() == owned_policy:
            policy.unlink()
    run(['systemctl', 'stop', 'warp-svc.service', 'nginx.service'], check=False)
    if s.get('firewall') == 'ufw':
        # Preserve provider SSH restrictions and every existing UFW rule.
        for port in ('80/tcp', '443/tcp'):
            run(['ufw', 'allow', port])
    if run(['dpkg-query', '-W', '-f=${Version}', 'cloudflare-warp']).stdout.strip() != '2026.7.1377.0':
        raise Stop('WARP 安装版本不匹配。')
    proxy_uid = ensure_user(PROXY_USER, '/nonexistent', 'proxy')
    state_update(proxy_uid=proxy_uid)
    service_binary_directory()
    with zipfile.ZipFile(BASE / 'downloads/v2ray.zip') as archive:
        atomic(OPT / 'bin/v2ray', archive.read('v2ray'), 0o755)
    atomic(OPT / 'bin/acme.sh', files['acme.sh'].read_bytes(), 0o700)
    source = SELF.read_bytes()
    atomic(SCRIPT, source, 0o700)
    ETC.mkdir(exist_ok=True, mode=0o755)
    os.chmod(ETC, 0o755)
    private = load(ETC / 'private.json')
    own_config(ETC / 'v2ray.json', json.dumps(server_config(private['uuid'], private['path']), indent=2), PROXY_USER)
    atomic(ETC / 'nginx.conf', nginx_config(s['domain'], private['path'], tls=False))
    for directory in (WEBROOT, WEBROOT / '.well-known', WEBROOT / '.well-known/acme-challenge'):
        directory.mkdir(parents=True, exist_ok=True, mode=0o755)
        os.chmod(directory, 0o755)
    for directory in (ACME_STAGE, ACME_PROD):
        directory.mkdir(exist_ok=True, mode=0o700)
        os.chmod(directory, 0o700)
    run([OPT / 'bin/v2ray', 'test', '-config', ETC / 'v2ray.json'])
    run(['nginx', '-t', '-c', ETC / 'nginx.conf'])
    write_units()
    atomic('/etc/apt/apt.conf.d/52-sps-security', '''Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Package-Blacklist { "cloudflare-warp"; };
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
''', 0o644)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', 'sps-guard.service', 'sps-deadline.timer', 'sps-health.timer'])
    run(['systemctl', 'start', 'sps-deadline.timer'])
    state_update(prepared=True, stage='prepared', script_sha256=hashlib.sha256(source).hexdigest())


def clear_own_routes():
    for family in ('-4', '-6'):
        for pref in RULE_PREFS:
            for _ in range(32):
                if run(['ip', family, 'rule', 'del', 'pref', str(pref)], check=False).returncode:
                    break
            else:
                raise Stop('路由优先级记录异常；停止清理，需诊断。')
        for table in (WAN_TABLE, BUSINESS_TABLE):
            run(['ip', family, 'route', 'flush', 'table', table], check=False)


def native_route_plan():
    """Build native management copies from JSON, never replay display text.

    RA lifetime/expiry and linkdown/offload markers are status, not CLI tokens.
    The native main table remains untouched; the management copies deliberately
    have no RA expiry and are rebuilt at boot/start from current native routes.
    """
    plan = {}
    allowed = {'dst', 'dev', 'gateway', 'prefsrc', 'protocol', 'scope', 'metric',
               'pref', 'flags', 'type', 'table', 'expires', 'metrics'}
    for family in ('-4', '-6'):
        rows = json.loads(run(['ip', family, '-j', 'route', 'show', 'table', 'main']).stdout)
        commands = []
        for row in rows:
            if row.get('dev') == WARP_IF:
                continue
            if set(row) - allowed or row.get('type', 'unicast') not in (
                    'unicast', 'blackhole', 'unreachable', 'prohibit', 'throw'):
                raise Stop('原生路由包含未支持的多路径或扩展属性；未安装管理路由，需要审核。')
            flags = set(row.get('flags', []))
            if flags - {'onlink', 'linkdown', 'offload', 'trap', 'rt_offload', 'rt_trap', 'notify'}:
                raise Stop('原生路由包含未支持的标志；未安装管理路由，需要审核。')
            command = ['ip', family, 'route', 'replace', 'table', WAN_TABLE,
                       row.get('type', 'unicast'), row.get('dst', 'default')]
            for key, option in (('gateway', 'via'), ('dev', 'dev'), ('prefsrc', 'src'),
                                ('scope', 'scope'), ('metric', 'metric'), ('pref', 'pref')):
                if key in row:
                    command += [option, str(row[key])]
            # Copies are explicitly static; kernel/DHCP/RA own only the main table.
            command += ['proto', 'static']
            metrics = row.get('metrics', {})
            if isinstance(metrics, list) and len(metrics) == 1:
                metrics = metrics[0]
            if not isinstance(metrics, dict) or set(metrics) - {'mtu', 'advmss', 'hoplimit'}:
                raise Stop('原生路由包含未支持的指标；未安装管理路由，需要审核。')
            for key, value in metrics.items():
                if type(value) is not int or value < 0:
                    raise Stop('原生路由指标不是可支持的整数；未安装管理路由。')
                command += [key, str(value)]
            if 'onlink' in flags:
                command.append('onlink')
            commands.append((bool(row.get('gateway')), command))
        # Connected/host routes must precede routes that depend on a gateway.
        plan[family] = [command for _, command in sorted(commands, key=lambda item: item[0])]
    return plan


def management_routes():
    s = load(STATE)
    dev = s['network']['dev']
    addresses = json.loads(run(['ip', '-j', 'address', 'show', 'dev', dev]).stdout)
    original = s['ssh']['server']
    if not any(a.get('local') == original for row in addresses for a in row.get('addr_info', [])):
        raise Stop('原公网地址尚未就绪或已改变；拒绝重用旧管理路由。')
    plan = native_route_plan()
    clear_own_routes()
    for family in ('-4', '-6'):
        for command in plan[family]:
            run(command)
        run(['ip', family, 'rule', 'add', 'pref', str(RULE_PREFS[0]), 'uidrange', f"{s['proxy_uid']}-{s['proxy_uid']}", 'lookup', BUSINESS_TABLE])
        run(['ip', family, 'rule', 'add', 'pref', str(RULE_PREFS[1]), 'uidrange', '0-0', 'lookup', WAN_TABLE])
    run(['ip', '-4', 'rule', 'add', 'pref', str(RULE_PREFS[2]), 'from', original + '/32', 'lookup', WAN_TABLE])
    # Preserve native IPv6 replies where a native global address exists.
    native6 = [a['local'] for row in addresses for a in row.get('addr_info', [])
               if a.get('family') == 'inet6' and ipaddress.ip_address(a['local']).is_global]
    for address in native6:
        run(['ip', '-6', 'rule', 'add', 'pref', str(RULE_PREFS[2]), 'from', address + '/128', 'lookup', WAN_TABLE])


def business_routes():
    if run(['ip', 'link', 'show', 'dev', WARP_IF], check=False).returncode:
        raise Stop('官方 WARP 隧道网卡尚未出现。')
    for family in ('-4', '-6'):
        run(['ip', family, 'route', 'replace', 'table', BUSINESS_TABLE, 'default', 'dev', WARP_IF])


def restore_dns():
    network = load(STATE)['network']
    target = Path('/etc/resolv.conf')
    # Preflight admitted only a regular file. A WARP-created symlink is removed, not followed.
    if target.is_symlink():
        target.unlink()
    atomic(target, network['resolv'], 0o644)


def safe_stop(reason='user-request', boot=False):
    with lock('transaction.lock', nonblocking=False):
        return safe_stop_locked(reason, boot)


def safe_stop_locked(reason='user-request', boot=False):
    global ACTIVE_TRANSACTION
    require_root()
    record_step('recovery', 'start')
    s = load(STATE)
    errors = []
    state_update(stage='safe-stopped', ready=False, stopped_reason=reason, recovery_errors=['in-progress'])
    cancelled = load(PENDING) if PENDING.exists() else {
        'id': secrets.token_hex(16), 'boot_id': boot_id(), 'origin': '',
        'started': time.time(), 'deadline': time.time(), 'label': 'recovery'}
    cancelled['cancelled'] = True
    save(PENDING, cancelled)
    if not boot:
        record_step('recovery-proxy', 'start')
        for service in (PROXY_SERVICE, NGINX_SERVICE):
            run(['systemctl', 'stop', service], check=False, timeout=45)
        if run(['systemctl', 'is-active', PROXY_SERVICE], check=False).returncode == 0:
            run(['systemctl', 'kill', '--kill-whom=all', '--signal=SIGKILL', PROXY_SERVICE], check=False)
            if run(['systemctl', 'is-active', PROXY_SERVICE], check=False).returncode == 0:
                raise Stop('代理进程尚未确认停止；保留 WARP，不撤掉其出口。需要诊断。')
        record_step('recovery-proxy', 'done')
    if s.get('proxy_uid'):
        try:
            nft_apply()
        except Stop:
            errors.append('guard')
    if not boot:
        record_step('recovery-warp', 'start')
        run(['systemctl', 'stop', 'warp-svc.service'], check=False, timeout=45)
        run(['systemctl', 'mask', 'warp-svc.service'], check=False)
        if run(['systemctl', 'is-active', 'warp-svc.service'], check=False).returncode == 0:
            raise Stop('WARP 服务未确认停止；保留恢复标记，不能报告恢复完成。')
        record_step('recovery-warp', 'done')
    record_step('recovery-network', 'start')
    clear_own_routes()
    try:
        restore_dns()
    except (OSError, Stop):
        errors.append('dns')
    # Keep a cancellation marker so an old process cannot commit/restart after recovery.
    # A later explicit resume clears it, under the operation lock.
    PROOF.unlink(missing_ok=True)
    state_update(recovery_errors=errors)
    ACTIVE_TRANSACTION = False
    if errors:
        record_step('recovery', 'failed')
        raise Stop('代理已要求停止，但恢复检查未全部通过；请保留供应商救援入口并导出诊断。')
    record_step('recovery-network', 'done')
    record_step('recovery', 'done')
    if not boot:
        say('已进入安全停止：代理不交付，WARP 已停止；请用新的 SSH 登录确认管理可达。')


def transaction_begin(label, seconds=600):
    global ACTIVE_TRANSACTION
    with lock('transaction.lock', nonblocking=False):
        if PENDING.exists():
            raise Stop('存在未提交事务；先执行 rescue 或等待自动回退。')
        origin = ssh_connection()
        pending = {'id': secrets.token_hex(16), 'label': label, 'boot_id': boot_id(),
                   'origin': connection_digest(origin), 'started': time.time(), 'deadline': time.time() + seconds}
        PROOF.unlink(missing_ok=True)
        save(PENDING, pending)
        ACTIVE_TRANSACTION = True
        state_update(stage='connecting-warp', ready=False)
    run(['systemctl', 'start', 'sps-deadline.timer'])
    return pending


def valid_proof(pending, proof, current_boot=None, now=None):
    return (not pending.get('cancelled')
            and pending.get('boot_id') == (boot_id() if current_boot is None else current_boot)
            and (time.time() if now is None else now) < pending.get('deadline', 0)
            and proof.get('transaction') == pending.get('id')
            and proof.get('connection') != pending.get('origin')
            and proof.get('connection') is not None
            and pending.get('ssh_after') is not None
            and proof.get('ssh_started_at', 0) >= pending['ssh_after'] - 1.0
            and proof.get('boot_id') == pending.get('boot_id'))


def confirm_ssh():
    require_root()
    with lock('transaction.lock', nonblocking=False):
        pending = load(PENDING)
        conn = ssh_connection()
        proof = {'transaction': pending['id'], 'connection': connection_digest(conn), 'boot_id': boot_id(),
                 'at': time.time(), 'ssh_started_at': ssh_session_start()}
        if not valid_proof(pending, proof):
            raise Stop('这不是有效的新 SSH 连接，或确认已过期。请从本地重新登录，不要复用原终端。')
        save(PROOF, proof)
    say('新的 SSH 登录已确认。返回第一个终端，脚本会自动继续。')


def wait_ssh_proof():
    with lock('transaction.lock', nonblocking=False):
        assert_transaction()
        pending = load(PENDING)
        pending['ssh_after'] = time.time()
        save(PENDING, pending)
        PROOF.unlink(missing_ok=True)
    say('请保留这个终端，从你的电脑另开一次 SSH 登录，然后只执行：')
    say('  bash /opt/senyz-proxy-simple/setup_script.sh confirm-ssh')
    say('这是唯一一次额外登录确认；超时会进入安全停止。')
    while time.time() < pending['deadline'] - 45:
        if not PENDING.exists() or load(PENDING).get('id') != pending['id'] or load(PENDING).get('cancelled'):
            raise Stop('事务已被恢复或替换；不继续交付。')
        if PROOF.exists() and valid_proof(pending, load(PROOF)):
            return
        time.sleep(2)
    raise Stop('未收到有效的新 SSH 登录确认。')


def transaction_commit(stage, **changes):
    global ACTIVE_TRANSACTION
    with lock('transaction.lock', nonblocking=False):
        pending = load(PENDING)
        if not PROOF.exists() or not valid_proof(pending, load(PROOF)):
            raise Stop('缺少独立 SSH 证明，不能提交网络事务。')
        state_update(stage=stage, last_network_commit=time.time(), **changes)
        PENDING.unlink()
        PROOF.unlink(missing_ok=True)
        ACTIVE_TRANSACTION = False


def assert_transaction():
    pending = load(PENDING)
    if pending.get('cancelled') or pending.get('boot_id') != boot_id() or time.time() >= pending.get('deadline', 0):
        raise Stop('事务已取消或超时；不能继续启动服务。')


def reset_cancelled_transaction():
    with lock('transaction.lock', nonblocking=False):
        if PENDING.exists():
            if not load(PENDING).get('cancelled'):
                raise Stop('仍有未提交事务，先 rescue；不并行恢复。')
            if load(STATE).get('recovery_errors'):
                raise Stop('上次安全恢复尚未完成；不能清除保护标记。请先 rescue 或导出诊断。')
            PENDING.unlink()
            PROOF.unlink(missing_ok=True)


def resolve_trace_addresses():
    result = {}
    for family, name in ((socket.AF_INET, 'trace4'), (socket.AF_INET6, 'trace6')):
        try:
            addresses = socket.getaddrinfo('www.cloudflare.com', 443, family=family, type=socket.SOCK_STREAM)
        except OSError:
            raise Stop('无法取得双栈验收目标地址；不降低为单栈交付。') from None
        for address in addresses:
            value = ipaddress.ip_address(address[4][0])
            if value.is_global and not (value.version == 6 and value.ipv4_mapped):
                result[name] = str(value)
                break
        if name not in result:
            raise Stop('双栈验收目标地址不符合要求。')
    return result


def trace_ok(text):
    return bool(re.search(r'^warp=(?:on|plus)\s*$', text, re.M))


def trace_curl(family, *, socks=False, hostname=False, force_wan=False):
    s = load(STATE)
    address = s['trace' + str(family)]
    args = ['curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
            '--connect-timeout', '4', '--max-time', '12']
    if socks:
        # noproxy '*' would bypass SOCKS, so explicitly clear it for this test.
        args[2] = ''
        args += ['--socks5-hostname' if hostname else '--socks5', '127.0.0.1:18443']
    if not hostname:
        dest = '[' + address + ']' if family == 6 else address
        args += ['--resolve', 'www.cloudflare.com:443:' + dest]
        if not socks:
            args += ['-' + str(family)]
    if force_wan:
        # Bind a SOURCE address, not an interface (which could fail merely for lack of CAP_NET_RAW).
        source = s['ssh']['server'] if family == 4 else s.get('native6')
        if not source:
            return None
        args += ['--interface', source]
    args += ['https://www.cloudflare.com/cdn-cgi/trace']
    if not socks:
        args = ['runuser', '-u', PROXY_USER, '--', *args]
    return run(args, check=False, timeout=18)


def verify_warp_context():
    if not nft_is_present():
        raise Stop('业务出站保护规则缺失；不能继续。')
    for family in (4, 6):
        route = json.loads(run(['ip', '-' + str(family), '-j', 'route', 'get',
                               load(STATE)['trace' + str(family)], 'uid', str(load(STATE)['proxy_uid'])]).stdout)
        if not route or route[0].get('dev') != WARP_IF:
            raise Stop('业务路由未指向 WARP；不输出节点。')
        p = trace_curl(family)
        if p is None or p.returncode or not trace_ok(p.stdout):
            raise Stop('代理身份下的 IPv' + str(family) + ' WARP 实际出口未通过。')


def configure_native_split():
    # Let the official daemon allow native server ingress/management. Only our
    # dedicated business UID is explicitly routed into its tunnel; the nft UID
    # guard still drops every native fallback, even while WARP is disconnected.
    for prefix in ('0.0.0.0/0', '::/0'):
        run(['warp-cli', '--accept-tos', 'tunnel', 'ip', 'add-range', prefix], timeout=12)
    verify_native_split()


def verify_native_split():
    output = run(['warp-cli', '--accept-tos', 'tunnel', 'ip', 'list'], timeout=10).stdout
    if not output.startswith('Excluded routes:') or not all(
            re.search(r'^\s+' + re.escape(prefix) + r'(?:\s|$)', output, re.M)
            for prefix in ('0.0.0.0/0', '::/0')):
        raise Stop('官方 WARP 分流未允许原生管理入口；不启动业务。')


def verify_blocking_without_tunnel():
    # Run while the official service is stopped, before the first connection.
    # Successful HTTP, regardless of returned warp status, proves an unacceptable bypass.
    if run(['systemctl', 'is-active', 'warp-svc.service'], check=False).returncode == 0:
        raise Stop('阻断测试要求 WARP 尚未启动。')
    for family in (4, 6):
        p = trace_curl(family)
        if p is not None and p.returncode == 0:
            raise Stop('检测到 WARP 未运行时业务仍可出站，停止。')
    # Positive management control: the network must actually be usable while the protected UID fails.
    s = load(STATE)
    p = run(['curl', '--noproxy', '*', '-4', '-fsS', '--connect-timeout', '4', '--max-time', '12',
             '--resolve', 'www.cloudflare.com:443:' + s['trace4'], 'https://www.cloudflare.com/cdn-cgi/trace'],
            check=False, timeout=18)
    if p.returncode:
        raise Stop('管理网络对照测试失败，无法区分规则阻断与整体网络故障。')


def connect_warp():
    say('检查官方 WARP；注册最多调用一次，发现限流即停止。')
    with step('guard'):
        nft_apply()
        say('准备原生 SSH 管理路由；此步骤通过后才启动 WARP。')
        management_routes()
        verify_blocking_without_tunnel()
        assert_transaction()
        run(['systemctl', 'reset-failed', 'sps-guard.service', 'warp-svc.service'], check=False)
        run(['systemctl', 'start', 'sps-guard.service'])
    say('管理路由及业务阻断检查通过，开始启动官方 WARP。')
    started = int(time.time())
    with step('service-start'):
        with lock('transaction.lock', nonblocking=False):
            assert_transaction()
            run(['systemctl', 'unmask', 'warp-svc.service'])
            run(['systemctl', 'start', '--no-block', 'warp-svc.service'])
    with step('cli-ready'):
        deadline = time.monotonic() + 35
        while True:
            assert_transaction()
            p = run(['warp-cli', '--accept-tos', 'status'], check=False, timeout=8)
            if p.returncode == 0 or re.search(r'registration (?:missing|not found)|not registered', p.stdout + p.stderr, re.I):
                break
            if time.monotonic() >= deadline:
                raise Stop('WARP 服务未就绪；停止，不尝试注册。')
            say('仍在等待 WARP 本地控制接口；尚未开始注册。')
            time.sleep(2)
    with step('disconnect'):
        p = run(['warp-cli', '--accept-tos', 'disconnect'], check=False, timeout=8)
        if p.returncode and not re.search(r'registration (?:missing|not found)|not registered', p.stdout + p.stderr, re.I):
            raise Stop('不能确认 WARP 已断开；停止注册准备。')
    with step('registration-check'):
        registration = run(['warp-cli', '--accept-tos', 'registration', 'show'], check=False, timeout=10)
        missing = bool(re.search(r'missing|not registered|does not exist', registration.stdout + registration.stderr, re.I))
        if registration.returncode and not missing:
            raise Stop('注册状态查询失败；不把未知错误当作需要新注册。')
    if missing:
        if load(STATE).get('registration_attempted'):
            raise Stop('已尝试过注册，不能自动重复；需诊断后明确允许重试。')
        with step('registration-new'):
            state_update(registration_attempted=True)
            p = run(['warp-cli', '--accept-tos', 'registration', 'new'], check=False, timeout=45)
            journal = run(['journalctl', '-u', 'warp-svc.service', '--since', '@' + str(started),
                           '-n', '120', '--no-pager', '-o', 'cat'], check=False, timeout=8).stdout
            if re.search(r'\b429\b|Too Many Requests|rate.limit', p.stdout + p.stderr + journal, re.I):
                state_update(registration_blocked=True)
                raise Stop('WARP 注册限流；已停止本轮，不删除注册或循环重试。')
            if p.returncode:
                raise Stop('官方 WARP 注册未通过；保留状态等待诊断。')
    with step('registration-verify'):
        registration = run(['warp-cli', '--accept-tos', 'registration', 'show'], check=False, timeout=10)
        if registration.returncode or re.search(r'missing|not registered|does not exist', registration.stdout, re.I):
            raise Stop('未能确认 WARP 注册。')
    with step('configure'):
        configure_native_split()
        for args in (['mode', 'warp+doh'], ['tunnel', 'protocol', 'set', 'MASQUE']):
            run(['warp-cli', '--accept-tos', *args], timeout=12)
    with step('connect'):
        with lock('transaction.lock', nonblocking=False):
            assert_transaction()
            run(['warp-cli', '--accept-tos', 'connect'], timeout=12)
    with step('egress'):
        deadline = time.monotonic() + 90
        next_notice = 0.0
        while time.monotonic() < deadline:
            assert_transaction()
            status = run(['warp-cli', '--accept-tos', 'status'], check=False, timeout=8)
            if status.returncode == 0 and re.search(r'\bConnected\b', status.stdout):
                business_routes()
                verify_warp_context()
                state_update(registration_blocked=False, warp_verified_at=time.time())
                say('IPv4/IPv6 代理业务的 WARP 出口检查通过。')
                return
            if time.monotonic() >= next_notice:
                say('仍在等待 WARP 连接；尚未通过出口验收。')
                next_notice = time.monotonic() + 10
            time.sleep(3)
        raise Stop('WARP 连接未在限时内通过；停止。')


def tls_websocket(staging=False):
    s = load(STATE)
    private = load(ETC / 'private.json')
    context = ssl._create_unverified_context() if staging else ssl.create_default_context()
    # Staging bypass applies ONLY to this loopback handshake, with no VMess credentials.
    with socket.create_connection(('127.0.0.1', 443), timeout=4) as raw:
        with context.wrap_socket(raw, server_hostname=s['domain']) as conn:
            conn.settimeout(5)
            request = ('GET ' + private['path'] + ' HTTP/1.1\r\nHost: ' + s['domain'] +
                       '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                       'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
            conn.sendall(request.encode())
            result = b''
            while b'\r\n\r\n' not in result and len(result) < 8192:
                part = conn.recv(2048)
                if not part:
                    break
                result += part
            header = result.decode('latin1')
            return (header.startswith('HTTP/1.1 101 ') and
                    bool(re.search(r'^Sec-WebSocket-Accept:\s*s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=\s*$', header, re.M | re.I)))


def start_http():
    s = load(STATE)
    private = load(ETC / 'private.json')
    atomic(ETC / 'nginx.conf', nginx_config(s['domain'], private['path'], tls=False))
    run(['nginx', '-t', '-c', ETC / 'nginx.conf'])
    run(['systemctl', 'reset-failed', NGINX_SERVICE], check=False)
    with lock('transaction.lock', nonblocking=False):
        assert_transaction()
        run(['systemctl', 'start', NGINX_SERVICE])


def acme(home, args, timeout=240):
    # Direct invocation, not an unpinned self-install script or shell command string.
    return run(['/bin/bash', OPT / 'bin/acme.sh', '--home', home, '--config-home', home,
                '--cert-home', home, *args], check=False, timeout=timeout, env={'ACME_PACKAGED': '1'})


def issue_certificate(staging):
    s = load(STATE)
    home = ACME_STAGE if staging else ACME_PROD
    ca = 'https://acme-staging-v02.api.letsencrypt.org/directory' if staging else 'https://acme-v02.api.letsencrypt.org/directory'
    p = acme(home, ['--issue', '--server', ca, '-d', s['domain'], '--webroot', WEBROOT,
                    '--accountemail', s['email'], '--keylength', 'ec-256'])
    if p.returncode not in (0, 2):
        raise Stop(('测试 CA' if staging else '正式证书') + ' 签发失败；不重复强制签发。')
    args = ['--install-cert', '-d', s['domain'], '--ecc', '--key-file', ETC / 'key.pem',
            '--fullchain-file', ETC / 'fullchain.pem']
    if not staging:
        args += ['--reloadcmd', '/bin/bash ' + str(SCRIPT) + ' internal-cert-deploy']
    p = acme(home, args, timeout=60)
    if p.returncode:
        raise Stop('证书部署未通过。')
    for path in (ETC / 'key.pem', ETC / 'fullchain.pem'):
        os.chmod(path, 0o600)


def activate_tls(staging=False):
    s = load(STATE)
    private = load(ETC / 'private.json')
    atomic(ETC / 'nginx.conf', nginx_config(s['domain'], private['path']))
    run(['nginx', '-t', '-c', ETC / 'nginx.conf'])
    run(['systemctl', 'reload', NGINX_SERVICE])
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        assert_transaction()
        try:
            if tls_websocket(staging):
                return
        except (OSError, ssl.SSLError):
            pass
        time.sleep(1)
    raise Stop('TLS 与 WebSocket 握手未通过。')


def certificate_deploy():
    require_root()
    run(['nginx', '-t', '-c', ETC / 'nginx.conf'])
    run(['systemctl', 'reload', NGINX_SERVICE])


def certificate_expiry():
    p = run(['openssl', 'x509', '-in', ETC / 'fullchain.pem', '-noout', '-enddate'], check=False)
    if p.returncode or not p.stdout.startswith('notAfter='):
        raise Stop('无法检查证书到期时间。')
    return ssl.cert_time_to_seconds(p.stdout.strip().split('=', 1)[1])


def verify_served_certificate():
    s = load(STATE)
    pem = (ETC / 'fullchain.pem').read_text()
    first = pem[:pem.index('-----END CERTIFICATE-----') + len('-----END CERTIFICATE-----')]
    expected = ssl.PEM_cert_to_DER_cert(first)
    # Nginx reload is asynchronous; old workers may accept a connection briefly.
    for attempt in range(10):
        try:
            with socket.create_connection(('127.0.0.1', 443), timeout=3) as raw:
                with ssl.create_default_context().wrap_socket(raw, server_hostname=s['domain']) as tls:
                    if tls.getpeercert(binary_form=True) == expected:
                        return certificate_expiry()
        except (OSError, ssl.SSLError):
            pass
        if attempt < 9:
            time.sleep(1)
    raise Stop('Nginx 未通过新证书实际生效检查。')


def renew_certificate():
    require_root()
    if not load(STATE).get('ready') or PENDING.exists():
        return
    with lock():
        try:
            p = acme(ACME_PROD, ['--cron'], timeout=600)
            if p.returncode not in (0, 2):
                raise Stop('证书续期任务失败。')
            expiry = verify_served_certificate()
            if expiry - time.time() < 14 * 86400:
                raise Stop('证书剩余不足 14 天，需要处理。')
            state_update(certificate_ok=True, certificate_checked_at=time.time(), certificate_expires_at=expiry)
        except (Stop, OSError, ssl.SSLError):
            state_update(certificate_ok=False, certificate_checked_at=time.time())
            raise Stop('证书续期/生效检查失败；运行 status 查看状态，不必重装服务器。') from None


def proxy_probe_config(s, private):
    return {
        'log': {'loglevel': 'none'},
        'inbounds': [{'listen': '127.0.0.1', 'port': 18443, 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': False}}],
        'outbounds': [{'protocol': 'vmess', 'settings': {'vnext': [{'address': s['ssh']['server'], 'port': 443,
                      'users': [{'id': private['uuid'], 'alterId': 0, 'security': 'auto'}]}]},
                      'streamSettings': {'network': 'ws', 'security': 'tls',
                                         'tlsSettings': {'serverName': s['domain'], 'allowInsecure': False},
                                         'wsSettings': {'path': private['path'], 'headers': {'Host': s['domain']}}}}],
    }


def full_proxy_probe():
    s = load(STATE)
    private = load(ETC / 'private.json')
    temp = BASE / 'probe.json'
    atomic(temp, json.dumps(proxy_probe_config(s, private)))
    proc = None
    try:
        proc = subprocess.Popen([str(OPT / 'bin/v2ray'), 'run', '-config', str(temp)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        if proc.poll() is not None:
            raise Stop('临时完整链路探针未启动；可能端口占用。')
        for family in (4, 6):
            p = trace_curl(family, socks=True)
            if p is None or p.returncode or not trace_ok(p.stdout):
                raise Stop('完整 VMess/TLS 链路 IPv' + str(family) + ' WARP 检查失败。')
        p = trace_curl(4, socks=True, hostname=True)
        if p is None or p.returncode or not trace_ok(p.stdout):
            raise Stop('完整链路中的业务域名解析未通过。')
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        temp.unlink(missing_ok=True)


def deploy_prepared():
    s = load(STATE)
    verify_dns(s['domain'], s['ssh']['server'])
    state_update(**resolve_trace_addresses())
    transaction_begin('simple-install', 1200)
    connect_warp()
    wait_ssh_proof()
    with lock('transaction.lock', nonblocking=False):
        assert_transaction()
        state_update(stage='testing-proxy')
        run(['systemctl', 'reset-failed', PROXY_SERVICE], check=False)
        run(['systemctl', 'start', '--no-block', PROXY_SERVICE])
    deadline = time.monotonic() + 110
    while time.monotonic() < deadline:
        assert_transaction()
        if run(['systemctl', 'is-active', PROXY_SERVICE], check=False).returncode == 0:
            break
        time.sleep(2)
    else:
        raise Stop('代理启动检查未通过。')
    start_http()
    say('验证不停 Nginx 的证书申请方式，再安装正式证书。')
    if not load(STATE).get('staging_passed'):
        issue_certificate(staging=True)
        activate_tls(staging=True)
        state_update(staging_passed=True)
    issue_certificate(staging=False)
    activate_tls(staging=False)
    expiry = verify_served_certificate()
    full_proxy_probe()
    verify_warp_context()
    with lock('transaction.lock', nonblocking=False):
        assert_transaction()
        run(['systemctl', 'enable', 'warp-svc.service', PROXY_SERVICE, NGINX_SERVICE,
             'sps-health.timer', 'sps-renew.timer'])
    transaction_commit('client-trial', ready=True, health_ok=True, health_at=time.time(), health_failures=0,
                       certificate_ok=True, certificate_expires_at=expiry,
                       acceptance={'server_dual_stack': True, 'full_vmess_chain': True, 'tls_valid': True,
                                   'business_dns': True, 'fresh_ssh': True, 'live_warp_drop_test': False,
                                   'reboot_test': False, 'renewal_test': False, 'real_clients': False})
    run(['systemctl', 'start', 'sps-health.timer', 'sps-renew.timer'])
    say('服务器侧检查通过；以下节点仅用于客户端验收，真实掉线、重启、续期演练仍待完成。')
    export_node()


def install():
    require_root()
    if STATE.exists():
        if load(STATE).get('ready'):
            status()
            return
        resume()
        return
    conn = clean_check()
    network = initial_network(conn)
    if run(['id', '-u', PROXY_USER], check=False).returncode == 0:
        raise Stop('已有同名服务用户；未作修改。')
    say('精简版试装：尚未在你的干净 VPS 上完成验收。只用于已选定的干净测试机。')
    domain = prompt('代理域名（已有 A 记录指向本机）').lower()
    email = prompt('证书联系邮箱')
    validate_inputs(domain, email)
    verify_dns(domain, conn['server'])
    trace = resolve_trace_addresses()
    if prompt('确认测试机及官方 WARP/证书服务条款；输入 TRIAL 开始') != 'TRIAL':
        raise Stop('已取消，未安装。')
    BASE.mkdir(mode=0o700)
    ETC.mkdir(mode=0o755)
    import uuid
    save(ETC / 'private.json', {'uuid': str(uuid.uuid4()), 'path': '/ray'})
    save(STATE, {'version': VERSION, 'stage': 'preparing', 'ready': False, 'prepared': False,
                 'domain': domain, 'email': email, 'ssh': conn, 'network': network,
                 'firewall': firewall_environment(),
                 'created': time.time(), 'registration_blocked': False, **trace})
    with lock():
        prepare()
        deploy_prepared()


def resume(retry_registration=False):
    require_root()
    check_platform()
    s = load(STATE)
    if s.get('version') != VERSION:
        raise Stop('版本不一致；需要单独审核迁移。')
    if s.get('ready'):
        raise Stop('已有候选节点运行；需要维护时使用 repair，不重复安装。')
    if PENDING.exists() and not load(PENDING).get('cancelled'):
        raise Stop('仍有未提交事务，请先 rescue，不并发恢复。')
    if s.get('registration_blocked') and not retry_registration:
        raise Stop('此前已发现注册限流。不会自动重试；经重新判断后才使用 resume --retry-registration。')
    with lock():
        reset_cancelled_transaction()
        if retry_registration:
            state_update(registration_attempted=False, registration_blocked=False)
        prepare()
        deploy_prepared()


def wait_native_network(seconds=35):
    # network-online.target can be reached before dhcpcd obtains the address on
    # provider images. Wait for the saved IPv4 AND its default route; never invent
    # a gateway or use an address from the previous boot. The service has its own
    # 60-second startup bound in addition to this polling deadline.
    s = load(STATE)
    dev = s['network']['dev']
    deadline = time.monotonic() + seconds
    while True:
        addresses = run(['ip', '-j', 'address', 'show', 'dev', dev], check=False, timeout=5)
        routes = run(['ip', '-4', '-j', 'route', 'show', 'default', 'table', 'main'], check=False, timeout=5)
        if addresses.returncode == routes.returncode == 0:
            rows = json.loads(addresses.stdout)
            defaults = json.loads(routes.stdout)
            if (any(a.get('local') == s['ssh']['server'] for r in rows for a in r.get('addr_info', []))
                    and len(defaults) == 1 and defaults[0].get('dev') == dev and defaults[0].get('gateway')):
                return
        if time.monotonic() >= deadline:
            raise Stop('等待原生公网地址和默认路由超时；WARP 与代理保持停止，SSH 设置未改动。')
        time.sleep(1)


def internal_guard():
    require_root()
    s = load(STATE)
    if not s.get('proxy_uid'):
        raise Stop('基础准备未完成。')
    nft_apply()
    if PENDING.exists() and (load(PENDING).get('cancelled') or load(PENDING).get('boot_id') != boot_id()):
        safe_stop('reboot-with-uncommitted-transaction', boot=True)
        raise Stop('发现未提交安装后重启；代理和 WARP 启动已阻止，请重新登录后恢复。')
    if s.get('stage') == 'safe-stopped' and not PENDING.exists():
        raise Stop('处于安全停止状态；没有自动连接 WARP。')
    wait_native_network()
    management_routes()


def proxy_gate():
    require_root()
    s = load(STATE)
    if not s.get('prepared') or s.get('stage') == 'safe-stopped':
        raise Stop('本项目尚未允许启动代理。')
    nft_apply()
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            verify_native_split()
            business_routes()
            verify_warp_context()
            return
        except Stop:
            time.sleep(3)
    raise Stop('启动门禁：WARP 未验证，代理保持停止。')


def deadline_check():
    require_root()
    with lock('transaction.lock', nonblocking=False):
        if not PENDING.exists():
            return
        pending = load(PENDING)
        if pending.get('cancelled'):
            if load(STATE).get('recovery_errors'):
                safe_stop_locked('retry-incomplete-recovery')
            return
        if pending.get('boot_id') != boot_id() or time.time() >= pending.get('deadline', 0):
            # Independent of the installer's long operation lock, but serialized with commit.
            safe_stop_locked('deadline-expired')


def health_check():
    require_root()
    s = load(STATE)
    if not s.get('ready') or PENDING.exists():
        return
    with lock():
        try:
            # Disconnect/reconnect destroys the tunnel interface and the kernel
            # removes routes attached to it. Recreate only our business default;
            # the UID firewall remains in force throughout the interruption.
            verify_native_split()
            business_routes()
            verify_warp_context()
            healthy = run(['systemctl', 'is-active', PROXY_SERVICE], check=False).returncode == 0
        except Stop:
            healthy = False
        failures = 0 if healthy else s.get('health_failures', 0) + 1
        state_update(health_ok=healthy, health_at=time.time(), health_failures=failures)
        if failures >= 3:
            # Firewall blocks immediately; this reduces stale services after persistent failures.
            run(['systemctl', 'stop', PROXY_SERVICE], check=False, timeout=45)
            state_update(ready=False, stage='needs-repair')
            say('持续健康检查失败，代理已停止；使用 status/repair。未删除或重建 WARP 注册。')


def status():
    require_root()
    s = load(STATE)
    output = {'版本': VERSION, '阶段': s.get('stage'), '可输出测试节点': bool(s.get('ready')),
              '存在未提交事务': PENDING.exists(), '上次健康检查合格': s.get('health_ok'),
              '需要系统重启': Path('/var/run/reboot-required').exists(),
              '证书检查合格': s.get('certificate_ok'),
              '证书剩余天数': int((s.get('certificate_expires_at', 0) - time.time()) / 86400) if s.get('certificate_expires_at') else None,
              '业务保护表存在': nft_is_present() if s.get('prepared') else False,
              '真实客户端/掉线/重启验收': s.get('acceptance', {}),
              '通知': '此候选尚未配置外部告警；状态与错误只在本机保存'}
    for service in ('warp-svc.service', PROXY_SERVICE, NGINX_SERVICE):
        output[service] = run(['systemctl', 'is-active', service], check=False).stdout.strip()
    say(json.dumps(output, ensure_ascii=False, indent=2))


def export_node():
    require_root()
    s = load(STATE)
    if not s.get('ready') or PENDING.exists():
        raise Stop('尚未通过服务器侧验收，或有未提交事务；不输出节点。')
    verify_warp_context()
    if not tls_websocket(False):
        raise Stop('当前 TLS/入口验证失败，不输出节点。')
    full_proxy_probe()
    private = load(ETC / 'private.json')
    node = {'v': '2', 'ps': 'Simple-WARP-TRIAL', 'add': s['domain'], 'port': '443', 'id': private['uuid'],
            'aid': '0', 'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': s['domain'],
            'path': private['path'], 'tls': 'tls', 'sni': s['domain']}
    link = 'vmess://' + base64.b64encode(json.dumps(node, separators=(',', ':')).encode()).decode()
    atomic(BASE / 'client-trial.txt', 'CANDIDATE: not production accepted\n' + link + '\n')
    say('仅用于你自己的客户端验收；请勿把接下来的节点或二维码发到聊天/公开网站。')
    with open('/dev/tty', 'w') as tty:
        tty.write(link + '\n')
        tty.flush()
        # Secret travels over stdin, not the command line.
        subprocess.run(['qrencode', '-t', 'ANSIUTF8'], input=link, text=True, stdout=tty, check=False)
    say('本机另存 root 专用文件：/var/lib/senyz-proxy-simple/client-trial.txt')


def diagnostics():
    require_root()
    s = load(STATE)
    report = {k: s.get(k) for k in ('version', 'stage', 'ready', 'prepared', 'created', 'health_ok',
                                  'health_at', 'health_failures', 'registration_blocked', 'recovery_errors', 'acceptance',
                                  'certificate_ok', 'certificate_checked_at', 'certificate_expires_at')}
    report['pending'] = PENDING.exists()
    report['recent_steps'] = recent_steps()
    report['disk_free_bytes'] = shutil.disk_usage('/').free
    report['reboot_required'] = Path('/var/run/reboot-required').exists()
    report['guard_table_present'] = nft_is_present() if s.get('prepared') else False
    report['services'] = {name: run(['systemctl', 'is-active', name], check=False).stdout.strip()
                          for name in ('warp-svc.service', PROXY_SERVICE, NGINX_SERVICE)}
    # Explicit allowlist: never export raw state, client settings, XML, or journals.
    atomic(BASE / 'diagnostics.json', json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    say('脱敏诊断：/var/lib/senyz-proxy-simple/diagnostics.json；不包含 IP、域名、UUID、节点或令牌。')


def repair():
    require_root()
    s = load(STATE)
    if not s.get('prepared'):
        raise Stop('准备未完成，使用 resume。')
    if s.get('registration_blocked'):
        raise Stop('此前是注册限流，不把它当普通断线反复修复。')
    with lock():
        safe_stop('repair-request')
        reset_cancelled_transaction()
        state_update(ready=False)
        deploy_prepared()








def main(args):
    command = args[0] if args else 'install'
    if command == 'check-terminal':
        terminal_check()
    elif command == 'check':
        require_root()
        clean_check()
        say('只读预检通过；没有安装或修改服务器。')
    elif command in ('install', 'trial-install'):
        install()
    elif command == 'resume':
        resume('--retry-registration' in args[1:])
    elif command == 'confirm-ssh':
        confirm_ssh()
    elif command == 'status':
        status()
    elif command == 'node':
        with lock():
            export_node()
    elif command == 'diagnostics':
        diagnostics()
    elif command == 'repair':
        repair()
    elif command == 'rescue':
        safe_stop()
    elif command == 'internal-guard':
        internal_guard()
    elif command == 'internal-proxy-gate':
        proxy_gate()
    elif command == 'internal-deadline':
        deadline_check()
    elif command == 'internal-health':
        health_check()
    elif command == 'internal-renew':
        renew_certificate()
    elif command == 'internal-cert-deploy':
        certificate_deploy()
    elif command in ('help', '--help', '-h'):
        say('用法：bash setup_script.sh（全新测试机安装）；只读检查：check；终端检查：check-terminal；状态：status。')
        say('故障时保留输出交给维护者；不需要重新安装系统。')
    else:
        raise Stop('未知操作，未执行。')


def interrupted(signum, frame):
    raise Stop('操作已中断。')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main(sys.argv[2:])
    except Exception as exc:
        say('停止：' + (str(exc) if isinstance(exc, Stop) else type(exc).__name__ + '；状态未通过检查。'))
        if ACTIVE_TRANSACTION and STATE.exists():
            try:
                safe_stop('operation-failed')
            except Exception:
                say('自动恢复未全部完成；持久事务保留，定时器将继续尝试。请保留供应商救援入口。')
        if not sys.argv[2:] or sys.argv[2] in ('install', 'trial-install', 'resume', 'repair'):
            say('先保留 SSH 窗口和本段输出；不要重装、叠加旧脚本或反复注册/签发证书。')
            say('故障处理：仓库 docs/TROUBLESHOOTING.md；本次停止不代表必须重装系统。')
        sys.exit(1)
SWO_PYTHON
