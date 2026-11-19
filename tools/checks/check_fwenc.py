"""固件加密对拍（backlog P1-4，按「C 语言怎么用我们就怎么用」策略）。

SDK 内没有加密算法源码（只有预编译 `firmware_security_encrypt[.exe]`），
SDK 自己的 `mk_image.py::data_crypt_create_image()` 也是**调这个二进制**：
  firmware_security_encrypt --key <k> [--nonce <n>] [--tweak <t>] --infile <in> --outfile <out>

对拍：用同一组参数分别直接调 exe（模拟参考调用）与 `wk image fwenc`，产物必须逐个字节一致；
并覆盖「带 nonce+tweak / 只带 tweak / 都不带」三种参数组合。
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
EXE = os.path.join(SCRIPTS, 'firmware_security_encrypt.exe')
WORK = os.path.join(REPO, 'artifacts', 'fwenc')
KEY = bytes(range(16))
NONCE = bytes(range(8))
TWEAK = '0x3039'
PLAIN = bytes(range(64)) * 2


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    if not os.path.isfile(EXE):
        print('SKIP: 缺少参考 firmware_security_encrypt.exe')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    open(os.path.join(WORK, 'key.bin'), 'wb').write(KEY)
    open(os.path.join(WORK, 'nonce.bin'), 'wb').write(NONCE)
    open(os.path.join(WORK, 'in.bin'), 'wb').write(PLAIN)

    cases = [
        ('key+nonce+tweak', ['--key', 'key.bin', '--nonce', 'nonce.bin', '--tweak', TWEAK]),
        ('key+tweak', ['--key', 'key.bin', '--tweak', TWEAK]),
        ('key-only', ['--key', 'key.bin']),
    ]

    fails = 0
    for name, args in cases:
        ref = 'ref_%s.bin' % name.replace('+', '_')
        our = 'our_%s.bin' % name.replace('+', '_')

        r = subprocess.run([EXE] + args + ['--infile', 'in.bin', '--outfile', ref],
                           cwd=WORK, capture_output=True)
        if r.returncode != 0:
            fails += 1
            print('FAIL[%s]: 参考工具失败' % name)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:500])
            continue

        r = subprocess.run([WK, 'image', 'fwenc'] + args +
                           ['--infile', 'in.bin', '--outfile', our, '--tooldir', SCRIPTS],
                           cwd=WORK, capture_output=True)
        if r.returncode != 0:
            fails += 1
            print('FAIL[%s]: wk image fwenc 失败' % name)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:500])
            continue

        a = open(os.path.join(WORK, ref), 'rb').read()
        b = open(os.path.join(WORK, our), 'rb').read()
        if a != b or len(a) != len(PLAIN):
            fails += 1
            print('FAIL[%s]: 产物不一致（ref=%d, ours=%d）' % (name, len(a), len(b)))
        else:
            print('OK[%s]: %d B 逐字节一致（%s）' % (name, len(a), a[:8].hex()))

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
