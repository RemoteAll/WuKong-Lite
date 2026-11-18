# 全量迁移执行清单（Backlog）

> 审计依据：`docs/MIGRATION_AUDIT.md`。本清单把缺口拆成可执行项，每项写**验证基线**与**状态**。
> 状态：✅ 已完成 / 🟡 进行中 / ⬜ 未开始 / ⏸ 明确不做（设备侧保留官方 SDK）。
> 原则：先做能独立验证的主机侧格式/工具；设备侧（bootloader/RTOS/HAL）不重复实现。

## P0 · 上板与协议

| ID | 项目 | 状态 | 验证基线 | 说明 |
|----|------|------|----------|------|
| P0-1 | bootloader/PBP 资源打包（`mk_prebootprog.py`、`mk_private_resource.py`、`spienc`） | 🟡 | PBP/私有资源均与参考逐字节一致 | `mk_prebootprog`、`mk_private_resource` 已完成；spienc 保留官方 |
| P0-2 | RTOS 内核（rt-thread/freertos/ucos-ii）与 HAL 驱动 | ⏸ | 官方 SDK | 同上；本仓库只做 OSAL/设备框架模拟 |
| P0-3 | 主机烧写协议（upgcmd 源码 / UART USB 客户端） | 🟡 | 帧编码/解码与参考 `aicupg_client.py` **逐字节一致**（2026-11-18） | 主机源码未公开；已按开源设备端 `lib/aicupg` 与 `docs/official/skills/aiburn` 的 Python 客户端实现**帧层**（`AA55/ver/cmd/len/CRC16-CCITT/55AA`，`wk upg frame|decode`）；烧写流程（burn/upload/串口或 TCP 传输）待做；`upgcmd -e` 可作对照 |
| P0-4 | 上游文档同步机制 | ✅ | `tools/sync-upstream.ps1 -Check` 退出 0 | 2026-11-17 建立，10 个文件 + `UPSTREAM.json` |

## P1 · 镜像与安全

| ID | 项目 | 状态 | 验证基线 | 下一步 |
|----|------|------|----------|--------|
| P1-1 | FAT32 / `--fullpart` / AICF `dirent_*` | ✅ | FAT32 + fullpart 均用 `mcopy` 回读；AICF length=32、dirent=0 与参考一致 | 2026-11-17 完成 |
| P1-2 | littlefs 镜像（`makelittlefs.py`） | ✅ | `mklittlefs -l/-u` 可列出/解包；多文件嵌套内容一致 | 2026-11-18 完成（复用上游 littlefs 2.5） |
| P1-3 | uffs 镜像（`makeuffs.py`） | ⛔ 受阻 | —— | 参考 `mkuffs.exe` 只是外壳，UFFS 文件系统实现（树/页状态/ECC）**不在本 SDK 源码内**（`bsp/artinchip/drv/spinand/uffs.c` 只含移植层，RT-Thread `components/dfs/filesystems` 无 uffs）。需引入上游 uffs 源码才可对齐，暂不猜测实现 |
| P1-4 | `firmware_security_encrypt`（AES-XTS/nonce/tweak） | ⛔ 受阻 | 已实测模式特征（见下） | 工具为预编译 exe，SDK 无源码。**实测事实**：只读密钥文件前 16 B（AES-128）；输入必须是 16 的整数倍、无填充；改明文第 2 块只影响第 2~N 块（前向链式）；已排除 ECB / CBC / CTR(XOR 流) / 纯 XTS 结构。无源码情况下不猜测实现，留待上游公开 |
| P1-5 | `encrypt_rsa_key.py` | ✅ | `wk image rsakey` 与参考脚本**逐字节一致**（私钥 AES/DES 加密、公钥 PKCS#1/SPKI 四种组合） | 2026-11-18 完成；公钥+对称密钥参考脚本自身会崩，我们按语义实现并写明差异 |
| P1-6 | ITS `signature*`/`cipher` 节点 + AIC 头签名/加密联动 | 🟡 | `mkimage` 签名 FIT + 我们解析 | 独立 RSA/AES 已有；补节点生成与头字段 |
| P1-7 | `mkcpio` OTA（`ota-subimgs.cfg`、`ota_info.bin`、尺寸回填） | ✅ | `wk image ota` 生成 512B env + crc cpio；`cpio.exe -it` 可列出；size 回填实测 1024 | 2026-11-17 完成 |
| P1-8 | `simg_dump` 等价 CLI | ✅ | `wk image simg --dump` 输出头/chunk 表，单测覆盖 | 2026-11-17 完成 |

## P2 · 主机辅助工具

| ID | 项目 | 状态 | 验证基线 | 说明 |
|----|------|------|----------|------|
| P2-1 | `merge_files.py` | ✅ | `wk image merge` 按顺序字节拼接，实测 1,2,3 + 4,5 + 6,7,8,9 → 1..9 | 2026-11-17 完成 |
| P2-2 | `calc_linked_addr.py` | ✅ | `wk image linkaddr`：MEM_AUTO/显式 TEXT_BASE + 4 占位符替换；实测 text=0x400ef000/load=0x400eef00 | 2026-11-17 完成 |
| P2-3 | `linked_size.py` | ✅ | `wk image linksize` 生成 summary/detail/dironly；hello_uart.map 与参考 summary 完全一致（382=187+84+111） | 2026-11-17 完成 |
| P2-4 | `gen_partition_file_list.py` / `partition_check.py` | ✅ | `partlist` 与参考 D13x 输出一致；`partcheck` 在 50%/125% 样本上与参考表格、`--strict` 退出码一致 | 2026-11-18 完成 |
| P2-5 | `fsinstall.py` / `config_update.py` / `rtt2freertos.py` / `sdk_update.py` / `release_patch.py` / `panic_parse.py` / `build_mini_bootloader.py` | 🟡 | `wk fs install/clean`、`wk sdk-update`、`wk panic`、`wk rtt2freertos` 实测通过 | 2026-11-18：`rtt2freertos.py` → `wk rtt2freertos`（**28 个官方 rt-thread 方案输出与参考逐字节一致**，忽略行尾）。剩下 `config_update.py`（交互式 menuconfig，无 TUI 需求）、`release_patch.py`、`build_mini_bootloader.py` 待做 |
| P2-6 | 官方文档 `topics/` 464 篇 + images/webhelp | ⬜ | 目录/链接完整性 | 体积大，建议按需生成离线包，不全量入库 |

## P3 · 生态与二进制

| ID | 项目 | 状态 | 说明 |
|----|------|------|------|
| P3-1 | `packages/artinchip`（ota/lvgl-ui/mpp/zipfs/uds 等 19 个） | ⏸ | 设备侧中间件，保留官方 |
| P3-2 | `packages/third-party`（lwIP/mbedTLS/cherryusb/sqlite/LVGL/MicroPython 等 44 个） | ⏸ | 同上 |
| P3-3 | `crc32/xxd/sed/cat/truncate` 等 exe | ✅ | 功能已被 Zig 实现覆盖；不迁移二进制 |
| P3-4 | `mtools`（mformat/mcopy） | ✅ | 已验证参考二进制可用，不重写 |

## 本轮建议顺序（2026-11-18 更新）

1. ~~P1-5 `encrypt_rsa_key`~~ ✅
2. ~~P2-5 `sdk_update.py` / `panic_parse.py` / `rtt2freertos.py`~~ ✅
3. P2-5 余项：`release_patch.py`（发布补丁）、`build_mini_bootloader.py`（子构建编排，需 SCons 环境）
4. P0-3 主机烧写协议：按开源设备端 `lib/aicupg` 实现 UART 客户端（无 DLL 依赖）
5. P1-6 ITS `signature*`/`cipher` 节点 + AIC 头签名/加密联动（独立 RSA/AES 已就绪）
6. P1-3 / P1-4 待上游源码（uffs 核心、firmware_security_encrypt），不猜测实现

每个条目完成时：补单测/样本 → 与参考工具比对 → 在本表改状态 → `docs/决策记录.md` 记一条（含用户原话）。
