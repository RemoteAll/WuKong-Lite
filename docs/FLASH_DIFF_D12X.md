# d12x 烧写对比：能升级的固件 vs 我们打出来的固件

> 对照物：`d12x_demo68-nor_v1.0.0.img`（6,607,360 B，SHA256 `383ABD06…3DB61D`，2026-11-19 由用户提供，**实测可升级成功**）
> 我方：`artifacts/firmware-d12x/d12x_demo68-nor_v1.0.0_zig.img`（9,419,264 B，SHA256 `6797B4A3…2FDF3EF`）
> 现象：我方镜像在 AiBurn 里 **进度 3%、速率 10.7 KB/s、用时 1:13 后 FAIL**，启动阶段仍显示 `BROM`。

## 1. 结论先说

1. **分区表 / 介质 / 版本完全一致** —— `info.bin` 两个都是 2,048 B，**只差 2 字节**（构建时间戳 0x0159-0x015A）。所以不是 flash 容量、不是分区越界、不是介质类型错。
2. **失败点在"传完 bootloader 那一刻"** —— 两边都是先传 `psram-init` 再传 `bootloader`：
   - 对照固件：36,112 + 255,504 = **291,616 B**
   - 我方：34,576 + 260,880 = **295,456 B**
   - 进度 3% ≈ 9.4 MB × 3% ≈ 282 KB，**正好落在这个位置**。也就是说：BROM 收完 spl 之后，spl 没能接管后续流程。
3. **差异全部集中在两个 BROM 阶段的二进制上**，应用侧（os/rodata/data）不是失败原因（本文第 4 节给了验证办法）。

## 2. 逐组件对比

| 组件 | 对照固件（能升级） | 我方 | 判定 |
|------|-------------------|------|------|
| `info.bin`（分区表/介质/版本） | 2,048 B | 2,048 B | **只差 2 字节**（构建时间戳）→ 布局一致 |
| `env.bin`（env / env_r） | 4,096 B，CRC `0xCE19208A` | 4,096 B，CRC `0xCE19208A` | **完全相同** |
| `uartupg-psram-init.aic` | **36,112 B**，CRC `0x2B70EDD0` | **34,576 B**，CRC `0xBB9749C6` | **差 1,536 B**，内含 pbp 二进制版本不同 |
| `bootloader.aic`（spl） | **255,504 B**，CRC `0xC881C994` | **260,880 B**，CRC `0x3E37D63F` | **差 5,376 B**，不同 SDK 版本编译 |
| `d12x_os.itb` | 1,128,448 B | 1,619,968 B | 我方大 491 KB（app 配置/组件更多） |
| `rodata.fatfs` | 4,648,960 B | 6,959,104 B | 我方大 2.31 MB（LVGL 资源更多） |
| `data.lfs` | 266,240 B | 266,240 B | 大小相同、内容不同（可写数据分区，不影响烧写） |

## 3. 两个引导组件的具体差异

### 3.1 `uartupg-psram-init.aic`（BROM 阶段初始化 PSRAM）

两边都是 `SECT_PSRAM(0x41490006)` + 同名 cfg 表结构（`pbp_cfg.json` 里 **10 个 cfg**，我方
`pbp_cfg.bin` = 1,808 B 已含全部 10 项）；**体积差 1,536 B 属 SDK 版本差异**，内嵌 `d12x.pbp`
也不是同一份。

> ⚠️ **已撤回的错误结论**：早前按“型号 ID 在二进制里的出现次数”判定“我方缺 W957D6NKR / W956D8NKR”，
> 那是**搜索口径弄错**——`pbp_cfg.json` 里 `getid.id` 用的是读 CR 得到的值（如 `0x000a000a`、`0x00020002`），
> 与 `ram_param.c` 里 `PSRAM_FUSE_*` 的芯片 ID（如 `0x0c860c86`）不是同一套值，两者不能直接比对。
> 对 D123BBV（mark_id 0x08 → APS3208K）我方配置是齐的。

### 3.2 `bootloader.aic`（spl）

两边都带 `Welcome to ArtInChip Luban-Lite %d.%d.%d` 与 PSRAM 型号表（我方型号齐全，仅个别型号条目计数略少），
但**体积差 5,376 B**，属于**不同 SDK 版本编译的产物**。

> 我方 bootloader.bin = 223,664 B，与官方 SDK `target/d12x/demo68-nor/pack/bootloader.bin` **大小一致**，
> 即"当前 SDK 版本的标准产物"。对照固件约 218,288 B，明显更旧。

**因此最可能的失败原因：新版 SDK 的 bootloader 与这块板子（或与其配对的 psram-init）不匹配。**

## 4. 用三个混合镜像一轮定位

已生成（`artifacts/firmware-d12x/`），全部只替换引导组件，应用侧仍是我们的：

| 镜像 | psram-init | bootloader | 大小 | 若**成功**说明 | 若**失败**说明 |
|------|-----------|-----------|------|---------------|---------------|
| `..._MIX-psram.img` | 对照 | 我方 | 9,421,312 B | 问题在 psram-init | 问题不在 psram-init |
| `..._MIX-boot.img` | 我方 | 对照 | 9,406,976 B | 问题在 bootloader | 问题不在 bootloader |
| `..._MIX-both.img` | 对照 | 对照 | 9,409,024 B | 引导侧问题确认，且**这个镜像可直接当交付固件用** | 问题在应用侧（os/rodata） |
| `..._v1.0.0_zig.img` | 我方 | 我方 | 9,419,264 B | （已知失败，作为基线） | — |
| `..._MIX-cd.img` | 我方 | 我方 | 6,617,600 B | 反向验证：我方引导 + 对照 app | — |

**推荐测试顺序**：`MIX-both` → 若成功，再用 `MIX-psram` / `MIX-boot` 确定具体是哪一件。

## 5. 烧写参数（**3M 可用**，实测结论）

> ⚠️ **已撤回的错误判断**：早前根据“3M 下实测 10.7 KB/s”推测链路降到了 115200，建议改 921600。
> 用户实测反馈：**能升级成功的那份固件就是用 3M 烧的** —— 所以 3M 本身没问题，该推断不成立。
> 10.7 KB/s 更可能是“擦除 / 等待应答”阶段的瞬时值，不代表链路降速。

仍建议用命令行烧写，因为**日志信息量大得多**（AiBurn 只显示“执行失败”）：

```
wk\image\tools\upgcmd\upgcmd.exe -u COM25 -b 3000000 -p -v image "<img 文件>"
```

`-v` 会打印握手、每个组件的进度与错误码，能直接指出是“擦除失败”“写入失败”还是“执行超时”。

其它：
1. 勾选 **“烧写成功后重启设备”**；若仍失败再试 **“全片擦除”**。
2. 烧写前可先自检镜像：`upgcmd.exe -i <img>` 应列出 9 个 FWC 且 platform=d12x。

## 6. 与 C 参考 SDK 的构建对比（用户要求：是否完全按 C 版迁移）

### 6.1 源码级：实质一致

逐文件比对 `G:\Code\C\luban-lite`（33,382 文件）与 `build\luban-lite`（32,294 文件）：

| 项 | 数量 | 说明 |
|----|------|------|
| 内容不同 | **1** | `application/rt-thread/helloworld/main.c` —— 仅文件头多一个 UTF-8 BOM（撤销 Zig 注入时写入），**无实质差异** |
| 仅副本有 | 6 | `.config.old` / `.defconfig` / `partition_table.h` / `rtconfig.py` / `d12x_bootloader_gcc.ld` / `.Kconfig.prj` —— 全是构建中间产物 |
| 仅参考有 | 1,100 | 其中 **1,087 个是 `doc/`**，其余为 README/.gitignore/win_env.bat 等，**不参与编译** |

### 6.2 产物级：**bootloader 与官方预编译交付物逐字节相同**

```
我们构建的  output\d12x_demo68-nor_baremetal_bootloader\images\d13x.bin   223,664 B
SDK 官方    target\d12x\demo68-nor\pack\bootloader.bin                     223,664 B
SHA256 均为 0B3557B8…
→ 逐字节相同
```

`pack/bootloader.bin` 是厂商随 SDK 交付的预编译 bootloader，我们用自己的工具链从源码编出来与它**完全一致**，
说明构建参数、优化级别、链接布局都没有偏差。

### 6.3 但我们的构建流程确实有“绕过”，根因在这里

官方 `SConstruct` 第 68-71 行：

```python
chip_path = os.path.join(AIC_ROOT, 'bsp/artinchip/sys/' + PRJ_CHIP)
sys.path.append(chip_path)
import rtconfig
```

**官方直接从 `bsp/artinchip/sys/<chip>/rtconfig.py` 导入，工作区根目录不需要 `rtconfig.py`。**
而这个文件里的 `SOC` 决定产物名：`TARGET = PRJ_OUT_DIR + rtconfig.SOC + '.' + TARGET_EXT`。

我们当初为了让 GCC 14 通过（SDK 默认假定 V2.6.1 工具链，其 `ISA_TAG=''` 不带 `zifencei`，
而 GCC 14 生成的代码含 `fence.i` 必须声明该扩展），把 **d13x 的 `rtconfig.py` 复制到工作区根**并硬编码 `_zifencei`。
后果：

1. Python 的 import 优先命中根目录副本 → `SOC='d13x'` → **d12x 方案产出 `d13x.elf`**；
2. 于是我们的构建脚本又加了“把 `d13x.elf` 复制成 `d12x.elf`”的补丁（`image_cfg` 的 `elf2itb` 段要 `d12x.elf`）。

**正确的做法**（已查证）：不要动工作区根，改为给 `bsp/artinchip/sys/d12x/rtconfig.py` 打同一条 zifencei 补丁。
另外该文件在 `e906fdp/e907fdp`（双精度）分支**漏了 `TOOLCHAIN_LIB` 赋值**（d13x 版有），
直接用它构建会报 `can't link single-float modules with double-float modules` —— 这也是当初绕去用 d13x 版本的原因。

> 工具链 `toolchain/lib/gcc/riscv64-unknown-elf/14.1.1/` 下只有 `rv32imafc/ilp32f`、
> `rv32imafdc_xtheade/ilp32d`、`rv64imafdc_zfh_xtheadc/lp64d` 三份 multilib，**没有 `rv32imafdc_zifencei_xtheade`**。
> 所以正确配法是：`-march` 带 `_zifencei`，multilib 路径用不带 zifencei 的 `rv32imafdc_xtheade`（ABI 相同）。

**但这属于“流程洁癖”，与烧写失败无关** —— 6.2 已证明产物就是官方那一份。

### 6.4 结论

- 我们的固件 = **官方当前 SDK 的标准产物**（bootloader 二进制逐字节可证）；
- 你能升级成功的那份是**更老 SDK 版本**的产物（loader 216,136 B vs 223,664 B）；
- 所以“做到和它完全一模一样”不成立 —— 除非改用同一版本的 SDK；
- 想立刻能用：烧 `..._MIX-both.img`（引导用那份能跑的、app 用我们的）。

## 7. 附录：对照固件的组件清单（`upgcmd -i`）

```
image.updater.psram   size 0x8D10  RAM 0x30043000  required;run
image.updater.spl     size 0x3E610 RAM 0x40100000  required;run
image.info            size 0x800
image.target.spl      part spl    size 0x3E610
image.target.env      part env    size 0x1000   CRC 0xCE19208A
image.target.env_r    part env_r  size 0x1000   CRC 0xCE19208A
image.target.os       part os     size 0x113800 CRC 0xD78CF26B
image.target.rodata   part rodata size 0x46F000 CRC 0xA7A7350B
image.target.data     part data   size 0x41000  CRC 0x8DAF463E
```
