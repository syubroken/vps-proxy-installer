#!/usr/bin/env python3
"""住宅 IP 失效邮件提醒：检测程序。安装后位于 /usr/local/lib/residential-alert/check.py，由定时器每 10 分钟运行。

做法与 住宅IP分流-自测.sh 相同：在本机临时起一个模拟客户端，经 Nginx/TLS/VMess 进入代理，访问名单里的
challenges.cloudflare.com，看出口是不是住宅 IP。连续 2 次失败发邮件，仍未恢复时每 24 小时提醒一次，恢复时再发一封。
程序会在内部读取节点参数和邮箱授权码，但不显示 UUID、代理密码或授权码。
预期出口 IP 来自启用脚本保存的 /etc/senyz-proxy-simple/residential.json；那里没写时，第一次检测正常就自动记下。

用法：check.py check | probe（只检测、不发信、不记状态） | test-mail | status
"""
import fcntl
import json
import os
import smtplib
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

CONF = '/etc/residential-alert/mail.conf'
STATE = '/var/lib/residential-alert/state.json'
V2RAY = '/etc/senyz-proxy-simple/v2ray.json'
NODE_STATE = '/var/lib/senyz-proxy-simple/state.json'
NODE_PRIVATE = '/etc/senyz-proxy-simple/private.json'
BIN = '/opt/senyz-proxy-simple/bin/v2ray'
RES_SETTINGS = '/etc/senyz-proxy-simple/residential.json'  # saved by the enable script (no password inside)
RES_URL = 'https://challenges.cloudflare.com/cdn-cgi/trace'  # on the residential list
WARP_URL = 'https://www.cloudflare.com/cdn-cgi/trace'  # not on the list, so it shows the WARP path
PORT = 18463  # the self-test uses 18453
FAILS_BEFORE_MAIL = 2
REMIND_SECONDS = 24 * 3600
BEIJING = timezone(timedelta(hours=8))

FOOTER = ('怎么办：先在客户端里切到应急节点（全走 WARP、不经过住宅 IP 的那个）继续用，再联系 Claude 排查。\n'
          '这封邮件由 {domain} 每 10 分钟一次的自动检测发出。')
PROBLEMS = {
    'res_down': ('住宅 IP 连不上',
                 '经这台服务器访问 AI 网站会打不开；其他网站不受影响（WARP 正常），应急节点也不受影响。\n'
                 '常见原因：住宅代理服务商故障、流量用完、套餐到期、代理密码改过。'),
    'all_down': ('服务器整体不通',
                 '经这台服务器，AI 网站和普通网站都测不通，可能是 WARP 或代理服务出了问题。'),
    'bypassed': ('AI 网站没有走住宅 IP',
                 '分流没有生效：AI 网站经这台服务器看到的是 WARP 的 IP，不是住宅 IP。'),
}


def domain():
    return load(NODE_STATE, {}).get('domain') or socket.gethostname()


def now_beijing():
    return datetime.now(BEIJING).strftime('%Y-%m-%d %H:%M')


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_state(st):
    os.makedirs(os.path.dirname(STATE), mode=0o700, exist_ok=True)
    tmp = STATE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(st, f, ensure_ascii=False)
    os.replace(tmp, STATE)


def residential_enabled():
    return any(o.get('tag') == 'residential' for o in load(V2RAY, {}).get('outbounds', []))


def trace(url):
    try:
        r = subprocess.run(['curl', '-s', '--max-time', '25', '--socks5-hostname', f'127.0.0.1:{PORT}', url],
                           capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return None
    kv = dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)
    return kv if 'ip' in kv else None


def probe():
    s, p = load(NODE_STATE, None), load(NODE_PRIVATE, None)
    if not s or not p:
        return None, None
    cfg = {'log': {'loglevel': 'none'},
           'inbounds': [{'listen': '127.0.0.1', 'port': PORT, 'protocol': 'socks',
                         'settings': {'auth': 'noauth', 'udp': False}}],
           'outbounds': [{'protocol': 'vmess',
                          'settings': {'vnext': [{'address': s['ssh']['server'], 'port': 443,
                                                  'users': [{'id': p['uuid'], 'alterId': 0, 'security': 'auto'}]}]},
                          'streamSettings': {'network': 'ws', 'security': 'tls',
                                             'tlsSettings': {'serverName': s['domain'], 'allowInsecure': False},
                                             'wsSettings': {'path': p['path'], 'headers': {'Host': s['domain']}}}}]}
    with tempfile.TemporaryDirectory(prefix='residential-alert.', dir='/run') as d:
        path = os.path.join(d, 'client.json')
        with open(path, 'w') as f:
            json.dump(cfg, f)
        proc = subprocess.Popen([BIN, 'run', '-config', path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(50):
                with socket.socket() as sk:
                    if sk.connect_ex(('127.0.0.1', PORT)) == 0:
                        break
                time.sleep(0.1)
            res = trace(RES_URL) or trace(RES_URL)  # one retry for a transient error
            warp = None if res else trace(WARP_URL)
            return res, warp
        finally:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()


def endpoint():
    s = load(RES_SETTINGS, None)
    return f"{s.get('server')}:{s.get('port')}" if s else ''


def expected_ip(st):
    """The exit IP websites should see: from the enable script's settings, else the one learned for this endpoint."""
    s = load(RES_SETTINGS, None) or {}  # no settings file: learn the exit on the first good check
    if s.get('expected_ip'):
        return s['expected_ip']
    learned = st.get('learned') or {}
    return learned.get('ip', '') if learned.get('endpoint') == endpoint() else ''  # a new endpoint starts unknown


def classify(res, warp, expected):
    if res and res.get('warp') == 'off':
        if not expected:
            return 'learned', res.get('ip')  # no expected IP configured yet: remember this one
        return ('ok' if res.get('ip') == expected else 'changed'), res.get('ip')
    if res:
        return 'bypassed', res.get('ip')
    return ('res_down' if warp else 'all_down'), None


def send(subject, body):
    c = load(CONF, None)
    if not c:
        print('没有邮件设置，发不了信。')
        return False
    m = EmailMessage()
    m['Subject'] = subject
    m['From'] = c['user']
    m['To'] = c.get('to') or c['user']
    m['Date'] = formatdate(localtime=False)
    m['Message-ID'] = make_msgid(domain=c['user'].rsplit('@', 1)[-1])
    m.set_content(body)
    try:
        with smtplib.SMTP_SSL(c['host'], int(c.get('port', 465)), timeout=30,
                              context=ssl.create_default_context()) as smtp:
            smtp.login(c['user'], c['pass'])
            smtp.send_message(m)
        return True
    except Exception as e:  # report the kind of failure only; smtplib errors do not contain the code
        print('发信失败：', type(e).__name__, str(e)[:200])
        return False


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'check'
    with open('/run/residential-alert.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if mode == 'test-mail':
            ok = send(f'【{domain()}】测试邮件，无需处理：提醒已开启',
                      f'这是一封测试邮件，说明这台服务器能给你发提醒。\n\n时间：{now_beijing()}（北京时间）\n'
                      '以后只有住宅 IP 出问题、或者恢复时，才会收到邮件。')
            print('测试邮件已发出，请查收（也看一下垃圾邮件箱）。' if ok else '测试邮件没有发出去。')
            sys.exit(0 if ok else 1)
        st = load(STATE, {})
        for k, v in (('fails', 0), ('alerted', False), ('last_mail', 0), ('last_kind', ''), ('changed_ip', '')):
            st.setdefault(k, v)
        if mode == 'status':
            print(json.dumps(st, ensure_ascii=False))
            return
        if not residential_enabled():
            print('住宅 IP 分流没有启用，跳过检测。')
            return
        expected = expected_ip(st)
        kind, ip = classify(*probe(), expected)
        if mode == 'probe':
            print(f'检测结果：{kind}' + (f'（{ip}）' if ip else ''))
            return
        t = time.time()
        if kind == 'learned':
            st['learned'] = {'endpoint': endpoint(), 'ip': ip}  # later checks compare against this exit
            kind = 'ok'
        if kind == 'ok':
            if st['alerted']:
                send(f'【{domain()}】住宅 IP 已恢复',
                     f'住宅 IP 已恢复正常（{ip}），经这台服务器访问 AI 网站又能用了。\n\n时间：{now_beijing()}（北京时间）')
            st.update(fails=0, alerted=False, changed_ip='')
        elif kind == 'changed':
            if st['changed_ip'] != ip and send(
                    f'【{domain()}】住宅 IP 变了',
                    f'住宅 IP 还能用，但出口从 {expected} 变成了 {ip}。AI 网站会看到一个新的 IP。\n'
                    f'如果不是你在住宅代理服务商的后台换的，请联系 Claude 核对。\n\n时间：{now_beijing()}（北京时间）'):
                st['changed_ip'] = ip
            st.update(fails=0, alerted=False)
        else:
            st['fails'] += 1
            due = ((not st['alerted'] and st['fails'] >= FAILS_BEFORE_MAIL)
                   or (st['alerted'] and t - st['last_mail'] >= REMIND_SECONDS))
            if due:
                title, text = PROBLEMS[kind]
                footer = FOOTER.format(domain=domain())
                if send(f'【{domain()}】{title}',
                        f'{text}\n\n时间：{now_beijing()}（北京时间），已连续 {st["fails"]} 次检测失败。\n\n{footer}'):
                    st.update(alerted=True, last_mail=t)
        st['last_kind'] = kind
        st['last_check'] = now_beijing()
        save_state(st)
        print(f'检测结果：{kind}' + (f'（{ip}）' if ip else '') + f'，连续失败 {st["fails"]} 次')


if __name__ == '__main__':
    main()
