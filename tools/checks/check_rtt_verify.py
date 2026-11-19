"""`rtt2freertos --verify` 对拍（参考用 kconfiglib，我们用自家 Kconfig 解析）。

对 SDK 里**所有** `*_rt-thread_*_defconfig` 逐个执行：
  参考：`python rtt2freertos.py <cfg> -o <tmp> --verify --sdk-root <sdk>`
  我们：`wk rtt2freertos <cfg> -o <tmp> --verify --sdk-root <sdk>`
只比较 `--verify` 段输出（`  every option is defined...` / `  options without a definition...`
/ 告警行），转换本体已在别处对拍。

注意：两边都会在 SDK 根写 `.Kconfig.prj`（参考用完不删，我们删），所以要么都有写权限、
要么就跳过——没有写权限时打 SKIP。

退出码：0 全部一致；1 有差异或环境缺失。
"""
import os
import re
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
SDK = os.environ.get('WK_REF_SDK', r'G:\Code\C\luban-lite')
SCRIPTS = os.path.join(SDK, 'tools', 'scripts')
CONFIGS = os.path.join(SDK, 'target', 'configs')
WORK = os.path.join(REPO, 'artifacts', 'rtt_verify')

VERIFY_START = '  every option is defined in the target tree'


def collect_cfgs():
    out = []
    for name in sorted(os.listdir(CONFIGS)):
        if not name.endswith('_defconfig'):
            continue
        if '_rt-thread_' not in name:
            continue
        out.append(name)
    return out


def verify_block(text):
    """从完整输出里截出 --verify 段（到 `next steps:` 之前）。"""
    lines = text.splitlines()
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith('written to '):
            start = i + 1
            break
    if start is None:
        return None
    block = []
    for ln in lines[start:]:
        if ln.startswith('next steps:'):
            break
        block.append(ln.rstrip())
    while block and not block[-1]:
        block.pop()
    while block and not block[0]:
        block.pop(0)
    return '\n'.join(block)


def run(cmd, cwd):
    env = dict(os.environ)
    env['PYTHONPATH'] = SCRIPTS
    env['PYTHONIOENCODING'] = 'utf-8'
    return subprocess.run(cmd, cwd=cwd, capture_output=True, env=env)


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    if not os.path.isfile(os.path.join(SCRIPTS, 'rtt2freertos.py')):
        print('SKIP: 参考 rtt2freertos.py 不可用（设置 WK_REF_SDK）')
        return 0
    try:
        import kconfiglib  # noqa: F401
    except ImportError:
        print('SKIP: 参考 --verify 需要 kconfiglib（pip install kconfiglib）')
        return 0

    cfgs = collect_cfgs()
    if not cfgs:
        print('SKIP: %s 下没有 *_rt-thread_*_defconfig' % CONFIGS)
        return 0

    os.makedirs(WORK, exist_ok=True)
    out_dir = os.path.join(WORK, 'out')
    os.makedirs(out_dir, exist_ok=True)

    fails = 0
    skipped = 0
    checked = 0
    for name in cfgs:
        rel_cfg = os.path.join('target', 'configs', name)
        ref_out = os.path.join(out_dir, 'ref_' + name)
        our_out = os.path.join(out_dir, 'our_' + name)
        # cwd 必须是 SDK 根：参考的 kconfiglib 用 $srctree（未设时即 cwd）解析相对 source
        r = run([sys.executable, os.path.join(SCRIPTS, 'rtt2freertos.py'), rel_cfg,
                 '-o', ref_out, '--verify', '--sdk-root', SDK], SDK)
        if r.returncode != 0:
            print('FAIL %s: 参考失败' % name)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[-600:])
            fails += 1
            continue
        ours = run([WK, 'rtt2freertos', rel_cfg, '-o', our_out, '--verify', '--sdk-root', SDK],
                   SDK)
        if ours.returncode != 0:
            print('FAIL %s: wk 失败' % name)
            print((ours.stdout + ours.stderr).decode('utf-8', 'replace')[-600:])
            fails += 1
            continue

        ref_txt = (r.stdout + r.stderr).decode('utf-8', 'replace')
        our_txt = (ours.stdout + ours.stderr).decode('utf-8', 'replace')
        ref_blk, our_blk = verify_block(ref_txt), verify_block(our_txt)
        if ref_blk is None or our_blk is None:
            print('FAIL %s: 找不到 --verify 段（ref=%s ours=%s）'
                  % (name, ref_blk is not None, our_blk is not None))
            fails += 1
            continue

        checked += 1
        if ref_blk != our_blk:
            fails += 1
            print('FAIL %s: --verify 输出不一致' % name)
            rl, ol = ref_blk.splitlines(), our_blk.splitlines()
            for i in range(max(len(rl), len(ol))):
                x = rl[i] if i < len(rl) else '<none>'
                y = ol[i] if i < len(ol) else '<none>'
                if x != y:
                    print('  line %d:\n    ref = %r\n    ours= %r' % (i + 1, x, y))
                    break
        else:
            kind = 'all-defined' if VERIFY_START in ref_blk else 'has-unknown'
            print('  OK %s (%s)' % (name, kind))

        for p in (ref_out, our_out):
            try:
                os.remove(p)
            except OSError:
                pass

    # 参考会残留 .Kconfig.prj；我们删掉，这里清理可能由参考留下的那份
    stale = os.path.join(SDK, '.Kconfig.prj')
    if os.path.exists(stale):
        try:
            os.remove(stale)
        except OSError:
            pass

    print('对拍 %d 个 defconfig（%d 跳过）；FAILS = %d' % (checked, skipped, fails))
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
