"""AIC 启动镜像 v2 对拍（对应 P1-6：AIC 头签名/加密联动）。

流程：
  1. 从参考 SDK 的 secure 方案拷夹具（bootloader.bin / keys），用 `wk image privres`
     生成 pbp_cfg.bin，再合成一个 d13x.pbp；
  2. 用参考 `mk_image.py -p`（只跑 pre-process）生成基准镜像；
  3. 用 `wk image aicimage` 生成我们自己的镜像；
  4. 逐字节比对，打印每个文件的差异。

覆盖 6 种组合：RSA-2048 签名 / HMAC-SHA256 / MD5+校验和、AES-128-CBC（SSK 派生与原始密钥）、
with_ext 填充、有无 loader、pbp/private/pubkey/iv 资源。

退出码：0 全部一致；1 有差异或环境缺失（打印 SKIP 原因）。
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
WORK = os.path.join(REPO, 'artifacts', 'aicboot')
FIXTURES = os.path.join(REPO, 'tools', 'checks', 'fixtures')

CASES = {
    'aicimage_secure.json': ['usbupg-psram-init.aic', 'pbp_ext.aic', 'loader.aic', 'plain-md5.aic'],
    'aicimage_variants.json': ['hmac-sign.aic', 'rawkey.aic'],
}


def skip(msg):
    print('SKIP: ' + msg)
    sys.exit(0)


def run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True)
    if r.returncode != 0:
        print('FAIL: ' + ' '.join(cmd))
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
        sys.exit(1)


def main():
    if not os.path.isfile(WK):
        skip('wk.exe 不存在（先 zig build）')
    if not os.path.isdir(PACK):
        skip('参考 SDK secure 方案不存在: ' + PACK)
    try:
        import Cryptodome  # noqa: F401
        have_cryptodome = True
    except Exception:
        have_cryptodome = os.path.isdir(os.path.join(SCRIPTS, 'Cryptodome'))
    if not have_cryptodome or not os.path.isfile(os.path.join(SCRIPTS, 'mk_image.py')):
        skip('参考 mk_image.py / Cryptodome 不可用')

    data = os.path.join(WORK, 'data')
    ref = os.path.join(WORK, 'ref')
    for d in (data, ref):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)

    shutil.copyfile(os.path.join(PACK, 'bootloader.bin'), os.path.join(data, 'bootloader.bin'))
    shutil.copytree(os.path.join(PACK, 'keys'), os.path.join(data, 'keys'), dirs_exist_ok=True)
    # 合成 d13x.pbp（参考只是原样拷贝 + 对齐）
    with open(os.path.join(data, 'd13x.pbp'), 'wb') as f:
        f.write(bytes(range(256)) * 17)
    run([WK, 'image', 'privres', '-c', os.path.join(PACK, 'pbp_cfg.json'),
         '-o', os.path.join(data, 'pbp_cfg.bin')], REPO)

    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'
    fails = 0
    for cfg, names in CASES.items():
        cfg_src = os.path.join(FIXTURES, cfg)
        if not os.path.isfile(cfg_src):
            print('SKIP: 缺少配置夹具 ' + cfg)
            continue
        shutil.copyfile(cfg_src, os.path.join(data, cfg))
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'mk_image.py'),
                            '-c', os.path.join('data', cfg), '-d', 'data/', '-k', 'data/', '-p', '-v'],
                           cwd=WORK, capture_output=True, env=env)
        if r.returncode != 0:
            print('FAIL: 参考 pre-process 失败 ' + cfg)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
            return 1
        for n in names:
            shutil.move(os.path.join(data, n), os.path.join(ref, n))
        r = subprocess.run([WK, 'image', 'aicimage', '-c', os.path.join('data', cfg), '-d', 'data', '-k', 'data'],
                           cwd=WORK, capture_output=True)
        if r.returncode != 0:
            print('FAIL: wk image aicimage 失败 ' + cfg)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:800])
            return 1
        for n in names:
            a = open(os.path.join(ref, n), 'rb').read()
            b = open(os.path.join(data, n), 'rb').read()
            diff = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
            first = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), None)
            status = 'OK  ' if diff == 0 else 'DIFF'
            print('%-28s %s len=%d/%d diff=%d first=%s' % (n, status, len(a), len(b), diff, first))
            if diff != 0:
                fails += 1

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
