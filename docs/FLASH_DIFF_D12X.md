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

我方少了两种 PSRAM 型号的配置条目（在二进制里按型号 ID 计数）：

| PSRAM 型号 | 对照固件出现次数 | 我方 |
|-----------|-----------------|------|
| APS3208K（D123BBV 用的就是它） | 13 | 13 ✓ |
| W955D8MKY | 6 | 6 ✓ |
| APS12816O | 5 | 5 ✓ |
| APS25616O | 2 | 2 ✓ |
| **W957D6NKR** | **3** | **0** ✗ |
| **W956D8NKR** | **3** | **0** ✗ |
| APS6408L | 3 | 2（少 1） |

> D123BBV 的 mark_id 是 0x08 → `PSRAM_FUSE_APS3208K`（`bsp/artinchip/sys/d12x/ram_param.c`），
> 这条我方是有的，所以**单看型号表不足以解释失败**；但两者内嵌的 `d12x.pbp`（PreBootProgram 二进制）
> 整体不是同一份（我方在对照 aic 里找不到自己的 pbp 字节串），说明**版本不同**。

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

## 5. 烧写注意（与镜像无关，但影响成功率）

1. **波特率别用 3M**。截图显示选 3M、实测只有 10.7 KB/s ≈ 115200 的吞吐，说明升速没成功。
   命令行烧写请显式指定，并保留完整日志：

   ```
   wk\image\tools\upgcmd\upgcmd.exe -u COM25 -b 921600 -p -v image "<img 文件>"
   ```

   `-v` 会打印握手、每个组件的进度与错误码，比 AiBurn 的"执行失败"信息量大得多。
2. 勾选 **"烧写成功后重启设备"**；若仍失败，再试 **"全片擦除"**（对照固件能成功，说明链路本身没问题）。
3. 烧写前可先自检镜像：`upgcmd.exe -i <img>` 应列出 9 个 FWC 且 platform=d12x。

## 6. 附录：对照固件的组件清单（`upgcmd -i`）

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
