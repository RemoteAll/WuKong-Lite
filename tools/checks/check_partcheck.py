"""`partition_check.py` 对拍（参考 vs `wk image partcheck`）。

覆盖 6 个场景（配置用纯 ASCII 自造，避免 SDK 配置的行尾注释差异）：
  1. `empty`    组件文件都不存在 → 逐条 `Skip ...: not measurable` + `Nothing to check`（**不出表格**）
  2. `half`     占用约 50% → 正常表格
  3. `overflow` 占用约 125% → 表格 + `Partition overflow`；`--strict` 退出码 1
  4. `badsize`  分区尺寸写成 `8x` → `Unrecognized size: 8x`
  5. `nomedia`  配置里没有对应 media 段 → `No media section for type 'spi-nor'`
  6. `ubi`      UBI 卷容量优先于容器
比较 stdout **字节**（含 ANSI 颜色码）与退出码。

退出码：0 全部一致；1 有差异或环境缺失。
"""
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
WORK = os.path.join(REPO, 'artifacts', 'partcheck-check')


def base_cfg():
    return {
        'image': {
            'info': {
                'platform': 'd13x',
                'product': 'partcheck',
                'version': '1.0.0',
                'media': {'type': 'spi-nor', 'device_id': 0},
            },
            'updater': {},
            'target': {
                'spl': {'file': 'bootloader.bin', 'attr': ['mtd', 'required'], 'part': ['spl']},
                'os': {'file': 'os.bin', 'attr': ['mtd', 'required'], 'part': ['os']},
                'data': {'file': 'data.bin', 'attr': ['mtd', 'optional'], 'part': ['data']},
            },
        },
        'spi-nor': {
            'size': '16m',
            'partitions': {
                'spl': {'size': '512k'},
                'os': {'size': '2m'},
                'data': {'size': '1m'},
            },
        },
    }


def write_case(name, cfg, files):
    d = os.path.join(WORK, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    with open(os.path.join(d, 'image_cfg.json'), 'w', encoding='ascii', newline='\n') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=True)
    for fname, size in files.items():
        with open(os.path.join(d, fname), 'wb') as f:
            f.write(bytes([size & 0xFF]) * size)
    return d


def run(cmd, cwd):
    env = dict(os.environ)
    env['PYTHONIOENCODING'] = 'utf-8'
    return subprocess.run(cmd, cwd=cwd, capture_output=True, env=env)


def compare(name, extra_args, case_dir):
    r = run([sys.executable, os.path.join(SCRIPTS, 'partition_check.py'),
             '-c', 'image_cfg.json', '-d', '.'] + extra_args, case_dir)
    o = run([WK, 'image', 'partcheck', '-c', 'image_cfg.json', '-d', '.'] + extra_args, case_dir)

    fails = 0
    if r.returncode != o.returncode:
        print('FAIL %s: 退出码 ref=%d ours=%d' % (name, r.returncode, o.returncode))
        fails += 1
    if r.stdout != o.stdout:
        fails += 1
        print('FAIL %s: stdout 不一致（ref=%d B, ours=%d B）'
              % (name, len(r.stdout), len(o.stdout)))
        rl = r.stdout.replace(b'\x1b', b'<ESC>').splitlines()
        ol = o.stdout.replace(b'\x1b', b'<ESC>').splitlines()
        for i in range(max(len(rl), len(ol))):
            x = rl[i] if i < len(rl) else b'<none>'
            y = ol[i] if i < len(ol) else b'<none>'
            if x != y:
                print('  line %d:\n    ref = %r\n    ours= %r' % (i + 1, x, y))
                break
    if fails == 0:
        print('  OK %s（%d 行, rc=%d）' % (name, len(r.stdout.splitlines()), r.returncode))
    return fails


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    if not os.path.isfile(os.path.join(SCRIPTS, 'partition_check.py')):
        print('SKIP: 参考 partition_check.py 不可用（设置 WK_REF_SDK）')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    fails = 0

    # 1) 空：没有任何组件文件
    d = write_case('empty', base_cfg(), {})
    fails += compare('empty', ['-v'], d)

    # 2) 50%：os 用掉 1 MiB / 2 MiB
    d = write_case('half', base_cfg(), {'bootloader.bin': 64 * 1024, 'os.bin': 1024 * 1024})
    fails += compare('half', ['-v'], d)

    # 3) 125%：os 用掉 2.5 MiB / 2 MiB
    d = write_case('overflow', base_cfg(), {'bootloader.bin': 64 * 1024, 'os.bin': 2560 * 1024})
    fails += compare('overflow', ['-v'], d)
    fails += compare('overflow-strict', ['-v', '--strict'], d)

    # 4) 无法识别的大小
    cfg = base_cfg()
    cfg['spi-nor']['partitions']['os']['size'] = '8x'
    d = write_case('badsize', cfg, {'bootloader.bin': 64 * 1024, 'os.bin': 1024 * 1024})
    fails += compare('badsize', ['-v'], d)

    # 5) 配置里没有 media 段
    cfg = base_cfg()
    cfg['image']['info']['media']['type'] = 'spi-nand'
    d = write_case('nomedia', cfg, {'bootloader.bin': 64 * 1024, 'os.bin': 1024 * 1024})
    fails += compare('nomedia', ['-v'], d)

    # 6) UBI 卷：卷有固定大小则优先于容器
    cfg = {
        'image': {
            'info': {
                'platform': 'd13x',
                'product': 'ubi',
                'version': '1.0.0',
                'media': {'type': 'spi-nand', 'device_id': 0},
            },
            'updater': {},
            'target': {
                'rootfs': {'file': 'rootfs.ubi', 'attr': ['ubi', 'required'], 'part': ['ubisystem:rootfs']},
            },
        },
        'spi-nand': {
            'size': '64m',
            'partitions': {
                'ubisystem': {'size': '32m', 'ubi': {'rootfs': {'size': '16m'}}},
            },
        },
    }
    d = write_case('ubi', cfg, {'rootfs.ubi': 4 * 1024 * 1024})
    fails += compare('ubi', ['-v'], d)

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
