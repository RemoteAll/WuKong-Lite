#!/usr/bin/env python3
# -*- coding:utf-8 -*-
"""零差异对拍：同一份输入 + 同一个 FIT timestamp 下，
参考 `mk_image.py` 与我们的 `wk image preproc` + `wk image pack` 产出的 AIC.FW 是否**逐字节相同**。

为什么需要对拍
--------------
两者唯一的不可比项是 FIT 根 `timestamp`：参考由 `int(time.time())` 现取（无法通过参数固定），
我们由 `--timestamp` 指定。因此流程是：
  1. 先跑参考 → 得到参考包，并从它生成的 `.itb` 里读出那次用的 timestamp；
  2. 把工作目录还原成原始中间件，用 `wk image preproc --timestamp <同一个值>` + `wk image pack` 重打；
  3. 逐字节比较两个 `.img`。

判定
----
* 完全相同   → `ZERO-DIFF OK`
* 有任何差异 → 打印差异区间并返回 1（不能只报"不同"，要能定位）

依赖真实 d12x 构建产物（`build/luban-lite/output/d12x_demo68-nor_*/images`）。
缺失时打印 `SKIP: <原因>` 并返回 0 —— 回归里必须显式可见，不得静默跳过。
"""
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
WORK = os.path.join(REPO, 'artifacts', 'zero-diff')
PY = sys.executable

# 参与打包的输入（参考与我们都只读这些；.elf 供 elf2itb 段用）
EXTS = ('.json', '.bin', '.aic', '.pbp', '.itb', '.its', '.lfs', '.fatfs', '.txt', '.elf')

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def fdt_timestamp(data):
    """返回 FIT 根节点的 `timestamp` 属性值。"""
    magic, _total, off_struct, off_strings = struct.unpack_from('>4I', data, 0)
    if magic != 0xD00DFEED:
        raise ValueError('not a FIT/FDT image')
    pos, depth = off_struct, -1
    while pos < len(data):
        (token,) = struct.unpack_from('>I', data, pos)
        pos += 4
        if token == FDT_BEGIN_NODE:
            name_end = data.index(b'\x00', pos)
            depth += 1
            pos = (name_end + 4) & ~3
        elif token == FDT_END_NODE:
            depth -= 1
        elif token == FDT_PROP:
            (length, nameoff) = struct.unpack_from('>2I', data, pos)
            pos += 8
            if depth == 0:
                name_end = data.index(b'\x00', off_strings + nameoff)
                name = data[off_strings + nameoff:name_end]
                if name == b'timestamp' and length == 4:
                    return struct.unpack_from('>I', data, pos)[0]
            pos = (pos + length + 3) & ~3
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
    raise ValueError('root timestamp not found')


def run(argv, cwd=None, env=None):
    proc = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
    return proc.returncode, (proc.stdout or '')


def collect_inputs(dst):
    """把 images 目录里的输入文件复制到 dst（d12x.elf 缺失时从同目录其它 ELF 补）。"""
    src_elf = os.path.join(IMAGES, 'd12x.elf')
    if not os.path.exists(src_elf):
        cands = [f for f in os.listdir(IMAGES) if f.endswith('.elf') and not f.startswith('d12x')]
        if not cands:
            return '没有可用 ELF'
        shutil.copy2(os.path.join(IMAGES, cands[0]), src_elf)
    n = 0
    for name in os.listdir(IMAGES):
        if name.lower().endswith(EXTS):
            shutil.copy2(os.path.join(IMAGES, name), os.path.join(dst, name))
            n += 1
    return n


def zero_diff(box):
    """box: 工作目录；返回 (ok: bool, msg: str)。"""
    bak, work = os.path.join(box, 'bak'), os.path.join(box, 'in')
    shutil.rmtree(box, ignore_errors=True)
    os.makedirs(bak)
    os.makedirs(work)
    n = collect_inputs(bak)
    if isinstance(n, str):
        return None, n
    cfg = os.path.join(work, 'image_cfg.json')

    def reset():
        for f in os.listdir(work):
            os.remove(os.path.join(work, f))
        for f in os.listdir(bak):
            shutil.copy2(os.path.join(bak, f), os.path.join(work, f))

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'

    # 1) 参考打包
    reset()
    code, out = run([PY, os.path.join(SCRIPTS, 'mk_image.py'), '-v', '-c', cfg, '-d', work], env=env)
    ref_imgs = [f for f in os.listdir(work) if f.endswith('.img')]
    if code != 0 or not ref_imgs:
        return False, '参考 mk_image.py 失败(exit %d): %s' % (code, out.strip().replace('\n', ' ')[-200:])
    ref_img = os.path.join(box, 'ref.img')
    shutil.copy2(os.path.join(work, ref_imgs[0]), ref_img)
    # 参考覆盖生成了新的 .itb，从里面取它用的 timestamp
    ts = fdt_timestamp(open(os.path.join(work, 'd12x_os.itb'), 'rb').read())

    # 2) 我们的打包（相同输入 + 相同 timestamp）
    reset()
    code, out = run([WK, 'image', 'preproc', '-c', cfg, '-d', work, '--timestamp', str(ts)])
    if code != 0:
        return False, 'wk image preproc 失败(exit %d): %s' % (code, out.strip().replace('\n', ' ')[-200:])
    zig_img = os.path.join(box, 'zig.img')
    code, out = run([WK, 'image', 'pack', '--config', cfg, '--datadir', work, '-o', zig_img])
    if code != 0:
        return False, 'wk image pack 失败(exit %d): %s' % (code, out.strip().replace('\n', ' ')[-200:])

    # 3) 逐字节比较
    a = open(ref_img, 'rb').read()
    b = open(zig_img, 'rb').read()
    if a == b:
        return True, 'ZERO-DIFF OK  %d B（timestamp=%d）' % (len(a), ts)
    msg = ['尺寸 ref=%d zig=%d' % (len(a), len(b))]
    diffs = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
    msg.append('差异字节 %d' % len(diffs))
    ranges = []
    for i in diffs:
        if ranges and i == ranges[-1][1] + 1:
            ranges[-1][1] = i
        else:
            ranges.append([i, i])
    for s, e in ranges[:8]:
        msg.append('  0x%06X-0x%06X ref=%s zig=%s' % (s, e, a[s:e + 1].hex(), b[s:e + 1].hex()))
    return False, '; '.join(msg)


def main():
    if not os.path.exists(WK):
        print('SKIP: 未找到 %s（先 zig build）' % WK)
        return 0
    if not os.path.isdir(SCRIPTS):
        print('SKIP: 参考 SDK 脚本目录不存在: %s' % SCRIPTS)
        return 0
    if not os.path.isdir(IMAGES):
        print('SKIP: 缺少构建产物: %s' % IMAGES)
        return 0

    ok, msg = zero_diff(WORK)
    if ok is None:
        print('SKIP: %s' % msg)
        return 0
    if ok:
        print(msg)
        shutil.rmtree(WORK, ignore_errors=True)
        return 0
    print('FAIL: %s' % msg)
    return 1


if __name__ == '__main__':
    sys.exit(main())
