"""FIT 图像加密对拍（`itb` 条目带 keydir，对应 backlog P1-10 的 cipher 部分）。

参考实现是 SDK 自带的纯 Python `itbimage/_cipher.py::cipher_images()`：
  * 识别 `images/*/cipher-*` 子节点的 `algo` / `key-name-hint` / 可选 `iv-name-hint`；
  * `aes128`/`aes192`/`aes256` → AES-CBC + PKCS7（密钥/IV 取 `{keydir}/{hint}.bin`）；
  * `aes-128-ctr` → AES-CTR（128 位大端计数器，无填充）；
  * `chacha20` → 32 字节密钥 / 12 字节 nonce，无填充；
  * 加密后写回 `data`（密文）、`data-size-unciphered`、`iv`，并**再算** hash-* 的 value。

做法：跑 `mk_image.py -p` 与 `wk image preproc`，比对密文、`data-size-unciphered`、`iv`
与重算后的 hash 值；IV 全部由夹具给定（不随机），所以两边必须逐字节一致。
退出码 0 一致；1 有差异或环境缺失。
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
WORK = os.path.join(REPO, 'artifacts', 'fitcipher')
TIMESTAMP = 1700000000
KERNEL = bytes(range(256)) * 3

# 每种算法一条：名称、algo、密钥文件名与长度、IV/nonce 文件名与长度
ALGOS = [
    ('aes128', 'aes128', 'key128', 16, 'iv16', 16),
    ('aes192', 'aes192', 'key192', 24, 'iv16', 16),
    ('aes256', 'aes256', 'key256', 32, 'iv16', 16),
    ('aesctr', 'aes-128-ctr', 'key128', 16, 'iv16', 16),
    ('chacha', 'chacha20', 'key256', 32, 'nonce', 12),
]


def its_text(algo):
    return '''/dts-v1/;

/ {
    description = "fitcipher-%s";
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

            cipher-1 {
                algo = "%s";
                key-name-hint = "%s";
                iv-name-hint = "%s";
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


def fdt_props(blob):
    """FDT 结构块拍平成 path/prop=hex（跳过 timestamp）。"""
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
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    data = os.path.join(WORK, 'data')
    os.makedirs(os.path.join(data, 'keys'), exist_ok=True)

    with open(os.path.join(data, 'kernel.bin'), 'wb') as f:
        f.write(KERNEL)

    keys = {}
    for name, algo, keyfile, keylen, ivfile, ivlen in ALGOS:
        keys.setdefault(keyfile, bytes((i * 7 + 3) & 0xFF for i in range(keylen)))
        keys.setdefault(ivfile, bytes((i * 11 + 5) & 0xFF for i in range(ivlen)))
        with open(os.path.join(data, 'keys', keyfile + '.bin'), 'wb') as f:
            f.write(keys[keyfile])
        with open(os.path.join(data, 'keys', ivfile + '.bin'), 'wb') as f:
            f.write(keys[ivfile])
        with open(os.path.join(data, name + '.its'), 'w', encoding='ascii', newline='\n') as f:
            f.write(its_text(algo).replace('%s', algo, 1) % (algo, keyfile, ivfile))

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'

    fails = 0
    for name, algo, _kf, _kl, _if, _il in ALGOS:
        cfg = {
            'pre-process': {
                'itb': {
                    name + '.itb': {'its': name + '.its', 'keydir': 'keys'},
                },
            },
        }
        cfg_path = os.path.join(data, name + '.json')
        with open(cfg_path, 'w', encoding='ascii', newline='\n') as f:
            json.dump(cfg, f, indent=2)
        itb_path = os.path.join(data, name + '.itb')

        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                            '-c', os.path.join('data', name + '.json'),
                            '-d', 'data/', '-p'],
                           cwd=WORK, capture_output=True, env=env)
        if r.returncode != 0:
            fails += 1
            print('FAIL[%s]: 参考 pre-process 失败' % algo)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
            continue
        ref = open(itb_path, 'rb').read()
        os.remove(itb_path)

        r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join('data', name + '.json'),
                            '-d', 'data', '--timestamp', str(TIMESTAMP)],
                           cwd=WORK, capture_output=True)
        if r.returncode != 0:
            fails += 1
            print('FAIL[%s]: wk image preproc 失败' % algo)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
            continue
        our = open(itb_path, 'rb').read()

        pa, pb = fdt_props(ref), fdt_props(our)
        missing = sorted(set(pa) - set(pb))
        extra = sorted(set(pb) - set(pa))
        if missing or extra:
            fails += 1
            print('FAIL[%s]: 属性差异 missing=%d extra=%d' % (algo, len(missing), len(extra)))
            for x in (missing[:4] + extra[:4]):
                print('   ' + x[:130])
            continue

        def pick(props, suffix):
            return next((x.split('=', 1)[1] for x in props
                         if x.split('=', 1)[0].endswith(suffix)), None)

        def payload(props, blob):
            """取 kernel 数据：优先外部数据段（data-position/data-size），否则内联 data。"""
            pos = pick(props, '/kernel-1/data-position')
            size = pick(props, '/kernel-1/data-size')
            if pos is not None and size is not None:
                p, s = int(pos, 16), int(size, 16)
                return blob[p:p + s]
            d = pick(props, '/kernel-1/data')
            return bytes.fromhex(d) if d else None

        data_ref, data_our = payload(pa, ref), payload(pb, our)
        unc_ref = pick(pa, '/kernel-1/data-size-unciphered')
        unc_our = pick(pb, '/kernel-1/data-size-unciphered')
        iv_ref = pick(pa, '/cipher-1/iv')
        iv_our = pick(pb, '/cipher-1/iv')
        hash_ref = pick(pa, '/hash-1/value')
        hash_our = pick(pb, '/hash-1/value')

        bad = []
        if data_ref != data_our:
            bad.append('密文 ref=%s ours=%s' % (
                (data_ref or b'')[:16].hex(), (data_our or b'')[:16].hex()))
        if unc_ref != unc_our:
            bad.append('data-size-unciphered ref=%s ours=%s' % (unc_ref, unc_our))
        if iv_ref != iv_our:
            bad.append('iv ref=%s ours=%s' % (iv_ref, iv_our))
        if hash_ref != hash_our:
            bad.append('hash-1 ref=%s ours=%s' % (
                (hash_ref or 'None')[:24], (hash_our or 'None')[:24]))
        if len(ref) != len(our):
            bad.append('FIT 长度 ref=%d ours=%d' % (len(ref), len(our)))
        if bad:
            fails += 1
            print('FAIL[%s]: %s' % (algo, '; '.join(bad)))
            continue

        # 密文长度必须符合各算法语义：CBC 补齐到 16 的整数倍，流密码等长
        ct_len = len(data_our)
        extra_len = ct_len - len(KERNEL)
        if algo.startswith('aes') and algo != 'aes-128-ctr':
            if ct_len % 16 or extra_len != 16 - (len(KERNEL) % 16):
                fails += 1
                print('FAIL[%s]: CBC 密文长度异常 %d' % (algo, ct_len))
                continue
        elif extra_len != 0:
            fails += 1
            print('FAIL[%s]: 流密码密文长度应等长（差 %d）' % (algo, extra_len))
            continue
        print('OK[%s]: 密文 %d 字节，hash/iv/未加密长度与参考一致' % (algo, ct_len))

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
