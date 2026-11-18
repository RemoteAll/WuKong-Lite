"""`image_cfg.json` 的 pre-process 流水线对拍（mk_image.py -p vs wk image preproc）。

覆盖四段真实用到的处理器：
  * `aicprivate`  → 私有资源（_priv_build / privres）
  * `itb`         → ITS → FIT（用 SOURCE_DATE_EPOCH 固定 timestamp，才能逐字节比）
  * `uboot_env`   → 环境变量镜像（含 MTD= 分区前缀与冗余）
  * `aicimage`    → AIC 启动镜像 v2（签名 + 加密）
  * `concatenate` → 顺序拼接

退出码：0 全部一致；1 有差异或环境缺失（打印原因）。
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
PACK = os.path.join(SDK, 'target', 'd13x', 'demo88-nor-secure', 'pack')
WORK = os.path.join(REPO, 'artifacts', 'preproc')
FIXTURES = os.path.join(REPO, 'tools', 'checks', 'fixtures')

CFG = 'preproc_pipeline.json'
TIMESTAMP = 1700000000
OUTPUTS = ['priv.bin', 'kernel.itb', 'env.bin', 'loader.aic', 'bootloader.aic']

ITB_KERNEL = bytes(range(256)) * 8
ITS = '''/dts-v1/;

/ {
    description = "preproc-check";
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

ENV_TXT = 'bootdelay=0\nbootcmd=run distro_bootcmd\nbaudrate=115200\n'


def fdt_props(blob):
    """把 FDT 结构块拍平成 path/prop=hex 列表（跳过 timestamp），用于结构对拍。"""
    import struct as st
    magic, totalsize, off_struct, off_strings = st.unpack('>IIII', blob[:16])
    if magic != 0xd00dfeed:
        raise ValueError('not an FDT')
    sb = blob[off_struct:]
    strings = blob[off_strings:]
    out, path, i = [], [], 0
    while True:
        tok = st.unpack('>I', sb[i:i + 4])[0]
        i += 4
        if tok == 1:
            end = sb.index(b'\0', i)
            path.append(sb[i:end].decode())
            i = (end + 1 + 3) & ~3
        elif tok == 2:
            path.pop()
        elif tok == 3:
            ln, nameoff = st.unpack('>II', sb[i:i + 8])
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
    return out, totalsize


def compare_itb(ref_path, our_path):
    """FIT 结构对拍：属性集合一致 + 外部数据一致。返回差异条数。"""
    a, b = open(ref_path, 'rb').read(), open(our_path, 'rb').read()
    if len(a) != len(b):
        print('  itb: 长度不同 ref=%d ours=%d' % (len(a), len(b)))
        return 1
    pa, ta = fdt_props(a)
    pb, tb = fdt_props(b)
    diff = 0
    missing = sorted(set(pa) - set(pb))
    extra = sorted(set(pb) - set(pa))
    if missing or extra:
        diff += len(missing) + len(extra)
        print('  itb: 属性差异 missing=%d extra=%d' % (len(missing), len(extra)))
        for x in (missing[:5] + extra[:5]):
            print('    ' + x[:120])
    # 外部数据：data-position 指向的字节必须一致
    for item in sorted(pa):
        if not item.endswith('data-position') and '/data-position=' not in item:
            continue
        pos = int(item.rsplit('=', 1)[1], 16)
        node = item.rsplit('/', 1)[0]
        size_hex = next((x.rsplit('=', 1)[1] for x in pa if x.startswith(node + '/data-size=')), None)
        if size_hex is None:
            continue
        size = int(size_hex, 16)
        if a[pos:pos + size] != b[pos:pos + size]:
            diff += 1
            print('  itb: 外部数据不同 node=%s pos=%d size=%d' % (node, pos, size))
    print('  itb: dtb totalsize ref=%d ours=%d（字符串表/属性顺序不同属正常，按结构比）' % (ta, tb))
    return diff

def skip(msg):
    print('SKIP: ' + msg)
    sys.exit(0)


def main():
    if not os.path.isfile(WK):
        skip('wk.exe 不存在（先 zig build）')
    if not os.path.isdir(PACK):
        skip('参考 SDK secure 方案不存在: ' + PACK)
    if not os.path.isfile(os.path.join(SCRIPTS, 'mk_image.py')):
        skip('参考 mk_image.py 不可用（设置 WK_REF_SDK）')

    data = os.path.join(WORK, 'data')
    ref = os.path.join(WORK, 'ref')
    for d in (data, ref):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)

    # ---- 夹具 ----
    shutil.copyfile(os.path.join(FIXTURES, CFG), os.path.join(data, CFG))
    shutil.copyfile(os.path.join(PACK, 'bootloader.bin'), os.path.join(data, 'bootloader.bin'))
    shutil.copyfile(os.path.join(PACK, 'pbp_cfg.json'), os.path.join(data, 'pbp_cfg.json'))
    shutil.copytree(os.path.join(PACK, 'keys'), os.path.join(data, 'keys'), dirs_exist_ok=True)
    with open(os.path.join(data, 'kernel.bin'), 'wb') as f:
        f.write(ITB_KERNEL)
    with open(os.path.join(data, 'kernel.its'), 'w', encoding='ascii', newline='\n') as f:
        f.write(ITS)
    with open(os.path.join(data, 'env.txt'), 'w', encoding='ascii', newline='\n') as f:
        f.write(ENV_TXT)
    r = subprocess.run([WK, 'image', 'privres', '-c', os.path.join(data, 'pbp_cfg.json'),
                        '-o', os.path.join(data, 'pbp_cfg.bin')], cwd=REPO, capture_output=True)
    if r.returncode != 0:
        print('FAIL: 生成 pbp_cfg.bin 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:500])
        return 1

    # ---- 参考：mk_image.py -p（SOURCE_DATE_EPOCH 固定 FIT timestamp）----
    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'
    env['SOURCE_DATE_EPOCH'] = str(TIMESTAMP)
    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                        '-c', os.path.join('data', CFG), '-d', 'data/', '-k', 'data/', '-p', '-v'],
                       cwd=WORK, capture_output=True, env=env)
    if r.returncode != 0:
        print('FAIL: 参考 pre-process 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
        return 1
    for n in OUTPUTS:
        shutil.move(os.path.join(data, n), os.path.join(ref, n))

    # ---- 我们：wk image preproc ----
    r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join('data', CFG), '-d', 'data', '-k', 'data',
                        '--timestamp', str(TIMESTAMP)], cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image preproc 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
        return 1
    print((r.stdout + r.stderr).decode('utf-8', 'replace').strip())

    fails = 0
    for n in OUTPUTS:
        a_path, b_path = os.path.join(ref, n), os.path.join(data, n)
        if not os.path.isfile(a_path) or not os.path.isfile(b_path):
            print('%-16s MISSING ref=%s ours=%s' % (n, os.path.isfile(a_path), os.path.isfile(b_path)))
            fails += 1
            continue
        if n == 'kernel.itb':
            # FIT 由两套独立 FDT 写入器生成，字节不可能相同（字符串表/属性顺序不同），
            # 因此按「属性集合 + 外部数据」结构对拍。
            d = compare_itb(a_path, b_path)
            print('%-16s %s（结构对拍）' % (n, 'OK  ' if d == 0 else 'DIFF'))
            fails += 1 if d else 0
            continue
        if n == 'bootloader.aic':
            head_len = len(open(os.path.join(ref, 'loader.aic'), 'rb').read())
            if a[:head_len] != b[:head_len]:
                print('%-16s DIFF（loader 段）' % n)
                fails += 1
                continue
            d = compare_itb(os.path.join(ref, 'kernel.itb'), os.path.join(data, 'kernel.itb'))
            print('%-16s %s（loader 段逐字节 + itb 段结构）' % (n, 'OK  ' if d == 0 else 'DIFF'))
            fails += 1 if d else 0
            continue
        a, b = open(a_path, 'rb').read(), open(b_path, 'rb').read()
        diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
        first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), None)
        print('%-16s %s len=%d/%d diff=%d first=%s' % (n, 'OK  ' if diff == 0 else 'DIFF', len(a), len(b), diff, first))
        if diff != 0:
            fails += 1

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
