# 迁移全量审计（WuKong-Lite ↔ Luban-Lite）

- 审计日期：2026-11-18
- 参考实现：`G:\Code\C\luban-lite`（Luban-Lite SDK，官方仓库 `artinchip/luban-lite`）
- 被审计仓库：`G:\Code\Zig\WuKong-Lite`
- 结论：**主机侧“镜像格式 + 打包/校验工具链”基本覆盖；设备侧（bootloader/RTOS/HAL）
  与部分主机工具（uffs/PBP/SPIENC/OTA）尚未迁移。**

## 1. 总览

| 层 | 官方规模 | 已迁移 | 状态 |
|----|----------|--------|------|
| 镜像格式/打包脚本（`tools/scripts`） | 47 个脚本/工具 | ~10 个等价实现（另有 5 个部分实现） | 🟡 核心链路可用 |
| 板级驱动（`bsp/artinchip/drv`） | 42 类 | 2 类模拟（uart0/gpio0） | 🔴 仅占位 |
| 运行形态（`application`） | baremetal / rt-thread / freertos / ucos-ii | 仅 OSAL/设备框架模拟 | 🔴 无 RTOS 内核 |
| 厂商包（`packages/artinchip`） | 19 个 | 0 | 🔴 |
| 第三方包（`packages/third-party`） | 44 个 | 0（仅实现若干格式） | 🔴 |
| 板级方案（`target`） | d12x/d13x/d21x 多板 | 1 个 Kconfig 方案（demo88-nor 风格） | 🟡 |
| 官方文档（`doc`） | topics 464 篇 + webhelp/images | 仅 `skills/aiburn` + 3 篇自写说明 | 🟡 |
| 烧写主机端 | `upgcmd`（预编译）+ AiBurn GUI | upgcmd 可运行 + 脚本编排 | 🟡 无源码 |

## 2. 已迁移并有验证（✅）

| 官方 | 我们的实现 | 验证 |
|------|------------|------|
| `mk_image.py`（AIC.FW 打包） | `src/tools/pack.zig` | 组件/CRC/顺序；`upgcmd -e` 可解析 |
| `mkenvimage` | `src/bsp/common/env_image.zig` | 与参考 SHA256 一致 |
| `gen_partition_table.py` | `src/tools/partition_table.zig` | 内容一致（忽略 CRLF） |
| `mkimage`（FIT/ITS） | `src/tools/fdt.zig`、`itb.zig`、`its.zig`、`fdt_reader.zig` | 逻辑树一致；hash 校验通过 |
| `elf2image`（段提取/ITS） | `src/tools/elf2aic.zig` | 段哈希一致 |
| `img2simg` | `src/tools/sparse.zig` | 11 组样本 + FAT 镜像逐字节一致 |
| `simg_dump.py` | `wk image simg --dump` | 头部/chunk 表文本 + 单测（2026-11-17） |
| `cpio -H crc` | `src/tools/cpio.zig` | 参考 cpio 可解包；结构一致 |
| `makefatfs.py` | `src/tools/fat.zig` | FAT12/16/32、LFN、`--auto`、`--fullpart`；`mcopy` 回读通过（2026-11-17） |
| `mkcpio.py`（OTA） | `src/tools/ota.zig`、`wk image ota` | 512B env + crc cpio + size 回填；`cpio.exe -it` 可列出（2026-11-17） |
| `merge_files.py` | `src/tools/merge.zig`、`wk image merge` | 按序拼接，字节实测通过（2026-11-17） |
| `calc_linked_addr.py` | `src/tools/linkaddr.zig`、`wk image linkaddr` | MEM_AUTO/显式 TEXT_BASE + 4 占位符替换；实测通过（2026-11-17） |
| `linked_size.py` | `src/tools/linksize.zig`、`wk image linksize` | summary/detail/dironly CSV；hello_uart.map 与参考 summary 一致（2026-11-17） |
| `gen_partition_file_list.py` | `src/tools/partlist.zig`、`wk image partlist` | D13x 配置输出 6 项与参考完全一致（2026-11-18） |
| `partition_check.py` | `src/tools/partcheck.zig`、`wk image partcheck` | 50%/125% 样本表格与 `--strict` 退出码同参考；jffs2/UBI 规则已覆盖（2026-11-18） |
| `makelittlefs.py` | `src/tools/littlefs.zig`、`wk image littlefs` | 复用上游 littlefs 2.5；`mklittlefs -l/-u` 验证多文件/嵌套内容一致（2026-11-18） |
| `fsinstall.py` | `src/tools/fsinstall.zig`、`wk fs install/clean` | 递归安装/单文件安装/清理；内容 SHA256 一致（2026-11-18） |
| `mk_prebootprog.py` | `src/tools/preboot.zig`、`src/tools/des.zig`、`wk image pbp` | 明文与 PNK 加密 PBP 均与参考逐字节一致（512 B，DIFF=0；2026-11-18） |
| `mk_private_resource.py` | `src/tools/privres.zig`、`wk image privres` | `pbp_cfg.json` 1712 B、`pbp_security.json` 52 B 均与参考逐字节一致（2026-11-18） |
| `encrypt_rsa_key.py` | `src/tools/rsa_key.zig`、`wk image rsakey` | 私钥 AES/DES 加密 + 公钥 PKCS#1/SPKI 四种组合与参考脚本**逐字节一致**（2026-11-18） |
| `sdk_update.py` | `src/tools/sdk_update.zig`、`wk sdk-update` | 同一 pinmux.c 样本，忽略行尾后与参考脚本输出逐行一致；已修复文件幂等（2026-11-18） |
| `panic_parse.py` | `src/tools/panic.zig`、`wk panic` | 同一 panic 日志 + `d13x.elf`，与参考脚本输出**逐行一致**（寄存器/栈回溯/地址定位；2026-11-18） |
| `rtt2freertos.py` | `src/tools/rtt2freertos.zig`、`wk rtt2freertos` | 28 个官方 `*_rt-thread_*_defconfig` 全部转换，与参考脚本输出**逐字节一致**（忽略 Windows CRLF；2026-11-18） |
| `aicupg_client.py`（帧层） | `src/tools/upg_frame.zig`、`wk upg frame|decode` | 7 组命令/payload 编码与参考客户端**逐字节一致**；4 组 CRC、5 类损坏帧拒绝行为一致（2026-11-18） |
| `aicupg_client.py`（请求层） | `src/tools/upg_payload.zig`、`wk upg <请求子命令>` | 15 组请求（task_id / config-device UART+USB / burn 两种 / send-cmd / get-log / upload-start / task-id 覆盖）帧字节与参考一致（2026-11-18） |
| `openssl`（AES/RSA 子集） | `crypt.zig`、`rsa.zig` | AES 双向逐字节；RSA 与 openssl 互通 |
| `upgcmd`（使用侧） | `tools/fetch-upgcmd-deps.ps1`、`flash-*.ps1` | `-e` 解析本仓库 AIC.FW |
| Kconfig/defconfig/codegen | `kconfig.zig`、`codegen.zig`、`modules.zig` | 单测覆盖 |
| AIBURN 文档/客户端 | `docs/official/skills/aiburn/` | 可运行（需 server） |

## 3. 部分迁移（🟡，有明确缺口）

| 官方 | 已做 | 缺口 |
|------|------|------|
| `mkimage` 签名/加密 | 独立 RSA/AES 工具 | ITS `signature*`/`cipher` 节点、AIC 头 `sign_algo/encrypt_algo`/iv 区间联动 |
| `aic_build.py` | Kconfig→build_plan→codegen | SCons 全量构建、链接脚本/工具链选择、镜像后处理流水线 |
| 官方文档 | aiburn 技能 | `topics/` 464 篇、`images/`、`webhelp/` 未迁（体积原因，可按需） |
| 板级方案 | 1 个 Kconfig 方案 | d12x/d21x/多板 `target` 与 `pack/image_cfg.json` |

## 4. 未迁移（🔴）

### P0：影响“自己独立上板”
- **bootloader/PBP**：`application/baremetal/bootloader`、`spienc/spienctool`、
  `d13x.pbp/pbp_cfg.bin` 资源打包；
- **RTOS 内核**：`application/rt-thread`、`freertos`、`ucos-ii`；`kernel/` 适配；
- **HAL/驱动**：41 类 `bsp/artinchip/drv`（显示/存储/网络/音频/USB/安全等）；
- **烧写协议**：主机端 `upgcmd` 源码（内部 `aicupg`）、USB/UART 协议实现。

### P1：镜像与安全能力
- 文件系统镜像：`makeuffs.py`（uffs）—— **受阻**：本 SDK 只带 `mkuffs.exe` 外壳与
  `drv/spinand/uffs.c` 移植层，UFFS 核心（树/页状态/ECC）源码不在仓库内，无依据不可猜实现；
- 固件加密：`firmware_security_encrypt`（含 nonce/tweak）—— **受阻**：预编译 exe，SDK 无源码。
  实测特征：只取密钥文件前 16 B（AES-128）、输入需 16 B 对齐且不填充、改动一块明文会影响其后所有块
  （前向链式）、已排除 ECB/CBC/CTR(XOR 流)；其余待上游公开后对齐。
  `encrypt_rsa_key.py` 已完成（见 ✅ 表）；SPIENC/eFuse 安全启动仍保留官方工具；
- `mkimage` 的 RSA/SM2 签名节点、公钥内嵌、`-K` 更新 dtb；
- 镜像辅助脚本：`config_update.py`（交互式 menuconfig，无 TUI 需求）、`release_patch.py`、
  `build_mini_bootloader.py`。
  （`sdk_update.py` → `wk sdk-update`、`panic_parse.py` → `wk panic`、
  `rtt2freertos.py` → `wk rtt2freertos` 已完成，见 ✅ 表）

### P2：中间件/生态
- `packages/artinchip`：ota、xip_ramcode、zipfs、uds、barcode、lvgl-ui、mpp、
  aic-startup-ui、pinmux-check、thread_stack_trace、profiler 等；
- **GUI 支持范围**：官方仅集成 LVGL（`application/Kconfig` 的 `LPKG_USING_LVGL`
  可选 V8/V9，`packages/artinchip/lvgl-ui` 提供 LVGL 与 demo）；未发现 AWTK/emWin/
  Qt/GuiLite 等其它 GUI 包。显示/MPP 驱动与 GUI 解耦，第三方 GUI 需自行移植；
  WuKong-Lite 侧 GUI/显示仍属设备侧未迁移部分。
- `packages/third-party`：lwIP、mbedTLS、littlefs、cherryusb、sqlite、LVGL、
  MicroPython、蓝牙/WiFi、音视频编解码等；
- 官方文档全量离线站（topics/images/webhelp）。

### P3：主机便利工具
- `crc32/xxd/sed/cat/truncate` 等 exe（功能已被 Zig 实现覆盖，不需要二进制迁移）；
- `mtools`（mformat/mcopy）——已验证可用参考二进制，未重写。

## 5. 与“能不能烧写/跑起来”的关系

- **能做的**：用官方 bootloader/OS → `wk image flashpack` → `flash-upgcmd.ps1`
  烧写；或用 `upgcmd write/exec` 直接跑本仓库的 Zig 裸机 `hello_uart`。
- **不能独立做的**：没有 bootloader/PBP 与 RTOS/HAL，WuKong-Lite 无法单独产出
  “可启动的完整固件”；这不是格式问题，是设备侧代码缺失。
- **建议优先级**：
  1. （如可获取）接入厂商 `aicupg` 主机源码，替换预编译 upgcmd；
  2. 按开源设备端 `lib/aicupg` 实现 UART 主机客户端（无 DLL 依赖）；
  3. 补 uffs 与 SPIENC/PBP 镜像类型；
  4. 按板卡逐步补 HAL（先 UART/GPIO/时钟，再存储/显示）。

## 6. 审计复现命令

```powershell
# 参考规模
(Get-ChildItem G:\Code\C\luban-lite\tools\scripts -File).Count
(Get-ChildItem G:\Code\C\luban-lite\bsp\artinchip\drv -Directory).Count
(Get-ChildItem G:\Code\C\luban-lite\packages\artinchip -Directory).Count
(Get-ChildItem G:\Code\C\luban-lite\packages\third-party -Directory).Count
(Get-ChildItem G:\Code\C\luban-lite\doc\topics -Recurse -File -Filter *.html).Count

# 我方能力
Get-ChildItem src -Recurse -File -Filter *.zig | Measure-Object
.\zig-out\bin\wk.exe
zig build test
```
