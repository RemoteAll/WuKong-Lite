"""env 分区前缀对拍（MTD / UBI / GPT + 显式 offset）。

覆盖三种媒体（参考 `mk_image.py` 的 `aic_create_parts_for_env()`）：
  * spi-nor  带显式 offset（`@0x4400` 原样输出）
  * spi-nand 带 ubi 卷（含卷 offset）
  * mmc（`GPT=` + `parts_mmc=`）

做法：极简配置只留 `uboot_env`，分别用 `mk_image.py -p` 与 `wk image preproc` 生成 env.bin，
逐字节比对。退出码 0 全一致；1 有差异或环境缺失。
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
WORK = os.path.join(REPO, 'artifacts', 'envparts')
FIXTURES = os.path.join(REPO, 'tools', 'checks', 'fixtures')

CASES = ['envparts_nor.json', 'envparts_nand_ubi.json', 'envparts_mmc.json']
ENV_TXT = 'bootdelay=0\nbootcmd=run distro_bootcmd\nbaudrate=115200\n'


def skip(msg):
    print('SKIP: ' + msg)
    sys.exit(0)


def main():
    if not os.path.isfile(WK):
        skip('wk.exe 不存在（先 zig build）')
    if not os.path.isfile(os.path.join(SCRIPTS, 'mk_image.py')):
        skip('参考 mk_image.py 不可用（设置 WK_REF_SDK）')

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'

    fails = 0
    for cfg in CASES:
        src = os.path.join(FIXTURES, cfg)
        if not os.path.isfile(src):
            print('SKIP: 缺少夹具 ' + cfg)
            continue
        case = os.path.splitext(cfg)[0]
        data = os.path.join(WORK, case)
        shutil.rmtree(data, ignore_errors=True)
        os.makedirs(data, exist_ok=True)
        shutil.copyfile(src, os.path.join(data, cfg))
        with open(os.path.join(data, 'env.txt'), 'w', encoding='ascii', newline='\n') as f:
            f.write(ENV_TXT)

        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                            '-c', os.path.join(case, cfg), '-d', case + '/', '-k', case + '/', '-p'],
                           cwd=WORK, capture_output=True, env=env)
        if r.returncode != 0:
            print('FAIL: 参考 pre-process 失败 %s' % cfg)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:600])
            fails += 1
            continue
        ref_env = open(os.path.join(data, 'env.bin'), 'rb').read()
        os.remove(os.path.join(data, 'env.bin'))

        r = subprocess.run([WK, 'image', 'preproc', '-c', os.path.join(case, cfg),
                            '-d', case, '-k', case], cwd=WORK, capture_output=True)
        if r.returncode != 0:
            print('FAIL: wk image preproc 失败 %s' % cfg)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:600])
            fails += 1
            continue
        our_env = open(os.path.join(data, 'env.bin'), 'rb').read()

        same = ref_env == our_env
        print('%-24s %s len=%d/%d' % (cfg, 'OK  ' if same else 'DIFF', len(ref_env), len(our_env)))
        if not same:
            fails += 1
            first = next((i for i, (a, b) in enumerate(zip(ref_env, our_env)) if a != b), None)
            print('  first diff=%s' % first)
            print('  ref: %r' % ref_env[4:120])
            print('  our: %r' % our_env[4:120])

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
