import os, socket, subprocess, sys, threading, time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')


class SilentServer(threading.Thread):
    """accept 连接但永不回包，用于验证客户端读超时。"""

    def __init__(self):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.received = 0

    def run(self):
        try:
            conn, _ = self.sock.accept()
            conn.settimeout(5)
            try:
                data = conn.recv(4096)
                self.received = len(data)
            except Exception:
                pass
            time.sleep(3)  # 保持连接不关
            conn.close()
        finally:
            self.sock.close()


srv = SilentServer()
srv.start()
t0 = time.time()
r = subprocess.run([WK, 'upg', 'proto-version', '--send', '--server-port', str(srv.port),
                    '--timeout', '300'], capture_output=True)
elapsed = time.time() - t0
msg = (r.stdout + r.stderr).decode('utf-8', 'replace')
srv.join(6)

ok_rc = r.returncode != 0
ok_timeout_msg = 'Timeout' in msg or '超时' in msg
ok_fast = elapsed < 2.0
ok_sent = srv.received >= 12
print(f'timeout-case: rc={r.returncode} elapsed={elapsed:.2f}s sent={srv.received}B')
print('  msg:', msg.replace('\n', ' | ')[:200])
print('  ok:', dict(rc=ok_rc, timeout_msg=ok_timeout_msg, fast=ok_fast, frame_sent=ok_sent))
sys.exit(0 if (ok_rc and ok_timeout_msg and ok_fast and ok_sent) else 1)
