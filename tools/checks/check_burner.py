"""burner 量产镜像对拍（`mk_image.py -b/--burner` vs `wk image burner`）。

用**自造配置**覆盖四种布局（均无 updater/pre-process，避免参考脚本的额外依赖）：
  1. `nor_basic`   spi-nor 16 MiB，6 个分区（含显式 offset / "-" 剩余大小），块号 = 偏移/64 KiB；
  2. `nand_1org`   spi-nand 8 MiB，单 `array_organization`，验证 AICP 页表 + is_spl_nand；
  3. `nand_2org`   spi-nand 8 MiB，双 `array_organization`，验证每个组织各出一套产物；
  4. `mmc_basic`   mmc 16 MiB，验证 512 B 扇区块号与 512 KiB 跨块判定。

两边各跑一次，比较 `burner/*` 的文件名集合与逐字节内容。
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
WORK = os.path.join(REPO, 'artifacts', 'burner')

SPL_NOR = 120 * 1024        # 非 64 KiB 对齐，验证块号上取整
SPL_NAND = 100 * 1024       # 50 页 + 1 = 51 项，远小于 202 上限
APP = 300 * 1024


def nor_cfg():
    return {
        'image': {
            'info': {
                'platform': 'd13x',
                'product': 'burner nor',
                'version': '1.2.3',
                'media': {'type': 'spi-nor', 'device_id': 0},
            },
            'updater': {},
            'target': {
                'spl': {'file': 'bootloader.bin', 'attr': ['mtd', 'required'], 'part': ['spl']},
                'env': {'file': 'env.bin', 'attr': ['mtd', 'optional'], 'part': ['env']},
                'os': {'file': 'os.bin', 'attr': ['mtd', 'required'], 'part': ['os']},
                'rodata': {'file': 'rodata.bin', 'attr': ['mtd', 'optional'], 'part': ['rodata']},
                'data': {'file': 'data.bin', 'attr': ['mtd', 'optional'], 'part': ['data']},
            },
        },
        'spi-nor': {
            'size': '16m',
            'partitions': {
                'spl': {'size': '512k'},
                'env': {'size': '128k'},
                'env_r': {'size': '128k'},
                'os': {'size': '2m'},
                'rodata': {'size': '8m', 'offset': '0x500000'},
                'data': {'size': '-'},
            },
        },
    }


def nand_cfg(orgs):
    return {
        'image': {
            'info': {
                'platform': 'd13x',
                'product': 'burner-nand',
                'version': '2.0.0',
                'media': {
                    'type': 'spi-nand',
                    'device_id': 0,
                    'array_organization': orgs,
                    'planes': 1,
                },
            },
            'updater': {},
            'target': {
                'spl': {'file': 'bootloader.bin', 'attr': ['mtd', 'required'], 'part': ['spl']},
                'env': {'file': 'env.bin', 'attr': ['mtd', 'optional'], 'part': ['env']},
                'os': {'file': 'os.bin', 'attr': ['mtd', 'required'], 'part': ['os']},
                'rodata': {'file': 'rodata.bin', 'attr': ['mtd', 'optional'], 'part': ['rodata']},
            },
        },
        'spi-nand': {
            'size': '8m',
            'partitions': {
                'spl': {'size': '1m'},
                'env': {'size': '512k'},
                'os': {'size': '3m'},
                'rodata': {'size': '-'},
            },
        },
    }


def mmc_cfg():
    return {
        'image': {
            'info': {
                'platform': 'd21x',
                'product': 'burner-mmc',
                'version': '0.9',
                'media': {'type': 'mmc', 'device_id': 1},
            },
            'updater': {},
            'target': {
                'spl': {'file': 'bootloader.bin', 'attr': ['mtd', 'required'], 'part': ['spl']},
                'os': {'file': 'os.bin', 'attr': ['mtd', 'required'], 'part': ['os']},
                'data': {'file': 'data.bin', 'attr': ['mtd', 'optional'], 'part': ['data']},
            },
        },
        'mmc': {
            'size': '16m',
            'partitions': {
                'spl': {'size': '1m', 'offset': '0x2000'},
                'os': {'size': '4m'},
                'data': {'size': '-'},
            },
        },
    }


CASES = [
    ('nor_basic', nor_cfg, {'bootloader.bin': SPL_NOR, 'env.bin': 4096, 'os.bin': APP,
                            'rodata.bin': 700 * 1024, 'data.bin': 33 * 1024}),
    ('nand_1org', lambda: nand_cfg([{'page': '2K', 'block': '128K'}]), {
        'bootloader.bin': SPL_NAND, 'env.bin': 4096, 'os.bin': APP, 'rodata.bin': 900 * 1024}),
    ('nand_2org', lambda: nand_cfg([{'page': '2K', 'block': '128K'},
                                    {'page': '4K', 'block': '256K'}]), {
        'bootloader.bin': SPL_NAND, 'env.bin': 4096, 'os.bin': APP, 'rodata.bin': 900 * 1024}),
    ('mmc_basic', mmc_cfg, {'bootloader.bin': 100 * 1024, 'os.bin': APP, 'data.bin': 8192}),
]


def run_case(name, cfg_fn, files):
    case_dir = os.path.join(WORK, name)
    shutil.rmtree(case_dir, ignore_errors=True)
    data = os.path.join(case_dir, 'data')
    ref = os.path.join(case_dir, 'ref')
    ours = os.path.join(case_dir, 'ours')
    for d in (data, ref):
        os.makedirs(d, exist_ok=True)

    cfg = cfg_fn()
    cfg_path = os.path.join(data, 'image_cfg.json')
    with open(cfg_path, 'w', encoding='ascii', newline='\n') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=True)
    for idx, (fname, size) in enumerate(files.items()):
        with open(os.path.join(data, fname), 'wb') as f:
            f.write(bytes([(idx * 37 + 11) & 0xFF]) * size)

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'
    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                        '-c', os.path.join('data', 'image_cfg.json'),
                        '-d', 'data/', '-o', 'ref/', '-b', '-v'],
                       cwd=case_dir, capture_output=True, env=env)
    if r.returncode != 0:
        print('FAIL %s: 参考 burner 失败' % name)
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
        return 1

    r = subprocess.run([WK, 'image', 'burner', '-c', os.path.join('data', 'image_cfg.json'),
                        '-d', 'data', '-o', 'ours'], cwd=case_dir, capture_output=True)
    if r.returncode != 0:
        print('FAIL %s: wk image burner 失败' % name)
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:1200])
        return 1

    ref_dir, our_dir = os.path.join(ref, 'burner'), os.path.join(ours, 'burner')
    if not os.path.isdir(ref_dir) or not os.path.isdir(our_dir):
        print('FAIL %s: burner 目录缺失 ref=%s ours=%s'
              % (name, os.path.isdir(ref_dir), os.path.isdir(our_dir)))
        return 1

    ref_files, our_files = sorted(os.listdir(ref_dir)), sorted(os.listdir(our_dir))
    if ref_files != our_files:
        print('FAIL %s: 文件名不一致\n  ref =%s\n  ours=%s' % (name, ref_files, our_files))
        return 1

    fails = 0
    for f in ref_files:
        a = open(os.path.join(ref_dir, f), 'rb').read()
        b = open(os.path.join(our_dir, f), 'rb').read()
        if a != b:
            diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
            print('FAIL %s/%s: 长度 ref=%d ours=%d，差异 %d B' % (name, f, len(a), len(b), diff))
            fails += 1
        else:
            print('  OK %s/%s (%d B)' % (name, f, len(a)))
    return fails


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    if not os.path.isfile(os.path.join(SCRIPTS, 'mk_image.py')):
        print('SKIP: 参考 mk_image.py 不可用（设置 WK_REF_SDK）')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    fails = 0
    for name, cfg_fn, files in CASES:
        fails += run_case(name, cfg_fn, files)

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
