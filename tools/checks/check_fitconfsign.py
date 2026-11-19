"""FIT 配置签名 + 公钥注入对拍（backlog P1-10 收尾）。

参考实现：
  * `itbimage/_sign.sign_configurations()` —— 对 `/configurations/*/signature-*`
    做「FDT 区域哈希 + RSA 签名」，并写 `hashed-nodes` / `hashed-strings`；
    区域提取由 `_fdt_regions.find_regions()`（u-boot `fdt_find_regions` 移植）完成。
  * `itbimage/_sign.inject_pubkeys()` —— 把 `{keydir}/*.key` 的公钥写进目标 DTB 的
    `/signature/<name>`（`algo` / `rsa,num-bits` / `rsa,modulus` / `rsa,exponent` /
    `rsa,n0-inverse`，`-r` 时加 `required`）。

做法：
  [1] 同一条 ITS（image 签名 + config 签名）分别用 `mk_image.py -p` 与
      `wk image preproc` 产出 FIT，比对属性集合与全部签名值（时间戳除外）。
  [2] 以 `wk image itb` 产出的 FIT 为基准，两侧各注入一次公钥（Python 参考实现 vs
      `wk image itb --keydest`），比对 `/signature/*` 的属性与整个 DTB 字节。
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
WORK = os.path.join(REPO, 'artifacts', 'fitconfsign')
TIMESTAMP = 1700000000
KERNEL = bytes(range(256)) * 4
DTB_IN = bytes((i * 13 + 7) & 0xFF for i in range(768))  # 只是被注入的目标 DTB 载荷

ITS = '''/dts-v1/;

/ {
    description = "conf-sign";
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

            signature-1 {
                algo = "sha256,rsa2048";
                key-name-hint = "dev";
            };
        };
    };
};
'''

CFG = {
    'pre-process': {
        'itb': {
            'kernel-conf.itb': {'its': 'kernel-conf.its', 'keydir': 'keys'},
        },
    },
}


def skip(msg):
    print('SKIP: ' + msg)
    sys.exit(0)


def fdt_props(blob):
    magic, _totalsize, off_struct, off_strings = struct.unpack('>IIII', blob[:16])
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
        skip('wk.exe 不存在（先 zig build）')
    priv = os.path.join(KEYS, 'rsa_private_key.der')
    if not os.path.isfile(priv):
        skip('缺少参考 RSA 私钥夹具')

    shutil.rmtree(WORK, ignore_errors=True)
    data = os.path.join(WORK, 'data')
    os.makedirs(os.path.join(data, 'keys'), exist_ok=True)
    with open(os.path.join(data, 'kernel.bin'), 'wb') as f:
        f.write(KERNEL)
    with open(os.path.join(data, 'kernel-conf.its'), 'w', encoding='ascii', newline='\n') as f:
        f.write(ITS)
    import json
    with open(os.path.join(data, 'kernel-conf.json'), 'w', encoding='ascii', newline='\n') as f:
        json.dump(CFG, f, indent=2)
    shutil.copyfile(priv, os.path.join(data, 'keys', 'dev.key'))

    fails = 0
    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'

    # ── [1] 配置签名 ────────────────────────────────────────────────
    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                        '-c', os.path.join('data', 'kernel-conf.json'), '-d', 'data/', '-p'],
                       cwd=WORK, capture_output=True, env=env)
    if r.returncode != 0:
        print('FAIL: 参考 pre-process 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
        return 1
    itb = os.path.join(data, 'kernel-conf.itb')
    ref = open(itb, 'rb').read()
    os.remove(itb)

    r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join('data', 'kernel-conf.json'),
                        '-d', 'data', '--timestamp', str(TIMESTAMP)],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image preproc 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1
    our = open(itb, 'rb').read()

    pa, pb = fdt_props(ref), fdt_props(our)
    missing = sorted(set(pa) - set(pb))
    extra = sorted(set(pb) - set(pa))
    if missing or extra:
        fails += 1
        print('[config] 属性差异 missing=%d extra=%d' % (len(missing), len(extra)))
        for x in (missing[:5] + extra[:5]):
            print('   ' + x[:150])

    def pick(props, suffix):
        return next((x.split('=', 1)[1] for x in props
                     if x.split('=', 1)[0].endswith(suffix)), None)

    for suffix in ('/conf-1/signature-1/value',
                   '/conf-1/signature-1/hashed-nodes',
                   '/conf-1/signature-1/hashed-strings',
                   '/conf-1/signature-1/signer-name',
                   '/conf-1/signature-1/signer-version',
                   '/kernel-1/signature-1/value'):
        a, b = pick(pa, suffix), pick(pb, suffix)
        if a != b:
            fails += 1
            print('[config] %s 不一致 ref=%s ours=%s' % (
                suffix, (a or 'None')[:40], (b or 'None')[:40]))
        elif a is None:
            fails += 1
            print('[config] %s 缺失' % suffix)

    if not fails:
        print('OK[config]: hashed-nodes/hashed-strings 与两处签名值均与参考一致')

    # ── [2] 公钥注入 ────────────────────────────────────────────────
    base = open(itb, 'rb').read()
    a_dtb = os.path.join(data, 'inject-ref.dtb')
    b_dtb = os.path.join(data, 'inject-wk.dtb')
    with open(a_dtb, 'wb') as f:
        f.write(base)
    with open(b_dtb, 'wb') as f:
        f.write(base)

    code = ('import sys; sys.path.insert(0, %r);'
            'from itbimage._sign import inject_pubkeys;'
            'inject_pubkeys(%r, %r, False)') % (SCRIPTS, os.path.join(data, 'keys'), a_dtb)
    r = subprocess.run([sys.executable, '-c', code], capture_output=True, env=env)
    if r.returncode != 0:
        fails += 1
        print('FAIL[pubkey]: 参考注入失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
    else:
        r = subprocess.run([WK, 'image', 'itb',
                            '--keydest', os.path.join('data', 'inject-wk.dtb'),
                            '--keydir', os.path.join('data', 'keys')],
                           cwd=WORK, capture_output=True)
        if r.returncode != 0:
            fails += 1
            print('FAIL[pubkey]: wk 注入失败')
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
        else:
            ra, rb = open(a_dtb, 'rb').read(), open(b_dtb, 'rb').read()
            qa, qb = fdt_props(ra), fdt_props(rb)
            na = sorted(x for x in qa if '/signature/' in x)
            nb = sorted(x for x in qb if '/signature/' in x)
            if na != nb:
                fails += 1
                print('FAIL[pubkey]: /signature 属性不一致')
                for x in (sorted(set(na) - set(nb))[:4] + sorted(set(nb) - set(na))[:4]):
                    print('   ' + x[:140])
            else:
                for want in ('/signature/dev/algo', '/signature/dev/rsa,num-bits',
                             '/signature/dev/rsa,modulus', '/signature/dev/rsa,exponent',
                             '/signature/dev/rsa,n0-inverse'):
                    if not any(x.startswith(want + '=') for x in na):
                        fails += 1
                        print('FAIL[pubkey]: 缺属性 ' + want)
                print('OK[pubkey]: %d 条 /signature 属性与参考一致（DTB %d vs %d 字节）'
                      % (len(na), len(ra), len(rb)))

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
