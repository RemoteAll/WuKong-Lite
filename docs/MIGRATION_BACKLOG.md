# 全量迁移执行清单（Backlog）

> 审计依据：`docs/MIGRATION_AUDIT.md`。本清单把缺口拆成可执行项，每项写**验证基线**与**状态**。
> 状态：✅ 已完成 / 🟡 进行中 / ⬜ 未开始 / ⏸ 明确不做（设备侧保留官方 SDK）。
> 原则：先做能独立验证的主机侧格式/工具；设备侧（bootloader/RTOS/HAL）不重复实现。

## P0 · 上板与协议

| ID | 项目 | 状态 | 验证基线 | 说明 |
|----|------|------|----------|------|
| P0-1 | bootloader/PBP 资源打包（`mk_prebootprog.py`、`mk_private_resource.py`、`spienc`） | 🟡 | PBP/私有资源均与参考逐字节一致 | `mk_prebootprog`、`mk_private_resource` 已完成；spienc 保留官方 |
| P0-2 | RTOS 内核（rt-thread/freertos/ucos-ii）与 HAL 驱动 | ⏸ | 官方 SDK | 同上；本仓库只做 OSAL/设备框架模拟 |
| P0-3 | 主机烧写协议（upgcmd 源码 / UART USB 客户端） | 🟡 | 帧层/请求载荷与参考逐字节一致；TCP 会话 mock server 对拍 6 项全过；**读写超时实测 0.51 s 生效** | 已实现 `upg_frame`、`upg_payload`、`upg_client`（TCP，`--timeout` 走 `tcp.zig` 的 `SO_RCVTIMEO`）；CLI `wk upg … --send [--server-host/--server-port]`。**待做**：串口传输、分块上传循环与进度回执、真实 upgcmd server/设备联调 |
| P0-4 | 上游文档同步机制 | ✅ | `tools/sync-upstream.ps1 -Check` 退出 0 | 2026-11-17 建立，10 个文件 + `UPSTREAM.json` |

## P1 · 镜像与安全

| ID | 项目 | 状态 | 验证基线 | 下一步 |
|----|------|------|----------|--------|
| P1-1 | FAT32 / `--fullpart` / AICF `dirent_*` | ✅ | FAT32 + fullpart 均用 `mcopy` 回读；AICF length=32、dirent=0 与参考一致 | 2026-11-17 完成 |
| P1-2 | littlefs 镜像（`makelittlefs.py`） | ✅ | `mklittlefs -l/-u` 可列出/解包；多文件嵌套内容一致 | 2026-11-18 完成（复用上游 littlefs 2.5） |
| P1-3 | uffs 镜像（`makeuffs.py`） | ⛔ 受阻 | —— | 参考 `mkuffs.exe` 只是外壳，UFFS 文件系统实现（树/页状态/ECC）**不在本 SDK 源码内**（`bsp/artinchip/drv/spinand/uffs.c` 只含移植层，RT-Thread `components/dfs/filesystems` 无 uffs）。需引入上游 uffs 源码才可对齐，暂不猜测实现 |
| P1-4 | `firmware_security_encrypt`（AES-XTS/nonce/tweak） | ⛔ 受阻 | 已实测模式特征（见下） | 工具为预编译 exe，SDK 无源码。**实测事实**：只读密钥文件前 16 B（AES-128）；输入必须是 16 的整数倍、无填充；改明文第 2 块只影响第 2~N 块（前向链式）；已排除 ECB / CBC / CTR(XOR 流) / 纯 XTS 结构。无源码情况下不猜测实现，留待上游公开 |
| P1-5 | `encrypt_rsa_key.py` | ✅ | `wk image rsakey` 与参考脚本**逐字节一致**（私钥 AES/DES 加密、公钥 PKCS#1/SPKI 四种组合） | 2026-11-18 完成；公钥+对称密钥参考脚本自身会崩，我们按语义实现并写明差异 |
| P1-6 | ITS `signature*`/`cipher` 节点 + AIC 头签名/加密联动 | ✅ | `wk image aicimage` 与 `mk_image.py -p` **6 组镜像逐字节一致**（RSA-2048/HMAC、AES-128-CBC 含 SSK 派生、MD5+校验和、with_ext） | 2026-11-19 完成。ITS 签名节点经实测**不适用**：本 SDK 的 `mkimage.exe` 打印 “Signing / verified boot not supported”。未支持：SM2/SM4/ChaCha20/AES-CTR、pbp2/private2（遇配置即报错） |
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

## 回归守卫（2026-11-18 建立）

- **一键回归入口**：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1`
  → 构建 → **112** 单测 → 夹具自建 → 17 个顶层命令 → 30 条 image 子命令 → fs/upg →
  3 个 python 对拍（会话收发 / 读超时 / AIC 镜像签名加密）；
  退出码 0/1，报告 `artifacts/regression/report-<时间戳>.txt`。
- **阈值只能抬高**：`MinTests=112`、`MinCases=34`；降阈值必须在决策记录里写实测依据。
- **破坏性用例一律不碰仓库文件**：`fs clean` 等在自己的 `work-*/` 目录里造夹具。
- **新增功能必须同时加用例**；确实无法自动化的留 `SKIP` + 原因（禁止静默跳过）。
- 会话对拍脚本：`tools/checks/check_upg_send.py`（mock 服务端 6 项）、
  `tools/checks/check_upg_timeout.py`（静默服务端超时 ≤2 s 且已发出请求帧）、
  `tools/checks/check_aicimage.py`（6 组 AIC 启动镜像与 `mk_image.py -p` 逐字节比对，
  夹具在 `tools/checks/fixtures/aicimage_*.json`；参考 SDK 缺失时 SKIP 并说明原因）。

