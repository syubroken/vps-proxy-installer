#!/usr/bin/env python3
"""给手机上的 Shadowrocket 扫码导入节点。服务器上的文件名是 /root/phone-qr.py。

在电脑的终端里运行：ssh -t root@服务器IP python3 /root/phone-qr.py [节点名]
- 依次显示本机节点和应急节点（如果开了应急入口）的二维码，只显示二维码，不显示链接文字。
- 节点名不写时用域名；应急节点在后面加“-应急”。导入后也可以在手机上改名。
- 每扫好一个按回车，屏幕和滚动记录随即清空。
- 节点参数在服务器内部读取，和安装程序的 node 命令一样只给用户本人看。Claude 不读这个终端的内容。
"""
import base64
import json
import os
import subprocess
import sys

if os.geteuid() != 0 or not sys.stdout.isatty():
    sys.exit('需要 root，并且要在交互终端里运行。')

state = json.load(open('/var/lib/senyz-proxy-simple/state.json'))
private = json.load(open('/etc/senyz-proxy-simple/private.json'))
domain = state['domain']
base = sys.argv[1] if len(sys.argv) > 1 else domain
nodes = [(base, private['uuid'])]
em = '/etc/senyz-proxy-simple/emergency.json'
if os.path.exists(em):
    nodes.append((f'{base}-应急', json.load(open(em))['uuid']))

CLEAR = '\033[2J\033[3J\033[H'  # clear the screen and the scrollback
for i, (name, uid) in enumerate(nodes, 1):
    node = {'v': '2', 'ps': name, 'add': domain, 'port': '443', 'id': uid, 'aid': '0', 'scy': 'auto', 'net': 'ws',
            'type': 'none', 'host': domain, 'path': private['path'], 'tls': 'tls', 'sni': domain}
    link = 'vmess://' + base64.b64encode(json.dumps(node, ensure_ascii=False, separators=(',', ':')).encode()).decode()
    print(CLEAR, end='')
    print(f'第 {i}/{len(nodes)} 个：【{name}】\n用 Shadowrocket 首页左上角的扫码图标扫下面的二维码（不要拍照，也不要截图）：\n', flush=True)
    subprocess.run(['qrencode', '-t', 'ANSIUTF8'], input=link, text=True, check=False)
    del link
    input('\n扫好后按回车继续……')
print(CLEAR + '完成，屏幕已清空。可以关掉这个终端标签了。', flush=True)
