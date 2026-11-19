# WuKong-Lite 源码地图

> 供开发者和 AI Agent 快速定位实现。对照参考项目 `G:\Code\C\luban-lite`。

## 1. 配置与方案

| 文件 | 作用 |
|------|------|
| `wk/Kconfig` | 顶层配置树（Kernel / Build options / source 子配置） |
| `wk/target/d13x/Kconfig.chip` | d13x 芯片能力清单（`AIC_*_DRV`、版本号、外设开关） |
| `wk/target/d13x/demo88-nor/Kconfig.board` | demo88-nor 板级配置（介质、串口、启动地址） |
| `wk/target/configs/d13x_demo88-nor_rt-thread_helloworld_defconfig` | 方案配置 |
| `wk/config/.config` | 生成：配置结果（不提交） |
| `wk/config/cconfig.h` | 生成：C 宏头（不提交） |
| `wk/config/build_info.json` | 生成：工程元信息（不提交） |

## 2. 公共格式层 `src/bsp/common/`

| 文件 | 对应 Luban-Lite | 关键实现 |
|------|-----------------|----------|
| `crc32.zig` | `bsp/common/crc32/crc32.c` | 编译期生成 256 项表，ISO-HDLC |
| `checksum.zig` | `bsp/common/image/image.c` | `image_calc_checksum` / `image_verify_checksum` |
| `image.zig` | `bsp/common/include/aic_image.h` | `HeaderV1`(64B) / `HeaderV2`(80B)、构造/校验/dump |
| `partition.zig` | `bsp/common/partition/partition.c` | `parseMtd` / `parseGpt` / 名称查找 / dump |
| `gpt.zig` | `bsp/common/include/disk_part.h` | GPT 头/MBR/条目结构、CRC 校验、主备表生成 |
| `env_image.zig` | `tools/scripts/mkenvimage` + `packages/artinchip/env/env.c` | 单份/双份 env、CRC、前缀 |
| `utils.zig` | `tools/scripts/*.py` 小函数 | `sizeStrToInt`、`roundUp`、hexdump、定长字符串 |

## 3. 内核抽象 `src/kernel/common/`

| 文件 | 作用 |
|------|------|
| `osal.zig` | `Kernel`（节拍/线程表/睡眠）、`Mutex`、`Semaphore`、`Mailbox` |
| `device.zig` | `Device` + `DeviceOps` + `Registry`（注册/打开/引用计数/读写） |
| `heap.zig` | `Counting` 分配器包装（used/peak/alloc/free 统计，供 `free` 命令） |

## 4. 驱动（host 模拟）`src/bsp/artinchip/drv/`

| 文件 | 设备名 | 说明 |
|------|--------|------|
| `uart.zig` | `uart0` | char 设备，write → stdout |
| `gpio.zig` | `gpio0` | 128 引脚电平表，read/write |

## 5. 工具链 `src/tools/`

| 文件 | 对应脚本 | 说明 |
|------|----------|------|
| `kconfig.zig` | `tools/env` + `aic_build.py::chk_prj_config` | Kconfig 解析/表达式/求值/输出 |
| `image_cfg.zig` | `mk_image.py::parse_image_cfg` | 去注释 JSON、media/part/attr 解析 |
| `partition_table.zig` | `gen_partition_table.py` | MTD/UBI/GPT 宏、FAL 表、JSON、env 前缀 |
| `pack.zig` | `mk_image.py`（打包部分） | AIC.FW 组装、AIC 镜像、env、页表 |
| `codegen.zig` | `chk_prj_config` 的 C 头生成 | `.config` / Kconfig → `src/generated/config.zig` |
| `modules.zig` | `SConscript` + `GetDepend` | 模块启用评估、`build_plan.json` |
| `fdt.zig` | `mkimage -f`（FDT 部分） | DEVICE TREE blob 写入器 |
| `fdt_reader.zig` | `fdt_dump.py` + U-Boot `bootm` | FDT/FIT 读取、节点/属性访问、`hash-N` 重算校验 |
| `itb.zig` | `mk_image.py::itb` | FIT/ITB（images/configurations/timestamp） |
| `its.zig` | `mkimage -f`（`image-host/libfdt`） | `.its` 源码解析（C 风格注释/`<expr>`/节点引用），hash 节点自动填充，timestamp 置根首 |
| `elf2aic.zig` | `elf2image` + AIC 头 | ELF32/64 段解析、AIC 展开、ITS 段提取 |
| `crypt.zig` | `firmware_security_encrypt`（AES 部分） | AES-128-CBC 加/解密、hex 密钥解析、none/zero/pkcs7 补位 |
| `fat.zig` | `makefatfs.py`（mformat + mcopy + AICF） | FAT12/16 镜像、LFN/8.3 目录项、卷标、`--auto` 尺寸、`AICF` 信息块 |
| `rsa.zig` | `mk_image.py` 的 PKCS1_v1_5 + U-Boot bootm | PEM/DER 解析、PKCS#1 v1.5 SHA-256 签名/验签 |
| `sparse.zig` | `img2simg` / `simg2img` | Android sparse（零块 FILL、其余 RAW、尾部补齐） |
| `cpio.zig` | `mkcpio.py`（`cpio -ov -H crc`） | newc/crc 归档、4 字节对齐、TRAILER、512 对齐 |
| `flashpack.zig` | `mk_image.py` + 烧写前检查 | 组件校验/补齐、分区上限检查、AIC.FW、manifest/FLASH.md |

## 6. 应用与 shell

| 文件 | 说明 |
|------|------|
| `src/shell/shell.zig` | 分词、命令分派、交互式循环（stdin） |
| `src/shell/cmds.zig` | `help/version/uptime/ps/free/date/list_device/part/gpio/reboot` |
| `src/application/helloworld.zig` | 线程 + 邮箱 + 信号量示例 |
| `src/main.zig` | `wk` CLI：`defconfig/config/build/image/shell/run/demo` |
| `src/aic.zig` | 顶层模块导出（测试入口） |
| `src/generated/config.zig` | 生成：配置常量（`wk defconfig` / `wk build` 写入） |

## 7. 关键格式速查

### AIC 镜像头 V1（64 字节，小端）

```
0x00 magic(4)       = 0x20434941 "AIC "
0x04 checksum(4)    = ~sum32(image with checksum=0)
0x08 head_ver(4)    0x00010000
0x0C image_len(4)
0x10 fwver_counter/revision/minor/major (4×u8)
0x14 firmware_len(4)
0x18 load_address(4)
0x1C entry_point(4)
0x20 sign_algo(4) 0x24 encrypt_algo(4)
0x28..0x3F sign/iv offset+len (6×u32)
```

### AIC.FW 固件包

```
+0        文件头 348B（"AIC.FW" + platform/product/version/media_type + meta/file 区偏移/大小）
+2048     META 表，每项 512B（"META" + name/partition/part_offset/part_size/dev/offset/size/crc/ram/attr/file）
file_off  数据区，每个文件 2 KiB 对齐，空隙填 0
```

### U-Boot env

```
单一：u32 crc32(data) | data[size-4]（NUL 分隔，0xFF 填充）
冗余：u32 crc | u8 flags(1=active,0=obsolete) | data[size-5]
      （-r 只输出一份，第二份由 bootloader 生成；CRC 覆盖整个数据区含填充）
```

### NAND 页表（AICP）

```
head(20B): "AICP" + entry_cnt(u32) + page_size(u16) + pages_per_block(u8) + 0xFF + planes(u8) + 7×0xFF
entry(20B)×101: pageaddr1 + pageaddr2 + checksum2 + reserved + checksum1
校验和写在偏移 36（首个 entry 的 checksum1），整页 sum+1==0
```

### FAT 镜像与 AICF 信息块

```
引导扇区 0x00: EB 3C 90 + OEM + BPB（512B 扇区 / 2 FAT / 512 根目录项）
          0x1FE: 55 AA
         0x080: "AICF" + cksum ~sum32 + length(32) + version(0x0101)
                + image_size(u64) + used_size(u64) + dirent_sect_id + dirent_data_len
FAT12 项：entry0 = 0xFF8、entry1 = 0xFFF；FAT16：0xFFF8 / 0xFFFF
```

## 8. 常见任务

- **加一个新的板级方案**：复制 `wk/target/configs/*_defconfig` 改 `PRJ_*`，在对应 `Kconfig.board` 增加开关，执行 `wk defconfig`。
- **加一个配置项**：在 Kconfig 中 `config XXX`，`bool/string/int` + `default`；生成结果自动进 `.config` / `cconfig.h` / `config.zig`。
- **加一个模块**：在 `src/tools/modules.zig` 登记 sources/requires/deps，执行 `wk build` 查看启用状态。
- **ELF 固件**：`wk image elf2its --input app.elf -o app_os.its` 生成 ITS + `segN.bin`（可直接交给 `mkimage -f`）。
- **FIT 镜像**：`wk image itb --kernel ... --fdt ... -o os.itb`（无需 mkimage）。
- **ITS 直出 FIT**：`wk image itb --its os.its -o os.itb`（解析 `.its`，自动算 `hash-1` 并补 `timestamp`）。
- **FIT 信息/校验**：`wk image fitinfo --input os.itb [--verify] [--dump]`（等价 `mkimage -l`
  与 bootm 的 hash 校验；校验失败退出码 1）。
- **镜像加密**：`wk image crypt --input app.bin --key <32hex> --iv <32hex> [--pad zero]`，
  与 `openssl enc -aes-128-cbc -nopad` 逐字节一致；解密加 `--decrypt`。
- **FAT 数据分区**：`wk image fat --input-dir rootfs --output data.img --size 8M
  [--sector 512] [--cluster 4] [--label WKROOT]`，`--auto` 可省 `--size`（等价 makefatfs -a）；
  可用参考 `mcopy.exe -i data.img -s ::/ dir` 回读校验。
- **RSA 签名**：`wk image rsasign --input os.bin --key rsa2048.pem [-o os.sig]`，
  `wk image rsaverify --input os.bin --key rsa2048_pub.pem --sig os.sig`；与
  `openssl dgst -sha256 -sign/-verify` 逐字节互通。
- **稀疏镜像**：`wk image simg --input data.img --block 4096`（`--unsparse` 展开）；
  输出与参考 `img2simg.exe` 逐字节一致。
- **cpio 归档**：`wk image cpio --list files.txt --input-dir out -o ota.cpio`
  （默认 `crc`，可选 `--format newc`）；可用参考 `cpio.exe -idm` 回读。
- **烧写包**：`wk image flashpack [--payload-dir payload] [--out-dir flash]`；
  payload 放真实厂商 `bootloader.aic` / OS 文件；输出 AIC.FW + manifest + FLASH.md
  + `flash-upgcmd.ps1`（直烧）/ `flash-aiburn.ps1`（9100 server）。
- **AIC.FW 解包**：`wk image extract <img> [-o dir]`（等价 `mk_image.py -i/--imgfile`）；
  默认解到 `dirname(img)/<stem>`，`.tar` 组件自动展开。
  **注意**：参考 `extract_img_data()` 按 `partition[64]` 读、其打包端写 `partition[32]`，
  参考自身对真实镜像必崩；我们按打包端权威布局实现。
- **UFFS / 固件加密**：`wk image uffs` / `wk image fwenc`（调 SDK 自带 `mkuffs.exe` /
  `firmware_security_encrypt.exe`，参数与参考脚本完全一致；`--tooldir` 指目录）。
- **官方烧写工具**：`tools/fetch-upgcmd-deps.ps1` 补齐 upgcmd 的 3 个 DLL，
  产物在 `wk/image/tools/upgcmd`；用法见 `docs/FLASHING.md`。
- **官方文档**：`docs/official/`（迁移 `doc/skills/aiburn` 与第三方许可证）。
- **Zig 接入 Luban-Lite**：`docs/ZIG_ON_LUBAN_LITE.md` + `examples/zig_riscv/`
  （目标参数、与官方 Xuantie GCC 混链、SCons 接库方式）。
- **Zig 裸机应用**：`apps/hello_uart/` + `tools/build-zig-app.ps1`
  （`wk image elf2aic` 出 AIC，`objcopy` 出 bin，可 `upgcmd write/exec`）。
- **未实现（明确边界）**：SM2/RSA-PSS/加密私钥、AIC 头 `sign_algo/encrypt_algo` 与
  iv/sign 区联动、FAT32、`mklittlefs`/`mkuffs`、PBP 生成与 USB/UART 升级协议。
