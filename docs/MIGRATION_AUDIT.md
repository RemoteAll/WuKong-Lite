# 迁移全量审计（WuKong-Lite ↔ Luban-Lite）

- 审计日期：2026-11-17
- 参考实现：`G:\Code\C\luban-lite`（Luban-Lite SDK，官方仓库 `artinchip/luban-lite`）
- 被审计仓库：`G:\Code\Zig\WuKong-Lite`
- 结论：**主机侧“镜像格式 + 打包/校验工具链”基本覆盖；设备侧（bootloader/RTOS/HAL）
  与部分主机工具（littlefs/uffs/PBP/SPIENC/OTA）尚未迁移。**

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
| `mkcpio.py`（OTA） | `src/tools/ota.zig`、`wk image ota` | 512B env + crc cpio + size 回填；`cpio.exe -it` 可列出（2026-11-17） |
| `merge_files.py` | `src/tools/merge.zig`、`wk image merge` | 按序拼接，字节实测通过（2026-11-17） |
| `openssl`（AES/RSA 子集） | `crypt.zig`、`rsa.zig` | AES 双向逐字节；RSA 与 openssl 互通 |
| `upgcmd`（使用侧） | `tools/fetch-upgcmd-deps.ps1`、`flash-*.ps1` | `-e` 解析本仓库 AIC.FW |
| Kconfig/defconfig/codegen | `kconfig.zig`、`codegen.zig`、`modules.zig` | 单测覆盖 |
| AIBURN 文档/客户端 | `docs/official/skills/aiburn/` | 可运行（需 server） |

## 3. 部分迁移（🟡，有明确缺口）

| 官方 | 已做 | 缺口 |
|------|------|------|
| `makefatfs.py` | FAT12/16、LFN、`--auto` 尺寸 | FAT32、`--fullpart`、AICF `dirent_*` 列表、`fatupdate` 的 used_size 口径 |
| `mkimage` 签名/加密 | 独立 RSA/AES 工具 | ITS `signature*`/`cipher` 节点、AIC 头 `sign_algo/encrypt_algo`/iv 区间联动 |
| `aic_build.py` | Kconfig→build_plan→codegen | SCons 全量构建、链接脚本/工具链选择、镜像后处理流水线 |
| 官方文档 | aiburn 技能 | `topics/` 464 篇、`images/`、`webhelp/` 未迁（体积原因，可按需） |
| 板级方案 | 1 个 Kconfig 方案 | d12x/d21x/多板 `target` 与 `pack/image_cfg.json` |

## 4. 未迁移（🔴）

### P0：影响“自己独立上板”
- **bootloader/PBP**：`application/baremetal/bootloader`、`mk_prebootprog.py`、
  `mk_private_resource.py`、`spienc/spienctool`、`d13x.pbp/pbp_cfg.bin` 资源打包；
- **RTOS 内核**：`application/rt-thread`、`freertos`、`ucos-ii`；`kernel/` 适配；
- **HAL/驱动**：41 类 `bsp/artinchip/drv`（显示/存储/网络/音频/USB/安全等）；
- **烧写协议**：主机端 `upgcmd` 源码（内部 `aicupg`）、USB/UART 协议实现。

### P1：镜像与安全能力
- 文件系统镜像：`makelittlefs.py`、`makeuffs.py`（littlefs/uffs）；
- 固件加密：`firmware_security_encrypt`（含 nonce/tweak 的 AES-XTS 类流程）、
  `encrypt_rsa_key.py`、SPIENC/eFuse 安全启动；
- `mkimage` 的 RSA/SM2 签名节点、公钥内嵌、`-K` 更新 dtb；
- 镜像辅助脚本：`calc_linked_addr.py`、`linked_size.py`、
  `gen_partition_file_list.py`、`partition_check.py`、`fsinstall.py`、
  `config_update.py`、`rtt2freertos.py`、`sdk_update.py`、`release_patch.py`、
  `panic_parse.py`、`build_mini_bootloader.py`。

### P2：中间件/生态
- `packages/artinchip`：ota、xip_ramcode、zipfs、uds、barcode、lvgl-ui、mpp、
  aic-startup-ui、pinmux-check、thread_stack_trace、profiler 等；
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
  3. 补 littlefs/uffs 与 FAT32，覆盖剩余镜像类型；
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
