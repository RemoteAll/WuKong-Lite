"""`pre-process` 的 `elf2itb` 段对拍（参考 `mk_image.py -p` vs `wk image preproc`）。

参考语义（`mk_image.py:2877 firmware_component_preproc_elf2itb()`）：
  配置项 `"<name>.itb": { "elf": "...", "hash": [...] }`
  → `<name>.its` 由 ELF 现场生成（`elf2image.elf2its`，description 固定 "Luban-lite firmware"）
  → `itb_create_image()` = `build_itb(external_data=True, block_align=0x800)`
  → 段数据 `seg0.bin` 落在 ITS 同目录。

对拍口径：
  * `*.its`   → **逐字节**（参考以文本模式写文件，Windows 上是 CRLF）
  * `seg*.bin`→ **逐字节**
  * `*.itb`   → 逐字节，但参考的 FIT `timestamp` 来自 `int(time.time())`
                （`itbimage/_core.py:90`，无法固定），故把该 4 字节属性值替换成参考值后再比

依赖真实 d12x 构建产物（`build/luban-lite/output/d12x_*/images` 的 `image_cfg.json` + `d12x.elf`）。
产物不存在时打印 `SKIP: <原因>` 并返回 0（回归里必须显式可见，不得静默跳过）。
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
IMAGES = os.path.join(REPO, 'build', 'luban-lite', 'output',
                      'd12x_demo68-nor_rt-thread_helloworld', 'images')
WORK = os.path.join(REPO, 'artifacts', 'elf2itb')

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def fdt_timestamp(data):
    """返回 (根节点 `timestamp` 属性值偏移, 取值)。"""
    magic, _total, off_struct, off_strings = struct.unpack_from('>4I', data, 0)
    if magic != 0xD00DFEED:
        raise ValueError('not a FIT/FDT image')
    pos, depth = off_struct, -1
    while pos < len(data):
        (token,) = struct.unpack_from('>I', data, pos)
        pos += 4
        if token == FDT_BEGIN_NODE:
            pos = (data.index(b'\0', pos) + 4) & ~3
            depth += 1
        elif token == FDT_END_NODE:
            depth -= 1
        elif token == FDT_NOP:
            continue
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from('>II', data, pos)
            pos += 8
            val_off = pos
            pos = (pos + length + 3) & ~3
            name = data[off_strings + nameoff:data.index(b'\0', off_strings + nameoff)]
            if depth == 0 and name == b'timestamp' and length == 4:
                return val_off, struct.unpack_from('>I', data, val_off)[0]
        elif token == FDT_END:
            break
    raise ValueError('timestamp property not found')


def load_jsonc(path):
    """读带注释的 JSON（`image_cfg.json` 里有 `//` 与 `/* */`，我们的 `image_cfg.zig` 同样支持）。"""
    text = open(path, encoding='utf-8').read()
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if text.startswith('//', i):
            while i < n and text[i] != '\n':
                i += 1
            continue
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    # 去掉注释后可能出现尾随逗号（`"spl_cfg.bin": {...},\n // 注释行 \n }`），换掉才能给 json 模块
    return json.loads(re.sub(r',(\s*[}\]])', r'\1', ''.join(out)))


def main():
    cfg_src = os.path.join(IMAGES, 'image_cfg.json')
    elf_src = os.path.join(IMAGES, 'd12x.elf')
    if not os.path.isfile(cfg_src):
        print('SKIP: 缺少 d12x 构建产物 %s（先跑 tools\\build-d12x-firmware.ps1 -SkipPack）' % cfg_src)
        return 0
    if not os.path.isfile(elf_src):
        print('SKIP: 缺少 %s（d12x 构建未完成）' % elf_src)
        return 0
    if not os.path.isfile(WK):
        print('FAIL: 缺少 %s（先 zig build）' % WK)
        return 1

    cfg = load_jsonc(cfg_src)
    # 顶层 `pre-process`（与 `image` 平级，见 image_cfg.json 第 69 行附近）
    pre = cfg.get('pre-process') or {}
    kept = {k: v for k, v in pre.items() if k == 'elf2itb'}
    if not kept:
        print('SKIP: %s 的 pre-process 没有 elf2itb 段' % cfg_src)
        return 0
    cfg['pre-process'] = kept
    itb_names = list(kept['elf2itb'].keys())
    seg_bins = ['seg%d.bin' % i for i in range(len(itb_names) + 1)]

    data = os.path.join(WORK, 'data')
    ref = os.path.join(WORK, 'ref')
    for d in (data, ref):
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    shutil.copy2(elf_src, os.path.join(data, 'd12x.elf'))
    with open(os.path.join(data, 'image_cfg.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(cfg, f, indent=4)

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'
    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                        '-c', os.path.join('data', 'image_cfg.json'), '-d', 'data/', '-k', 'data/', '-p', '-v'],
                       cwd=WORK, capture_output=True, env=env)
    if r.returncode != 0:
        print('FAIL: 参考 pre-process 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1500])
        return 1
    outs = itb_names + [n[:-4] + '.its' for n in itb_names] + seg_bins
    for n in outs:
        p = os.path.join(data, n)
        if os.path.isfile(p):
            shutil.move(p, os.path.join(ref, n))

    # 参考的 FIT timestamp 取墙钟，把它的实际值喂给 wk，两边才能逐字节比（不留归一化兜底给主路径）
    ts_args = []
    ref_itb = os.path.join(ref, itb_names[0])
    if os.path.isfile(ref_itb):
        try:
            ts_args = ['--timestamp', str(fdt_timestamp(open(ref_itb, 'rb').read())[1])]
        except ValueError:
            pass

    r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join('data', 'image_cfg.json'),
                        '-d', 'data', '-k', 'data'] + ts_args, cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image preproc 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
        return 1
    print((r.stdout + r.stderr).decode('utf-8', 'replace').strip())

    fails = 0
    for n in outs:
        a_path, b_path = os.path.join(ref, n), os.path.join(data, n)
        if not os.path.isfile(a_path):
            print('%-16s SKIP: 参考未产出' % n)
            continue
        if not os.path.isfile(b_path):
            print('%-16s FAIL: 我们未产出' % n)
            fails += 1
            continue
        a, b = open(a_path, 'rb').read(), open(b_path, 'rb').read()
        note = ''
        if n.endswith('.itb') and a != b:
            try:
                off_a, ts_a = fdt_timestamp(a)
                off_b, ts_b = fdt_timestamp(b)
                if off_a == off_b:
                    b = b[:off_b] + struct.pack('>I', ts_a) + b[off_b + 4:]
                    note = '（FIT timestamp %d→%d 归一后比）' % (ts_b, ts_a)
            except ValueError as exc:
                note = '(%s)' % exc
        if a == b:
            print('%-16s OK   %d B%s' % (n, len(a), note))
        else:
            fails += 1
            diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
            first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), None)
            print('%-16s DIFF len=%d/%d diff=%d first=%s' % (n, len(a), len(b), diff, first))

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
