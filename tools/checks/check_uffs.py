"""UFFS 镜像对拍（backlog P1-3，按「C 语言怎么用我们就怎么用」策略）。

SDK 内没有 UFFS 核心源码（只有 `mkuffs`/`mkuffs.exe` 与 `drv/spinand/uffs.c` 移植层），
SDK 自己的 `makeuffs.py` 也是**调这个二进制**。因此我们也调同一个工具、同样的参数：
  mkuffs -t <partblkcnt> -p <page> -b <blockpages> -s <oob> -x auto -o 0 -f <out> -d <in>

对拍：同一份夹具分别用参考脚本与 `wk image uffs` 生成，必须**逐字节一致**。
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
WORK = os.path.join(REPO, 'artifacts', 'uffs')

PART_SIZE = 0x1000000   # 16 MiB
PAGE = 2048
BLOCK_PAGES = 64
OOB = 64
FILES = {
    'a.txt': b'uffs root file\n' * 40,
    'sub/b.bin': bytes(range(256)),
}


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    mkuffs = os.path.join(SCRIPTS, 'mkuffs.exe')
    if not os.path.isfile(mkuffs):
        print('SKIP: 缺少参考 mkuffs.exe')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    data = os.path.join(WORK, 'rootfs')
    os.makedirs(os.path.join(data, 'sub'), exist_ok=True)
    for name, body in FILES.items():
        with open(os.path.join(data, name), 'wb') as f:
            f.write(body)

    ref_dir = os.path.join(WORK, 'ref')
    our_dir = os.path.join(WORK, 'our')
    for d in (ref_dir, our_dir):
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'partition_file_list.h'), 'w', encoding='ascii', newline='\n') as f:
            f.write('rootfs,data.uffs,%d\n' % PART_SIZE)

    ref = os.path.join(ref_dir, 'data.uffs')
    our = os.path.join(our_dir, 'data.uffs')

    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'makeuffs.py'),
                        '-i', 'rootfs', '-o', 'ref/data.uffs',
                        '-g', str(BLOCK_PAGES), '-p', str(PAGE), '-s', str(OOB),
                        '-t', SCRIPTS + os.sep],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0 or not os.path.isfile(ref):
        print('FAIL: 参考 makeuffs 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1

    r = subprocess.run([WK, 'image', 'uffs', '-i', 'rootfs', '-o', 'our/data.uffs',
                        '-g', str(BLOCK_PAGES), '-p', str(PAGE), '-s', str(OOB),
                        '-t', SCRIPTS],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0 or not os.path.isfile(our):
        print('FAIL: wk image uffs 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1

    a = open(ref, 'rb').read()
    b = open(our, 'rb').read()
    print('size ref=%d ours=%d' % (len(a), len(b)))
    fails = 0
    if a != b:
        fails += 1
        first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), -1)
        print('FAIL: 内容不一致（首个差异 offset=%d）' % first)
    else:
        print('OK[uffs]: 与参考逐字节一致')
    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
