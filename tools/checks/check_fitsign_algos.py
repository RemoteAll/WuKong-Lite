"""FIT 签名多哈希档对拍（sha1 / sha256 / sha384 / sha512）。

参考 `itbimage/_sign.py` 的 `_parse_algo` 决定哈希档：
  * 图像签名 `sign_images()` —— 对 image data 做 `<hash>` 再 RSA PKCS#1 v1.5 签名；
  * 配置签名 `sign_configurations()` —— 先用 `<hash>` 算区域哈希，再用同一档再哈希一次签名。

本脚本对四个档位各跑一遍 `mk_image.py -p` 与 `wk image preproc`，
比对除 timestamp 外的全部属性（含两处签名值）。退出码 0 一致。
"""
import json
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
WORK = os.path.join(REPO, 'artifacts', 'fitsignalgos')
TIMESTAMP = 1700000000
KERNEL = bytes(range(256)) * 4

HASHES = ['sha1', 'sha256', 'sha384', 'sha512']

ITS = '''/dts-v1/;

/ {
    description = "algos-%(hash)s";
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
                algo = "%(hash)s";
            };

            signature-1 {
                algo = "%(hash)s,rsa2048";
                key-name-hint = "dev";
            };
        };
    };

    configurations {
        default = "conf-1";

        conf-1 {
            kernel = "kernel-1";

            signature-1 {
                algo = "%(hash)s,rsa2048";
                key-name-hint = "dev";
            };
        };
    };
};
'''


def fdt_props(blob):
    magic, _t, off_struct, off_strings = struct.unpack('>IIII', blob[:16])
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
            if name != 'timestamp':
                out.append('/'.join(path) + '/' + name + '=' + val.hex())
        elif tok in (4, 8):
            pass
        elif tok == 9:
            break
        else:
            raise ValueError('unknown FDT token %#x' % tok)
    return out


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    priv = os.path.join(KEYS, 'rsa_private_key.der')
    if not os.path.isfile(priv):
        print('SKIP: 缺少参考 RSA 私钥夹具')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    data = os.path.join(WORK, 'data')
    os.makedirs(os.path.join(data, 'keys'), exist_ok=True)
    with open(os.path.join(data, 'kernel.bin'), 'wb') as f:
        f.write(KERNEL)
    shutil.copyfile(priv, os.path.join(data, 'keys', 'dev.key'))

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'

    fails = 0
    for h in HASHES:
        name = 'kernel-' + h
        with open(os.path.join(data, name + '.its'), 'w', encoding='ascii', newline='\n') as f:
            f.write(ITS % {'hash': h})
        cfg = {'pre-process': {'itb': {name + '.itb': {'its': name + '.its', 'keydir': 'keys'}}}}
        with open(os.path.join(data, name + '.json'), 'w', encoding='ascii', newline='\n') as f:
            json.dump(cfg, f, indent=2)

        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                            '-c', os.path.join('data', name + '.json'),
                            '-d', 'data/', '-p'],
                           cwd=WORK, capture_output=True, env=env)
        if r.returncode != 0:
            fails += 1
            print('FAIL[%s]: 参考 pre-process 失败' % h)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
            continue
        itb = os.path.join(data, name + '.itb')
        ref = open(itb, 'rb').read()
        os.remove(itb)

        r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join('data', name + '.json'),
                            '-d', 'data', '--timestamp', str(TIMESTAMP)],
                           cwd=WORK, capture_output=True)
        if r.returncode != 0:
            fails += 1
            print('FAIL[%s]: wk image preproc 失败' % h)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
            continue
        our = open(itb, 'rb').read()

        pa, pb = fdt_props(ref), fdt_props(our)
        missing = sorted(set(pa) - set(pb))
        extra = sorted(set(pb) - set(pa))
        if missing or extra:
            fails += 1
            print('FAIL[%s]: 属性差异 missing=%d extra=%d' % (h, len(missing), len(extra)))
            for x in (missing[:4] + extra[:4]):
                print('   ' + x[:140])
            continue

        # 三处哈希/签名值都必须逐字节一致
        def pick(props, suffix):
            return next((x.split('=', 1)[1] for x in props
                         if x.split('=', 1)[0].endswith(suffix)), None)

        bad = []
        for suffix in ('/hash-1/value', '/kernel-1/signature-1/value',
                       '/conf-1/signature-1/value', '/conf-1/signature-1/hashed-strings'):
            a, b = pick(pa, suffix), pick(pb, suffix)
            if a != b:
                bad.append('%s ref=%s ours=%s' % (
                    suffix, (a or 'None')[:26], (b or 'None')[:26]))
        if bad:
            fails += 1
            print('FAIL[%s]: %s' % (h, '; '.join(bad)))
            continue
        print('OK[%s]: hash-1/signature-1/conf-signature 与参考逐字节一致' % h)

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
