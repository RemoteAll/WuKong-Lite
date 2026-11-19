"""release_patch 对拍（`release_patch.py` vs `wk release-patch`）。

自建一个 repo 工作区（`.repo/manifest.xml` + `<include>` + 两个子 git 仓库），
按两种起始 ref 各跑一遍：
  * `tag`：在首个提交打 `BASE` 标签（**不含**边界提交）；
  * `sha`：直接给首个提交 SHA（**含**边界提交）。

比较 `ref/*.patch` 与 `ours/*.patch` 的文件名集合与逐字节内容。
退出码：0 全部一致；1 有差异或环境缺失。
"""
import io
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
WORK = os.path.join(REPO, 'artifacts', 'release_patch')

MANIFEST = '''<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <include name="extra.xml"/>
  <project name="bsp/artinchip" path="bsp/artinchip">
    <linkfile src="include/a.h" dest="include/a.h"/>
  </project>
  <project name="target" path="target"/>
</manifest>
'''

EXTRA = '''<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="kernel" path="kernel/rt-thread"/>
</manifest>
'''

GIT_ENV = {
    'GIT_AUTHOR_NAME': 'WK Test',
    'GIT_AUTHOR_EMAIL': 'wk@example.com',
    'GIT_COMMITTER_NAME': 'WK Test',
    'GIT_COMMITTER_EMAIL': 'wk@example.com',
    # 固定时间但**保留本地时区**：参考用 %ct→本地时间，我们用 --format=%ci
    'GIT_AUTHOR_DATE': '2025-11-20 10:11:12',
    'GIT_COMMITTER_DATE': '2025-11-20 10:11:12',
}


def sh(args, cwd, env=None, check=True):
    e = dict(os.environ)
    e.update(env or {})
    e['PYTHONIOENCODING'] = 'utf-8'
    r = subprocess.run(args, cwd=cwd, capture_output=True, env=e)
    if check and r.returncode != 0:
        raise RuntimeError('cmd failed: %s\n%s\n%s'
                           % (' '.join(args), r.stdout.decode('utf-8', 'replace'),
                              r.stderr.decode('utf-8', 'replace')))
    return r


def make_repo(ws, path, commits, tag=None):
    root = os.path.join(ws, path)
    os.makedirs(root, exist_ok=True)
    sh(['git', 'init', '-q', '-b', 'main'], root)
    first_sha = None
    for i, files in enumerate(commits):
        for name, body in files.items():
            full = os.path.join(root, name)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, 'wb') as f:
                f.write(body)
        # 提交信息走文件（避免编码问题）
        msg_path = os.path.join(root, '.git', 'msg.txt')
        with open(msg_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write('提交 %d：%s\n' % (i + 1, path))
        sh(['git', 'add', '-A'], root, GIT_ENV)
        sh(['git', 'commit', '-q', '-F', '.git/msg.txt'], root, GIT_ENV)
        sha = sh(['git', 'rev-parse', 'HEAD'], root).stdout.decode().strip()
        if first_sha is None:
            first_sha = sha
    if tag:
        sh(['git', 'tag', tag, first_sha], root)
    return first_sha


def build_ws(ws):
    shutil.rmtree(ws, ignore_errors=True)
    os.makedirs(os.path.join(ws, '.repo', 'manifests'), exist_ok=True)
    with open(os.path.join(ws, '.repo', 'manifest.xml'), 'w', encoding='ascii', newline='\n') as f:
        f.write(MANIFEST)
    with open(os.path.join(ws, '.repo', 'manifests', 'extra.xml'), 'w', encoding='ascii', newline='\n') as f:
        f.write(EXTRA)

    sha_a = make_repo(ws, 'bsp/artinchip', [
        {'include/a.h': b'#define A 1\n', 'drv/pm.c': b'int pm(void) { return 0; }\n'},
        {'drv/pm.c': b'int pm(void) { return 1; }\n', 'drv/gpio.c': b'int gpio(void) { return 2; }\n'},
    ], tag='BASE')
    make_repo(ws, 'target', [
        {'pack/x.json': b'{"a": 1}\n'},
        {'pack/x.json': b'{"a": 2}\n'},
    ], tag='BASE')
    # 未匹配 ref 的项目：应被跳过而不报错
    make_repo(ws, 'kernel/rt-thread', [
        {'rt.c': b'void rt(void) {}\n'},
    ])
    return sha_a


def compare(name, ref_dir, our_dir):
    ref_files = sorted(f for f in os.listdir(ref_dir) if f.endswith('.patch'))
    our_files = sorted(f for f in os.listdir(our_dir) if f.endswith('.patch'))
    if ref_files != our_files:
        print('FAIL %s: 文件名不一致\n  ref =%s\n  ours=%s' % (name, ref_files, our_files))
        return 1
    fails = 0
    for f in ref_files:
        a = open(os.path.join(ref_dir, f), 'rb').read()
        b = open(os.path.join(our_dir, f), 'rb').read()
        if a != b:
            fails += 1
            print('FAIL %s/%s 内容不一致（ref=%d, ours=%d）' % (name, f, len(a), len(b)))
            al, bl = a.splitlines(), b.splitlines()
            for i in range(min(len(al), len(bl))):
                if al[i] != bl[i]:
                    print('  line %d:\n    ref = %r\n    ours= %r' % (i + 1, al[i], bl[i]))
                    break
        else:
            print('  OK %s/%s (%d B)' % (name, f, len(a)))
    return fails


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    if not os.path.isfile(os.path.join(SCRIPTS, 'release_patch.py')):
        print('SKIP: 参考 release_patch.py 不可用（设置 WK_REF_SDK）')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    ws = os.path.join(WORK, 'ws')
    sha_a = build_ws(ws)

    fails = 0
    cases = [
        ('tag', ['-t', 'BASE']),
        ('sha', ['-t', sha_a[:10]]),
        ('count', ['-t', 'BASE', '-n', '1']),
        ('projects', ['-t', 'BASE', '-p', 'bsp/artinchip']),
    ]
    for name, extra in cases:
        ref_dir = os.path.join(WORK, f'{name}-ref')
        our_dir = os.path.join(WORK, f'{name}-ours')
        os.makedirs(ref_dir, exist_ok=True)
        os.makedirs(our_dir, exist_ok=True)

        r = sh([sys.executable, os.path.join(SCRIPTS, 'release_patch.py')] + extra +
                ['-o', ref_dir], ws, check=False)
        if r.returncode != 0:
            print('FAIL %s: 参考 release_patch 失败' % name)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
            fails += 1
            continue

        r = sh([WK, 'release-patch'] + extra + ['-o', our_dir], ws, check=False)
        if r.returncode != 0:
            print('FAIL %s: wk release-patch 失败' % name)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
            fails += 1
            continue
        out = (r.stdout + r.stderr).decode('utf-8', 'replace').strip().splitlines()
        print('[%s] %s' % (name, out[-1] if out else ''))

        fails += compare(name, ref_dir, our_dir)

    # --list 也要一致（项目路径 + linkfile 映射）
    ref_list = sh([sys.executable, os.path.join(SCRIPTS, 'release_patch.py'), '--list'],
                  ws, check=False)
    our_list = sh([WK, 'release-patch', '--list'], ws, check=False)
    ref_txt = ref_list.stdout.decode('utf-8', 'replace')
    our_txt = our_list.stdout.decode('utf-8', 'replace')

    def norm(txt):
        lines = []
        for ln in txt.splitlines():
            ln = ln.rstrip()
            if not ln:
                continue
            if ln.startswith('>>>') or ln.startswith('!!!') or ln.startswith('***'):
                continue
            lines.append(' '.join(ln.split()))
        return lines

    if norm(ref_txt) != norm(our_txt):
        print('FAIL --list 不一致')
        print('  ref =', norm(ref_txt))
        print('  ours=', norm(our_txt))
        fails += 1
    else:
        print('  OK --list（%d 行）' % len(norm(ref_txt)))

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
