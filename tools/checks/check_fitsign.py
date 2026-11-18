"""FIT 图像签名对拍（`itb` 条目带 keydir，对应 backlog P1-10 的 RSA 部分）。

参考实现是 SDK 自带的纯 Python `itbimage/_sign.py::sign_images()`：
  * 识别 `images/*/signature-*` 子节点的 `algo`（`sha256,rsa2048`）与 `key-name-hint`；
  * 私钥取 `{keydir}/{key-name-hint}.key`；
  * 对**原始 image data**做 RSASSA-PKCS1-v1.5(SHA-256)，再写 `value` / `signer-name` /
    `signer-version` / `timestamp`。

做法：跑 `mk_image.py -p` 与 `wk image preproc`，比对 FIT 属性（跳过 timestamp）与签名值。
退出码 0 一致；1 有差异或环境缺失。
"""
import os
import shutil
import struct
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
KEYS = os.path.join(SDK, 'target', 'd13x', 'demo88-nor-secure', 'pack', 'keys')
WORK = os.path.join(REPO, 'artifacts', 'fitsign')
FIXTURES = os.path.join(REPO, 'tools', 'checks', 'fixtures')

CFG = 'fitsign.json'
TIMESTAMP = 1700000000
KERNEL = bytes(range(256)) * 6

ITS = '''/dts-v1/;

/ {
    description = "fitsign";
    #address-cells = <1>;

    images {
        kernel-1 {
            description = "kernel";
            data = /incbin/("kernel.bin");
            type = "kernel";
            arch = "riscv";
            os = "linux";
            compression = "none";
            load = <0x40000000>;
            entry = <0x40000000>;

            hash-1 {
                algo = "sha256";
            };

            signature-1 {
                algo = "sha256,rsa2048";
                key-name-hint = "dev";
            };
        };
    };

    configurations {
        default = "conf-1";

        conf-1 {
            kernel = "kernel-1";
        };
    };
};
'''


def skip(msg):
    print('SKIP: ' + msg)
    sys.exit(0)


def fdt_props(blob):
    """把 FDT 结构块拍平成 path/prop=hex（跳过所有 timestamp 属性）。"""
    magic, totalsize, off_struct, off_strings = struct.unpack('>IIII', blob[:16])
    if magic != 0xd00dfeed:
        raise ValueError('not an FDT')
    sb = blob[off_struct:]
    strings = blob[off_strings:]
    out, path, i = [], [], 0
    while True:
        tok = struct.unpack('>I', sb[i:i + 4])[0]
        i += 4
        if tok == 1:
            end = sb.index(b'\0', i)
            path.append(sb[i:end].decode())
            i = (end + 1 + 3) & ~3
        elif tok == 2:
            path.pop()
        elif tok == 3:
            ln, nameoff = struct.unpack('>II', sb[i:i + 8])
            i += 8
            val = sb[i:i + ln]
            i += (ln + 3) & ~3
            end = strings.index(b'\0', nameoff)
            name = strings[nameoff:end].decode()
            if name == 'timestamp':
                continue
            out.append('/'.join(path) + '/' + name + '=' + val.hex())
        elif tok == 4:
            pass
        elif tok == 9:
            break
        else:
            raise ValueError('unknown FDT token %#x' % tok)
    return out


def main():
    if not os.path.isfile(WK):
        skip('wk.exe 不存在（先 zig build）')
    if not os.path.isfile(os.path.join(KEYS, 'rsa_private_key.der')):
        skip('缺少参考 RSA 私钥夹具')

    data = os.path.join(WORK, 'data')
    for d in (data,):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)
    os.makedirs(os.path.join(data, 'keys'), exist_ok=True)

    shutil.copyfile(os.path.join(FIXTURES, CFG), os.path.join(data, CFG))
    with open(os.path.join(data, 'kernel.bin'), 'wb') as f:
        f.write(KERNEL)
    with open(os.path.join(data, 'kernel-signed.its'), 'w', encoding='ascii', newline='\n') as f:
        f.write(ITS)
    # 参考按 `{key-name-hint}.key` 取名，内容可以是 DER（RSA.import_key 两种都吃）
    shutil.copyfile(os.path.join(KEYS, 'rsa_private_key.der'),
                    os.path.join(data, 'keys', 'dev.key'))

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'
    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                        '-c', os.path.join('data', CFG), '-d', 'data/', '-k', 'data/', '-p', '-v'],
                       cwd=WORK, capture_output=True, env=env)
    if r.returncode != 0:
        print('FAIL: 参考 pre-process 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
        return 1
    ref_path = os.path.join(data, 'kernel-signed.itb')
    ref = open(ref_path, 'rb').read()
    os.remove(ref_path)

    r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join('data', CFG),
                        '-d', 'data', '-k', 'data', '--timestamp', str(TIMESTAMP)],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image preproc 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
        return 1
    our = open(ref_path, 'rb').read()

    pa = fdt_props(ref)
    pb = fdt_props(our)
    missing = sorted(set(pa) - set(pb))
    extra = sorted(set(pb) - set(pa))
    fails = 0
    if missing or extra:
        fails += 1
        print('属性差异 missing=%d extra=%d' % (len(missing), len(extra)))
        for x in (missing[:6] + extra[:6]):
            print('  ' + x[:140])

    def sig_value(props):
        return next((x.split('=', 1)[1] for x in props
                    if x.split('=', 1)[0].endswith('/signature-1/value')), None)

    sa, sb2 = sig_value(pa), sig_value(pb)
    print('signature-1/value ref=%s ours=%s' % ((sa or 'None')[:32], (sb2 or 'None')[:32]))
    if not sa or sa != sb2:
        fails += 1
        print('签名值不一致或缺失')

    for want in ('/images/kernel-1/signature-1/algo=',
                 '/images/kernel-1/signature-1/key-name-hint=',
                 '/images/kernel-1/signature-1/signer-name=',
                 '/images/kernel-1/signature-1/signer-version='):
        if not any(x.startswith(want) for x in pa):
            print('提示：参考缺属性 ' + want)

    print('len ref=%d ours=%d' % (len(ref), len(our)))
    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
