import json
import os
import socket
import struct
import subprocess
import sys
import threading

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CLIENT_DIR = os.path.join(REPO, 'docs', 'official', 'skills', 'aiburn', 'scripts')
sys.path.insert(0, CLIENT_DIR)
import aiburn.aicupg_client as C

WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')


def recv_frame(conn, buf):
    while True:
        if len(buf) >= 8:
            plen = struct.unpack('<I', bytes(buf[4:8]))[0]
            total = 8 + plen + 4
            if len(buf) >= total:
                frame = bytes(buf[:total])
                del buf[:total]
                return frame
        data = conn.recv(4096)
        if not data:
            return None
        buf += data


class MockServer(threading.Thread):
    """单连接 mock server：记录收到的帧，按 responder 回包。"""

    def __init__(self, responder):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.frames = []
        self.responder = responder
        self.error = None

    def run(self):
        try:
            conn, _ = self.sock.accept()
            conn.settimeout(5)
            buf = bytearray()
            frame = recv_frame(conn, buf)
            if frame is None:
                self.error = 'no frame'
                return
            self.frames.append(frame.hex())
            dec = C.decode_frame(frame)
            if dec is None:
                self.error = 'decode failed'
                return
            cmd, payload = dec
            resp = self.responder(cmd, payload)
            if resp is not None:
                conn.sendall(resp)
                conn.shutdown(socket.SHUT_WR)
            conn.close()
        except Exception as e:  # noqa: BLE001
            self.error = repr(e)
        finally:
            self.sock.close()


def ok_responder(data=None):
    def f(cmd, payload):
        body = json.dumps({'status': 'success', 'data': data if data is not None else {}})
        return C.encode_frame(cmd | C.CMD_RSP_MASK, body.encode())
    return f


def wrong_cmd_responder(cmd, payload):
    # 故意用错误命令字回包，验证客户端会拒绝
    body = json.dumps({'status': 'success'}).encode()
    return C.encode_frame((cmd | C.CMD_RSP_MASK) ^ 0x01, body)


def run_case(name, wk_args, py_frame_fn, responder, expect_substr, expect_ok=True):
    srv = MockServer(responder)
    srv.start()
    args = [WK, 'upg'] + wk_args + ['--send', '--server-port', str(srv.port)]
    r = subprocess.run(args, capture_output=True)
    srv.join(5)
    out = r.stdout.decode('utf-8', 'replace')

    expected = py_frame_fn().hex()
    ok_frame = srv.frames == [expected] if srv.frames else False
    ok_status = (r.returncode == 0) if expect_ok else (r.returncode != 0)
    ok_body = expect_substr in out
    ok = ok_frame and ok_status and ok_body and srv.error is None
    print(f'{name:22s}', 'OK' if ok else 'DIFF',
          f'(frame={ok_frame} status={ok_status} body={ok_body} srv_err={srv.error})')
    if not ok:
        print('  expect frame', expected[:80])
        print('  got frames  ', [f[:80] for f in srv.frames])
        print('  stdout      ', out.replace('\n', ' | ')[:300])
        print('  stderr      ', r.stderr.decode('utf-8', 'replace')[:200])
    return ok


def py_client():
    return C.AICUPGClient()


def capture_frame(fn):
    cap = []
    cli = py_client()
    cli._task_id_counter = 0
    cli._send_frame = lambda cmd, payload: (cap.append(C.encode_frame(cmd, payload)) or True)
    cli._recv_frame = lambda timeout=None: None
    fn(cli)
    return cap[0]


fails = 0
cases = [
    ('proto-version', ['proto-version'], lambda: capture_frame(lambda c: c.get_proto_version()),
     ok_responder({'version': '1.0.1'}), '"version": "1.0.1"'),
    ('config-device', ['config-device', '--port', 'COM4', '--baudrate', '115200'],
     lambda: capture_frame(lambda c: c.config_device('COM4', 115200)), ok_responder(), '"status": "success"'),
    ('burn', ['burn', '--image', 'C:\\temp\\a.img'],
     lambda: capture_frame(lambda c: c.burn_image('C:\\temp\\a.img')), ok_responder(), '"status": "success"'),
    ('send-cmd', ['send-cmd', '--command', 'reset'],
     lambda: capture_frame(lambda c: c.send_cmd('reset')), ok_responder(), '"status": "success"'),
]

for name, wk_args, py_fn, responder, needle in cases:
    if not run_case(name, wk_args, py_fn, responder, needle):
        fails += 1

if not run_case('wrong-response-cmd', ['proto-version'],
                lambda: capture_frame(lambda c: c.get_proto_version()),
                wrong_cmd_responder, '', expect_ok=False):
    fails += 1

# 连接失败路径：没有服务端时应给出明确错误并非零退出
r = subprocess.run([WK, 'upg', 'proto-version', '--send', '--server-port', '1'], capture_output=True)
conn_fail_ok = r.returncode != 0 and 'connect' in r.stdout.decode('utf-8', 'replace').lower() or True
msg = r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
conn_fail_ok = r.returncode != 0 and ('连接' in msg or 'Connection' in msg or 'connect' in msg.lower())
print(f'{"connect-refused":22s}', 'OK' if conn_fail_ok else 'DIFF', f'(rc={r.returncode})')
if not conn_fail_ok:
    fails += 1
    print('  ', msg.replace('\n', ' | ')[:200])

print('\nFAILS =', fails)
sys.exit(1 if fails else 0)

