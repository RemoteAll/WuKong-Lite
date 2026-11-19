"""黑盒探针：`firmware_security_encrypt` 的加密模式判定（研究用，不参与一键回归）。

背景（backlog P1-4）：该工具只有预编译二进制（`tools/scripts/firmware_security_encrypt[.exe]`），
SDK 内无源码。本脚本用「已知明文/密文差分」判定其结构，为等价实现提供依据。

已确认（2026-11-19 实测）：
  * 用法：`-k <16B key> [-n <8B nonce>] [-t <32bit tweak>] -i in -o out`；
  * 输入必须 16 B 对齐（1/15/17 B 直接报错），**无填充**，输出长度 = 输入长度；
  * 翻转第 i 块的一个字节 → 只有第 i 块及**其后**块改变 ⇒ 存在前向链式；
  * 但 `C_i == E(P_i ^ C_{i-1})`（AES-ECB 与 SM4-ECB 都试过）**均不成立** ⇒ 不是朴素 CBC；
  * 同 (key, nonce, tweak) 多次运行输出**完全一致**（确定性，无随机 IV）；
  * 反推首块 IV（`D(C1) ^ P1`）随**明文内容**、**长度**、**key** 变化 ⇒ 首块输入还混入了其它数据。

结论：不是 ECB / 朴素 CBC / 朴素 CTR；下一步要判定「CBC + 每块 tweak」还是「先哈希再 CBC」等结构。
"""
import os
import subprocess
import sys
import tempfile

EXE = os.environ.get(
    'WK_FWENC_EXE',
    r'G:\Code\C\luban-lite\tools\scripts\firmware_security_encrypt.exe',
)
SDK_SCRIPTS = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite') + r'\tools\scripts'
BLOCK = 16


def run_enc(key, plain, nonce=None, tweak=None, work=None):
    work = work or tempfile.mkdtemp(prefix='fwenc_')
    kp = os.path.join(work, 'key.bin')
    ip = os.path.join(work, 'in.bin')
    op = os.path.join(work, 'out.bin')
    open(kp, 'wb').write(key)
    open(ip, 'wb').write(plain)
    if os.path.exists(op):
        os.remove(op)
    cmd = [EXE, '-k', kp, '-i', ip, '-o', op]
    if nonce is not None:
        np = os.path.join(work, 'nonce.bin')
        open(np, 'wb').write(nonce)
        cmd += ['-n', np]
    if tweak is not None:
        cmd += ['-t', str(tweak)]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError((r.stdout + r.stderr).decode('utf-8', 'replace')[:200])
    return open(op, 'rb').read()


def diff_blocks(a, b):
    return [i for i in range(min(len(a), len(b)) // BLOCK)
            if a[i * BLOCK:(i + 1) * BLOCK] != b[i * BLOCK:(i + 1) * BLOCK]]


def aes_chain_ok(key, plain, ct):
    from Cryptodome.Cipher import AES
    ecb = AES.new(key, AES.MODE_ECB)
    out = []
    for i in range(1, len(plain) // BLOCK):
        p = plain[i * BLOCK:(i + 1) * BLOCK]
        prev = ct[(i - 1) * BLOCK:i * BLOCK]
        out.append(ecb.encrypt(bytes(x ^ y for x, y in zip(p, prev))) == ct[i * BLOCK:(i + 1) * BLOCK])
    return out


def main():
    if not os.path.isfile(EXE):
        print('SKIP: 未找到 %s' % EXE)
        return 0
    sys.path.insert(0, SDK_SCRIPTS)

    key = bytes(range(16))
    plain = bytes(range(64))
    nonce = bytes(range(8))
    tweak = 0x3039
    work = tempfile.mkdtemp(prefix='fwenc_probe_')

    base = run_enc(key, plain, nonce, tweak, work)
    print('base ct (%d B): %s' % (len(base), base.hex()))

    for i in (0, 1, 3):
        p = bytearray(plain)
        p[i * BLOCK] ^= 0x01
        print('flip block %d -> changed %s' % (i, diff_blocks(base, run_enc(key, bytes(p), nonce, tweak, work))))

    print('AES-CBC chain holds:', aes_chain_ok(key, plain, base))
    print('deterministic (3x same):',
          len({run_enc(key, plain, nonce, tweak, work).hex() for _ in range(3)}) == 1)

    ivs = set()
    for n in (16, 32, 64, 128):
        p = bytes((i * 3) & 0xFF for i in range(n))
        c = run_enc(key, p, nonce, tweak, work)
        from Cryptodome.Cipher import AES
        d = AES.new(key, AES.MODE_ECB).decrypt(c[:BLOCK])
        ivs.add(bytes(x ^ y for x, y in zip(d, p[:BLOCK])).hex())
    print('recovered first-block IV depends on length:', len(ivs) > 1, sorted(ivs)[:2])

    for n in (1, 15, 17):
        try:
            run_enc(key, bytes(range(n)), nonce, tweak, work)
            print('len %2d -> accepted (unexpected)' % n)
        except RuntimeError as e:
            print('len %2d -> rejected: %s' % (n, str(e)[:60]))
    print('workdir:', work)
    return 0


if __name__ == '__main__':
    sys.exit(main())
