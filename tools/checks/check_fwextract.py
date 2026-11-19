"""AIC.FW 解包对拍（`mk_image.py -i/--imgfile` 的 `extract_img_data`）。

**重要实测（2026-11-19）**：参考 `extract_img_data()` 与其打包函数 `img_gen_fwc_meta()` 的
布局**不一致**——打包写 `partition[32]`，解包按 `partition[64]` 读，因此直接运行
`mk_image.py -i <img>` 会 `UnicodeDecodeError`（解它自己的镜像也必然失败）。
所以本脚本的"参考"是用 `img_gen_fwc_meta()` 那份**权威结构**在 Python 里复现的解析器
（字段顺序与参考打包端逐字段一致），再与 `wk image extract` 的结果比对。

做法：
  1. `wk image pack` 生成含 3 个组件的 AIC.FW（普通文件 ×2 + `.tar`）；
  2. Python 按权威布局解析 + `tarfile` 解 .tar → 基准目录；
  3. `wk image extract` → 我们的目录；
  4. 逐文件比对（含 tar 内文件）。
退出码 0 一致。
"""
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tarfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
WK = os.path.join(REPO, 'zig-out', 'bin', 'wk.exe')
WORK = os.path.join(REPO, 'artifacts', 'fwextract')
META_SIZE = 280
META_ALIGNED = 512


def cstr(b):
    return b.split(b'\x00', 1)[0]


def ref_extract(blob, out_dir):
    """按 `img_gen_fwc_meta()` 的权威布局解析（与参考打包端字段顺序一致）。"""
    assert blob[:8].rstrip(b'\x00') == b'AIC.FW', 'bad magic'
    meta_offset, meta_size = struct.unpack('<II', blob[332:340])
    os.makedirs(out_dir, exist_ok=True)
    files = []
    for i in range(meta_size // META_ALIGNED):
        off = meta_offset + i * META_ALIGNED
        m = blob[off:off + META_SIZE]
        assert m[:8].rstrip(b'\x00') == b'META', 'bad meta magic'
        # magic[8] name[64] partition[32] part_offset part_size dev_name[20] dev_id
        # offset_in_img size_in_img crc ram attr[64] filename[64]
        offset_in_img, size_in_img = struct.unpack('<II', m[136:144])
        filename = cstr(m[216:280]).decode('utf-8')
        if not filename:
            continue
        path = os.path.join(out_dir, filename)
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        body = blob[offset_in_img:offset_in_img + size_in_img]
        with open(path, 'wb') as f:
            f.write(body)
        if filename.endswith('.tar'):
            with tarfile.open(path) as t:
                dest = os.path.realpath(out_dir)
                for member in t.getmembers():
                    target = os.path.realpath(os.path.join(dest, member.name))
                    if target != dest and not target.startswith(dest + os.sep):
                        raise ValueError('unsafe tar member: %s' % member.name)
                t.extractall(out_dir)
        files.append((filename, size_in_img))
    return files


def walk_files(root):
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, root).replace('\\', '/')
            out[rel] = open(p, 'rb').read()
    return out


def main():
    if not os.path.isfile(WK):
        print('SKIP: wk.exe 不存在（先 zig build）')
        return 0

    shutil.rmtree(WORK, ignore_errors=True)
    data = os.path.join(WORK, 'data')
    os.makedirs(data, exist_ok=True)

    open(os.path.join(data, 'rootfs.fat'), 'wb').write(bytes(range(256)) * 4)
    open(os.path.join(data, 'app.bin'), 'wb').write(b'APP' + bytes(range(64)))

    inner = {'top.txt': b'tar top level\n', 'nested/inner.bin': bytes(range(32))}
    with tarfile.open(os.path.join(data, 'files.tar'), 'w') as t:
        for name, body in inner.items():
            info = tarfile.TarInfo(name)
            info.size = len(body)
            t.addfile(info, io.BytesIO(body))

    cfg = {
        'image': {
            'info': {
                'platform': 'd13x',
                'product': 'fwextract',
                'version': '1.0.0',
                'media': {'type': 'spi-nor', 'device_id': 0},
            },
            'target': {
                'rootfs': {'file': 'rootfs.fat', 'part': ['data']},
                'app': {'file': 'app.bin', 'part': ['data']},
                'files': {'file': 'files.tar', 'part': ['data']},
            },
        },
        'spi-nor': {
            'size': '16m',
            'partitions': {'data': {'size': '8m'}},
        },
    }
    cfg_path = os.path.join(WORK, 'image_cfg.json')
    with open(cfg_path, 'w', encoding='ascii', newline='\n') as f:
        json.dump(cfg, f, indent=2)

    img = os.path.join(WORK, 'demo.img')
    r = subprocess.run([WK, 'image', 'pack', '--config', cfg_path, '--datadir', data, '-o', img],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image pack 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1

    ref_dir = os.path.join(WORK, 'ref')
    meta = ref_extract(open(img, 'rb').read(), ref_dir)
    print('参考解析出 %d 个组件：%s' % (len(meta), [m[0] for m in meta]))

    our_dir = os.path.join(WORK, 'our')
    r = subprocess.run([WK, 'image', 'extract', img, '-o', our_dir],
                       cwd=WORK, capture_output=True)
    if r.returncode != 0:
        print('FAIL: wk image extract 失败')
        print((r.stdout + r.stderr).decode('utf-8', 'replace')[:900])
        return 1

    a, b = walk_files(ref_dir), walk_files(our_dir)
    fails = 0
    missing = sorted(set(a) - set(b))
    extra = sorted(set(b) - set(a))
    if missing:
        fails += 1
        print('FAIL: 缺少文件 %s' % missing[:6])
    if extra:
        fails += 1
        print('FAIL: 多出文件 %s' % extra[:6])
    for name in sorted(set(a) & set(b)):
        if a[name] != b[name]:
            fails += 1
            print('FAIL: %s 内容不一致（ref=%d, ours=%d）' % (name, len(a[name]), len(b[name])))
        else:
            print('OK: %s (%d B)' % (name, len(a[name])))

    if len(a) < 5:
        fails += 1
        print('FAIL: 文件数偏少（%d），tar 可能未解包' % len(a))
    print('文件数 ref=%d ours=%d' % (len(a), len(b)))
    print('FAILS = %d' % fails)
    return 0 if fails == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
