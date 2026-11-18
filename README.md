# WuKong-Lite

WuKong-Lite（悟空 Lite）是用 **Zig** 复刻 [Luban-Lite 2.0](https://gitee.com/artinchip/luban-lite) 的 SDK 结构与核心工具链的项目。
目标不是逐行翻译 C 代码，而是让同一套“板级方案 / Kconfig 配置 / 镜像格式 / 打包流程 / 设备与 shell”在 Zig 下可用，
并且与 Luban-Lite 生成的二进制格式、分区串、宏定义保持一致。

> 参考项目：`G:\Code\C\luban-lite`（ArtInChip Luban-Lite SDK）
>
> 仓库地址：<https://github.com/RemoteAll/WuKong-Lite.git>（`origin` / `main`）

## 目录对照

| Luban-Lite | WuKong-Lite | 说明 |
|---|---|---|
| `Kconfig`、`target/*/Kconfig.*` | `wk/Kconfig`、`wk/target/d13x/Kconfig.*` | 配置树 |
| `target/configs/*_defconfig` | `wk/target/configs/*_defconfig` | 板级方案 |
| `output/<prj>/images/` | `wk/image/` | 生成产物 |
| `rtconfig.h` / `cconfig.h` | `wk/config/cconfig.h` | 配置头 |
| `.config` | `wk/config/.config` | 配置结果 |
| `bsp/common/*` | `src/bsp/common/*` | CRC32、镜像头、分区、env |
| `kernel/common`（OSAL） | `src/kernel/common/*` | 线程/互斥/信号量/邮箱/设备/堆统计 |
| `bsp/artinchip/drv/*` | `src/bsp/artinchip/drv/*` | host 模拟驱动（uart/gpio） |
| `tools/scripts/*.py` | `src/tools/*`、`wk` CLI | Kconfig、分区表、镜像打包 |
| `application/<kernel>/<app>` | `src/application/*` | HelloWorld 示例 |
| `finsh/msh` | `src/shell/*` | 命令行 |

## 已实现（与参考项目同格式/同语义）

- **Kconfig 配置系统**：`config/menuconfig`、`bool/tristate/string/int/hex`、`default ... if ...`、
  `depends on`、`select`、`def_bool`、`if/endif`、`source`（含 `*` 通配）、help 块。
  生成 `.config` / `cconfig.h` / `build_info.json`，方案命名沿用 `{soc}_{board}_{kernel}_{app}_defconfig`。
- **AIC 镜像头**（`bsp/common/include/aic_image.h`）：V1 64 字节 / V2 80 字节、magic `AIC `、
  32 位小端累加和取反校验、`load_address` / `entry_point` / 版本字段、构造与校验。
- **CRC32**：与 `crc32.c` 同一多项式与初值（ISO-HDLC，`123456789 -> 0xCBF43926`）。
- **分区串**：`MTD=spi0.0:512k(spl),128k(env),2m@0x100000(os),-(data)`、
  `GPT=...`（起点 `0x4400`）、大小后缀 K/M/G、`@offset`、`-` 剩余空间、名称前缀匹配。
- **分区表生成**（`gen_partition_table.py`）：`IMAGE_CFG_JSON_PARTS_MTD/UBI/GPT`、
  `FAL_PART_TABLE`、`partition.json`，偏移按顺序累加并支持显式 `offset`。
- **`image_cfg.json`**：剥离 `//` 注释与尾逗号；`media` 新旧两种格式；`part`/`attr` 数组转 `;`。
- **AIC.FW 固件包**（`mk_image.py`）：348 字节文件头、512 字节 META 表项、2 KiB 对齐数据区、
  `image.info` 组件（CRC 覆盖头部 2048 字节）、updater/target 组件顺序。
- **SPI NAND 页表**：`AICP` 头、101 项入口、双页地址 + 两段 checksum、整页校验和。
- **U-Boot env 镜像**（`mkenvimage`）：单份 `crc+data`、双份 `crc+flags+data`（active=1, obsolete=0），
  自动附加 `MTD=...` 分区串前缀。
- **GPT/MBR**：保护性 MBR、GPT 头与分区表 CRC、主备表生成与解析。
- **OSAL / 设备 / shell**：线程注册、互斥量、信号量、邮箱、节拍、设备注册/打开/读写、
  `uart0`（stdout）与 `gpio0` 模拟、`help/ps/free/date/list_device/part/gpio` 等 msh 命令。
- **HelloWorld 示例**：主线程 + 生产者线程，通过邮箱传递消息、信号量同步。
- **配置驱动编译**（等价 `SConscript` + `GetDepend`）：`wk build` 按 `.config` 评估模块表，
  生成 `wk/config/build_plan.json` 与 `src/generated/config.zig`；shell 按生成的常量裁剪设备注册。
- **FIT / ITB 打包**：`wk image itb` 直接生成标准 FIT（FDT 写入器 + images/configurations/timestamp），
  结构与参考 `mkimage -f` 生成物一致；`--its <file.its>` 走自写 ITS 解析器直出 FIT。
- **FIT 读取与校验**：`wk image fitinfo --input x.itb [--verify] [--dump]` 解析 FDT、
  列出 images/configurations，并按 `hash-N` 重算 crc32/md5/sha1/sha256（等价 bootm 的完整性检查）。
- **镜像加密**：`wk image crypt` 提供 AES-128-CBC 加/解密（`--pad none|zero|pkcs7`），
  与参考 `openssl enc -aes-128-cbc -nopad` 逐字节一致。
- **FAT 镜像构建**：`wk image fat` 生成 FAT12/FAT16/FAT32 数据分区镜像（LFN 长文件名、
  8.3 短名去重、卷标、`FAT 时间戳`），`--auto` 按内容估算尺寸（等价 `makefatfs.py -a`），
  `--fat32` 可强制 FAT32（含 BPB/FSInfo/备份引导/根目录簇），
  并在 0x80 写入 40 字节 AIC 扩展信息块 `AICF`（image_size/used_size + 校验和）。
- **RSA 签名/验签**：`wk image rsasign/rsaverify` 实现 PKCS#1 v1.5 + SHA-256
  （PKCS#1/PKCS#8 私钥、SPKI/PKCS#1 公钥 PEM，2048/3072/4096 位）。
- **Android sparse**：`wk image simg` 把 raw 镜像稀疏化（零块 FILL、其余 RAW、
  尾部补零），`--unsparse` 可展开；与参考 `img2simg.exe` 输出**逐字节一致**。
- **cpio 归档**：`wk image cpio` 按文件清单生成 `newc`/`crc` 归档（名字/数据 4 字节对齐、
  `TRAILER!!!`、512 对齐），对应 `mkcpio.py` 里 `cpio -ov -H crc` 的 OTA 子镜像。
- **OTA 打包**：`wk image ota` 解析 `ota-subimgs.cfg`、写回 image_cfg 的 version、生成
  512B `ota_info.bin`、按 `[file]` 列表生成 crc cpio，并把 `ota.cpio` 总大小回填到 `size` 字段。
- **文件拼接**：`wk image merge` 按 `--input` 顺序原样拼接（对应 `merge_files.py`）。
- **链接地址**：`wk image linkaddr` 根据 `.config` 计算 bootloader `TEXT/LOAD` 地址，并替换
  `image_cfg.json` 的 4 个占位符（对应 `calc_linked_addr.py`）。
- **链接尺寸**：`wk image linksize` 解析 `.map`，生成 `<base>.summary.csv`、`.detail.csv`、
  `.dironly.csv`（对应 `linked_size.py`）。
- **分区文件清单**：`wk image partlist` 读取 `image_cfg.json`，生成
  `<partition>,<file>,<partition_size>` 清单（对应 `gen_partition_file_list.py`）。
- **分区占用检查**：`wk image partcheck -c <cfg> -d <dir>` 输出占用表（对应
  `partition_check.py`）；`.jffs2` 按擦除块内容计算、UBI 卷优先取卷大小，`--strict` 时溢出返回非零。
- **littlefs 镜像**：`wk image littlefs -i <dir> -o <image.lfs> -b <block>` 生成 littlefs 2.x
  镜像（对应 `makelittlefs.py`）；复用 `third_party/littlefs` 上游实现，自动按
  `partition_file_list.h`/NFTL 保留区计算大小并裁剪尾部 `0xFF`。
- **烧写包准备**：`wk image flashpack` 读取 image_cfg 与 payload 目录，校验 AIC/FIT、
  自动补 `env.bin`/`rodata.fatfs`、按分区大小检查，输出 AIC.FW + `manifest.txt` + `FLASH.md`
  + `flash-upgcmd.ps1` / `flash-aiburn.ps1`。
- **官方文档迁移**：`docs/official/` 收录 SDK 的 AIBURN 技能（含客户端脚本）与第三方许可证，
  见 `docs/FLASHING.md`。
- **Zig 开发支持**：`docs/ZIG_ON_LUBAN_LITE.md` 记录 Zig 目标参数
  （`riscv32-freestanding-none -mcpu=generic_rv32+d+f+c+a+m`，对应 D13x `rv32imafdc/ilp32d`）
  与官方 Xuantie GCC 混链验证；示例在 `examples/zig_riscv/`。
- **Zig 裸机应用**：`apps/hello_uart/` + `tools/build-zig-app.ps1`，
  一键产出 `.o/.elf/.aic/.bin`（entry 0x41000000，UART0 轮询输出），
  可用 `upgcmd write/exec` 直接跑到 RAM。
- **ELF 工具**：`wk image elf2aic`（按 PT_LOAD 展开为 AIC 可启动镜像）、
  `wk image elf2its`（按参考 `elf2image` 规则提取 `segN.bin` 并生成 ITS，XIP 段序交换）。

## 未实现（明确边界）

- SM2 / RSA-PSS / 加密私钥；AIC 头 `sign_algo/encrypt_algo` 区间与 ITS `signature` 节点联动；
- ITS 中的 `signature*` / `cipher` 节点（解析到即报错，不做签名/加密）；
- 真实 SoC 的寄存器级 HAL、启动汇编、链接脚本与交叉编译到 RISC-V；
- RT-Thread/FreeRTOS/uCOS 内核本体、LVGL、lwIP、mbedTLS 等第三方包；
- FAT32 与 `makefatfs.py --fullpart`（按分区大小取整）；
- `fatupdate.exe` 追加的 AICF `dirent_sect_id/dirent_data_len` 列表（NFTL 离线烧录用），
  我们写 0，`used_size` 按“元数据 + 实际分配簇”计算，与参考工具口径不同；
- `mklittlefs` / `mkuffs` 文件系统镜像工具；
- cpio 的 ino/dev/uid/gid 跟随宿主机（参考 cpio.exe 也如此），因此不保证跨机字节一致；
- PBP/loader 组合、USB/UART 烧写上位机协议与 RTOS/HAL 本体：`flashpack` 只打包+校验，
  **不能代替厂商 bootloader 与烧写工具**（AiBurn / upgcmd）。

遇到未实现的配置（如 `sign` / `encrypt`）会明确报错，不会静默生成坏镜像。

## 快速开始

```powershell
zig build                     # 生成 zig-out/bin/wk.exe
zig build test                # 单元测试（配置/镜像/分区/OSAL/GPT/env）

# 1) 配置：方案 -> .config + cconfig.h + build_info.json
zig-out\bin\wk.exe defconfig --list
zig-out\bin\wk.exe defconfig d13x_demo88-nor_rt-thread_helloworld

# 2) 端到端演示：AIC 镜像 -> env -> AIC.FW 固件包 -> 分区表
zig-out\bin\wk.exe demo

# 3) 配置驱动的模块收集（等价 SConscript），生成 build_plan.json / config.zig
zig-out\bin\wk.exe build

# 4) 常用工具
zig-out\bin\wk.exe image dump wk/image/demo/demo88-nor.img
zig-out\bin\wk.exe image part --config wk/target/d13x/demo88-nor/pack/image_cfg.json
zig-out\bin\wk.exe image aic --input app.bin --load 0x40100000 --entry 0x40100000 -o app.aic
zig-out\bin\wk.exe image elf2aic --input app.elf -o app.aic
zig-out\bin\wk.exe image elf2its --input app.elf -o app_os.its
zig-out\bin\wk.exe image itb --kernel kernel.bin --fdt board.dtb --load 0x41000000 --entry 0x41000000 -o os.itb
zig-out\bin\wk.exe image itb --its app_os.its -o os.itb
zig-out\bin\wk.exe image crypt --input kernel.bin --key 000102030405060708090a0b0c0d0e0f --iv 101112131415161718191a1b1c1d1e1f --pad zero
zig-out\bin\wk.exe image fitinfo --input os.itb --verify
zig-out\bin\wk.exe image fat --input-dir rootfs --output data.img --size 8M --cluster 4 --label WKROOT
zig-out\bin\wk.exe image fat --input-dir rootfs --output data32.img --size 16M --cluster 1 --label FAT32T --fat32
zig-out\bin\wk.exe image fat --input-dir rootfs --output data.img --fullpart --cluster 4 --label WKROOT
zig-out\bin\wk.exe image fat --input-dir rootfs --output data.img --auto --cluster 4 --label WKROOT
zig-out\bin\wk.exe image rsasign --input os.bin --key rsa2048.pem -o os.sig
zig-out\bin\wk.exe image rsaverify --input os.bin --key rsa2048_pub.pem --sig os.sig
zig-out\bin\wk.exe image simg --input data.img --output data.img.sparse --block 4096
zig-out\bin\wk.exe image cpio --list ota-list.txt --input-dir out --output ota.cpio
zig-out\bin\wk.exe image ota --ota-cfg pack/ota-subimgs.cfg --image-cfg pack/image_cfg.json --input-dir out --out-dir out
zig-out\bin\wk.exe image merge --output merged.bin --input a.bin --input b.bin
zig-out\bin\wk.exe image linkaddr --config .config --input pack/image_cfg.json --output pack/image_cfg.json
zig-out\bin\wk.exe image linksize --map apps/hello_uart.map
zig-out\bin\wk.exe image partlist --config pack/image_cfg.json --output pack/partition_file_list.h
zig-out\bin\wk.exe image partcheck -c pack/image_cfg.json -d pack --strict
zig-out\bin\wk.exe image littlefs -i payload/data -o pack/data.lfs -b 4096 -p 256
zig-out\bin\wk.exe image flashpack --payload-dir payload --out-dir flash
powershell -File tools\fetch-upgcmd-deps.ps1 -SdkRoot <luban-lite>
powershell -File flash\flash-upgcmd.ps1 -Monitor COM5
zig-out\bin\wk.exe image env --config wk/target/d13x/demo88-nor/pack/image_cfg.json -o env.bin
zig-out\bin\wk.exe run hello
zig-out\bin\wk.exe shell
```

`wk demo` 会在 `wk/image/demo/` 下生成：

```
bootloader.bin -> bootloader.aic      AIC 可启动镜像（带 checksum）
os.bin         -> os.aic             AIC 可启动镜像
env.txt        -> env.bin            U-Boot 环境变量镜像（双份 + MTD 前缀）
image_cfg.json -> demo88-nor.img     AIC.FW 固件包（头部 + META 表 + 数据区）
               -> partition_table.h  与 Luban-Lite 相同的分区宏 / FAL 表
               -> partition.json     结构化分区表
```

## 与参考实现的逐字节验证

- `wk image env --input env.txt --size 4096 --redundant` 的输出与
  `tools/scripts/mkenvimage.exe -r -s 4096` **SHA256 完全一致**（含 0xFF 填充、flags 字节与 CRC 覆盖范围）。
- `wk image part --config ... --out/--json` 的输出与 `tools/scripts/gen_partition_table.py` 内容一致
  （Windows 下 Python 文本模式写 CRLF；忽略行尾差异后逐字节相同）。
- `wk image elf2its` 与 `tools/scripts/elf2image` 对同一 RISC-V ELF 生成的 `segN.bin` **哈希一致**、
  ITS 文本一致（忽略 CRLF）。
- `wk image itb` 生成的 FDT 结构与参考 `mkimage -f` 生成的 FIT 一致（images/configurations/timestamp）。
- `wk image itb --its <file.its>`（自写 ITS 解析器）与参考 `mkimage -f` 对比：
  `fdt_dump.py` 导出的逻辑树 **逐项完全相同**（含 `hash-1` 的 `value`、`timestamp` 位置置根首）；
  字节数不同只因 libfdt 会预留额外空间，结构等价。
- `wk image crypt` 与参考 `tools/scripts/openssl.exe enc -aes-128-cbc -nopad -K … -iv …`
  的**加密与解密双向均逐字节一致**（另含 NIST SP 800-38A 向量单测）；`--pad zero` 与
  手工补零后的 openssl 输出一致。
- `wk image fitinfo --verify` 对参考 `mkimage -f` 生成的带 hash FIT：**checked=4 failed=0**；
  改动 `data` 中一个字节后 **failed=2 且退出码 1**。
- `wk image fat` 生成的镜像用参考 `mcopy.exe` 递归拷回：**文件名（含 LFN）、目录结构、
  空目录、文件 SHA256 与源目录完全一致**（FAT12、512B 扇区、2 KiB 簇、卷标 WKROOT）。
- `wk image fat --auto` 对同一 rootfs 的总长与 `makefatfs.py -a` **同为 65536**，内容回读一致；
  `AICF` 头长度 40 与参考 `fatupdate.exe` 终态一致（其 dirent 列表与 used_size 口径未复刻，已注明）。
- `wk image rsasign` 对 1 MiB 数据 + 2048 位密钥的输出与 `openssl dgst -sha256 -sign`
  **逐字节相同**；`openssl dgst -verify` 能验过我们的签名，我们的 `rsaverify` 也能验过
  openssl 签名；篡改 1 字节后验签失败且退出码 1。
- `wk image simg` 与参考 `img2simg.exe` 在 11 组边界样本（全零/重复非零/交织/不足一块）
  及 1 MiB FAT 镜像上输出**逐字节完全一致**（block=1024）。
- `wk image cpio` 生成的归档能直接被参考 `cpio.exe -idm` 解开（文件与目录内容一致）；
  与参考归档做“归一化头字段”后比较，名字顺序/数据/校验和/对齐**完全一致**。
- `wk image flashpack` 自测（demo payload）：生成 27,136 字节 AIC.FW，manifest 列出每个组件的
  SHA256/分区/状态；缺 env.txt 时报 `MISSING(optional)`，补齐后自动生成 env.bin 且 warnings 归零。
- 补上 3 个 DLL 后，官方 `upgcmd.exe`（V1.4.2）的 `-e` **成功解析本工具生成的 AIC.FW**，
  列出并解出 updater/info/target 全部组件。
- 小样本回归向量（`a=b`、`-r -s 64`）已写入单元测试：`6D9AECC2 01 61 3D 62 00 00 FF...`。

## 测试覆盖

`zig build test` 覆盖：
- CRC32 标准向量、镜像 checksum 生成/校验/篡改检测；
- AIC 头 V1/V2 编解码、镜像构造与长度/校验；
- 分区串（单位、`@offset`、`-`、非法输入）、按名称前缀查找；
- env 单份/双份 CRC 与内容往返、容量越界；
- GPT 生成后解析、头 CRC 损坏检测；
- Kconfig 解析/defconfig/`depends on`/`select`/`if` 块、`.config` 与 `cconfig.h` 输出；
- `image_cfg` 注释/尾逗号、新旧 media 格式；
- 分区布局偏移、MTD 宏与 FAL 表、JSON 输出；
- AIC.FW 打包/解析、组件顺序/CRC、NAND 页表校验；
- OSAL 邮箱 FIFO/容量、信号量跨线程唤醒；
- 设备框架注册/打开/读写/关闭、GPIO 电平、统计分配器；
- 配置代码生成（Kconfig / `.config` → Zig 常量）、模块启用评估（含缺失符号诊断）；
- FDT/FIT 生成（头/属性/数据/配置）、ELF32 段解析与 AIC 镜像、ELF→ITS 段提取；
- FDT/FIT **读取**（写-读往返、坏 magic/截断报错）与 `hash-N` 校验、篡改检测；
- ITS 解析（C 风格注释、`<0x..>` 单元表达式、`&label` 引用、重复标签、错误位置）与 hash 节点回填；
- AES-128-CBC 加/解密往返、长度对齐错误、`zero`/`pkcs7` 补位；
- FAT12/FAT16 选择、卷标/短名/LFN 目录项、`AICF` 信息块与校验和；
- FAT `--auto` 尺寸（与参考 65536 基线一致）；
- RSA PKCS#1 v1.5 SHA-256：openssl 生成的 512 位向量逐字节比对、验签与篡改拒绝；
- sparse 头字段/零块 FILL/尾部补齐与往返、cpio crc 校验和与解析往返。

## 继续开发建议

1. SM2 签名、RSA-PSS、加密私钥，以及把 RSA 签名接入 ITS `signature` 节点与 AIC 头区间；
2. 增加 `src/bsp/artinchip/hal/*` 的寄存器模型与 `sys/d33x` 启动流程；
3. 把 `build.zig` 接入 `.config`（按开关选择模块编译，等价 `SConscript` 的 `GetDepend`）；
4. 补 FAT32、`makefatfs.py --fullpart` 与 AICF dirent 列表，以及 `mklittlefs` / `mkuffs` 镜像工具；
5. 接入厂商 PBP 生成与烧写协议（AiBurn/upgcmd）才能真正脱离厂商 SDK 上板。

> 烧写的具体命令、依赖与实测结论见 `docs/FLASHING.md`；
> 官方文档迁移范围见 `docs/official/README.md`；
> 全量迁移审计（已迁/部分/未迁 + 优先级）见 `docs/MIGRATION_AUDIT.md`。
