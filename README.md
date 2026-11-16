# WuKong-Lite

WuKong-Lite（悟空 Lite）是用 **Zig** 复刻 [Luban-Lite 2.0](https://gitee.com/artinchip/luban-lite) 的 SDK 结构与核心工具链的项目。
目标不是逐行翻译 C 代码，而是让同一套“板级方案 / Kconfig 配置 / 镜像格式 / 打包流程 / 设备与 shell”在 Zig 下可用，
并且与 Luban-Lite 生成的二进制格式、分区串、宏定义保持一致。

> 参考项目：`G:\Code\C\luban-lite`（ArtInChip Luban-Lite SDK）

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
- **镜像加密**：`wk image crypt` 提供 AES-128-CBC 加/解密（`--pad none|zero|pkcs7`），
  与参考 `openssl enc -aes-128-cbc -nopad` 逐字节一致。
- **ELF 工具**：`wk image elf2aic`（按 PT_LOAD 展开为 AIC 可启动镜像）、
  `wk image elf2its`（按参考 `elf2image` 规则提取 `segN.bin` 并生成 ITS，XIP 段序交换）。

## 未实现（明确边界）

- 镜像签名（RSA/SM2）与 AIC 头 `sign_algo/encrypt_algo` 区间联动（加密算法已可用，但未接入头部布局）；
- ITS 中的 `signature*` / `cipher` 节点（解析到即报错，不做签名/加密）；
- 真实 SoC 的寄存器级 HAL、启动汇编、链接脚本与交叉编译到 RISC-V；
- RT-Thread/FreeRTOS/uCOS 内核本体、LVGL、lwIP、mbedTLS 等第三方包；
- 文件系统镜像工具（makefatfs / mklittlefs / mkuffs）。

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
- ITS 解析（C 风格注释、`<0x..>` 单元表达式、`&label` 引用、重复标签、错误位置）与 hash 节点回填；
- AES-128-CBC 加/解密往返、长度对齐错误、`zero`/`pkcs7` 补位。

## 继续开发建议

1. RSA/SM2 签名（`signature`/`cipher` 节点目前显式报错）与 AIC 头 `sign_algo/encrypt_algo` 区间联动；
2. 增加 `src/bsp/artinchip/hal/*` 的寄存器模型与 `sys/d33x` 启动流程；
3. 把 `build.zig` 接入 `.config`（按开关选择模块编译，等价 `SConscript` 的 `GetDepend`）；
4. 增加 `makefatfs` / `mklittlefs` 的 Zig 版本与文件系统镜像回读校验。
