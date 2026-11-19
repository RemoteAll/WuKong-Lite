"""FAT + NFTL 预留块对拍（backlog P2-10）。

参考 `makefatfs.py`：
  * `-f/--fullpart`：镜像大小 = `partition_file_list.h` 里该文件的分区大小；
  * 若同目录 `partition.json` 的 `partitions.nftl` 包含 `<镜像名去扩展名>:`，再减去
    NFTL 预留（默认 `51*64*2048`；`-b N` 且 N>50 时 `(N+1)*64*2048`），最后按簇对齐。

做法：同一份夹具分别用参考脚本与 `wk image fat --fullpart --reserved N` 生成镜像（输出同名
`data.fat`，各自目录下带 `partition_file_list.h` / `partition.json`），比对：
  1. 镜像总大小（NFTL 尺寸策略的核心）；
  2. BPB 关键字段；
  3. 用参考 `mcopy` 从我们镜像里导出文件，与原始文件字节一致。
退出码 0 一致。
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
WORK = os.path.join(REPO, 'artifacts', 'fatnftl')

PART_SIZE = 16777216      # 16 MiB（十进制：参考 int() 不认 0x）
RESERVED = 60             # >50 ⇒ (60+1)*64*2048 = 7,995,392 B
CLUSTER_SECTORS = 8
SECTOR = 512
FILES = {
    'a.txt': b'hello nftl fat\n' * 100,
    'sub/b.bin': bytes(range(256)) * 3,
}


def bpb_info(img):
    return {
        'bytes_per_sector': struct.unpack('<H', img[11:13])[0],
        'sectors_per_cluster': img[13],
        'reserved_sectors': struct.unpack('<H', img[14:16])[0],
        'num_fats': img[16],
        'root_entries': struct.unpack('<H', img[17:19])[0],
        'total_sectors16': struct.unpack('<H', img[19:21])[0],
        'total_sectors32': struct.unpack('<I', img[32:36])[0],
    }


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0
    if not os.path.isfile(os.path.join(SCRIPTS, 'mformat.exe')):
        print('SKIP: 缺少参考 mtools（mformat/mcopy）')
        return 0
    mcopy = os.path.join(SCRIPTS, 'mcopy.exe')

    shutil.rmtree(WORK, ignore_errors=True)
    data = os.path.join(WORK, 'data')
    os.makedirs(os.path.join(data, 'sub'), exist_ok=True)
    for name, body in FILES.items():
        with open(os.path.join(data, name), 'wb') as f:
            f.write(body)

    for d in ('ref', 'our'):
        os.makedirs(os.path.join(WORK, d), exist_ok=True)
        with open(os.path.join(WORK, d, 'partition_file_list.h'), 'w', encoding='ascii', newline='\n') as f:
            f.write('data,data.fat,%d\n' % PART_SIZE)
        with open(os.path.join(WORK, d, 'partition.json'), 'w', encoding='ascii', newline='\n') as f:
            json.dump({'partitions': {'nftl': 'data:,rootfs:'}}, f)

    ref_img = os.path.join(WORK, 'ref', 'data.fat')
    our_img = os.path.join(WORK, 'our', 'data.fat')

    r = subprocess.run([sys.executable, os.path.join(SCRIPTS, 'makefatfs.py'),
                        '-f', '-r', '-i', 'data', '-o', 'ref/data.fat',
                        '-b', str(RESERVED), '-s', str(SECTOR), '-c', str(CLUSTER_SECTORS),
                        '-t', SCRIPTS + os.sep],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0 or not os.path.isfile(ref_img):
        print('FAIL: 参考 makefatfs 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1

    r = subprocess.run([WK, 'image', 'fat', '--fullpart', '--input-dir', 'data',
                        '--output', 'our/data.fat', '--reserved', str(RESERVED),
                        '--sector', str(SECTOR), '--cluster', str(CLUSTER_SECTORS)],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image fat 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1

    ref = open(ref_img, 'rb').read()
    our = open(our_img, 'rb').read()
    fails = 0

    expected = PART_SIZE - (RESERVED + 1) * 64 * 2048
    print('size ref=%d ours=%d expected=%d' % (len(ref), len(our), expected))
    if len(ref) != len(our) or len(our) != expected:
        fails += 1
        print('FAIL: 镜像大小不一致')

    a, b = bpb_info(ref), bpb_info(our)
    print('bpb ref=%s' % a)
    print('bpb our=%s' % b)
    for key in a:
        if a[key] != b[key] and key not in ('root_entries', 'total_sectors16'):
            fails += 1
            print('FAIL: BPB 字段 %s 不一致（%s vs %s）' % (key, a[key], b[key]))

    env = dict(os.environ)
    env['MTOOLS_SKIP_CHECK'] = '1'
    for name, body in FILES.items():
        dst = os.path.join(WORK, 'extract_' + name.replace('/', '_'))
        if os.path.exists(dst):
            os.remove(dst)
        # 目标也用相对路径：mtools 会把绝对盘符路径当成驱动器
        rel_dst = '../' + os.path.basename(dst)
        r = subprocess.run([mcopy, '-i', 'data.fat', '::/' + name, rel_dst],
                           cwd=os.path.join(WORK, 'our'), capture_output=True, env=env)
        if r.returncode != 0 or not os.path.exists(dst):
            fails += 1
            print('FAIL: mcopy 无法从我们的镜像导出 %s' % name)
            print((r.stdout + r.stderr).decode('utf-8', 'replace')[:400])
            continue
        if open(dst, 'rb').read() != body:
            fails += 1
            print('FAIL: %s 内容不一致' % name)
        else:
            print('OK: %s 可导出且内容一致' % name)

    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
