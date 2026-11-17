# 全量迁移执行清单（Backlog）

> 审计依据：`docs/MIGRATION_AUDIT.md`。本清单把缺口拆成可执行项，每项写**验证基线**与**状态**。
> 状态：✅ 已完成 / 🟡 进行中 / ⬜ 未开始 / ⏸ 明确不做（设备侧保留官方 SDK）。
> 原则：先做能独立验证的主机侧格式/工具；设备侧（bootloader/RTOS/HAL）不重复实现。

## P0 · 上板与协议

| ID | 项目 | 状态 | 验证基线 | 说明 |
|----|------|------|----------|------|
| P0-1 | bootloader/PBP 资源打包（`mk_prebootprog.py`、`mk_private_resource.py`、`spienc`） | ⏸ | 官方 SDK 产物 | 与官方 bootloader 强绑定，按用户口径保留官方实现 |
| P0-2 | RTOS 内核（rt-thread/freertos/ucos-ii）与 HAL 驱动 | ⏸ | 官方 SDK | 同上；本仓库只做 OSAL/设备框架模拟 |
| P0-3 | 主机烧写协议（upgcmd 源码 / UART USB 客户端） | ⬜ | 开源设备端 `lib/aicupg` | 主机源码未公开；可先实现 UART 协议子集，`upgcmd -e` 作为对照 |
| P0-4 | 上游文档同步机制 | ✅ | `tools/sync-upstream.ps1 -Check` 退出 0 | 2026-11-17 建立，10 个文件 + `UPSTREAM.json` |

## P1 · 镜像与安全

| ID | 项目 | 状态 | 验证基线 | 下一步 |
|----|------|------|----------|--------|
| P1-1 | FAT32 / `--fullpart` / AICF `dirent_*` | 🟡 | 参考 `makefatfs.py` + `mcopy` 回读 | 先补 FAT32 格式化/目录项；再做 fullpart 与 dirent 列表 |
| P1-2 | littlefs 镜像（`makelittlefs.py`） | ⬜ | 参考 `mklittlefs.exe` 产物逐字节/挂载回读 | 先解析参数与 superblock，再实现块分配 |
| P1-3 | uffs 镜像（`makeuffs.py`） | ⬜ | 参考 `mkuffs.exe` 产物 | 依赖 littlefs 经验，排在 P1-2 后 |
| P1-4 | `firmware_security_encrypt`（AES-XTS/nonce/tweak） | ⬜ | 参考 exe 加密结果逐字节 | 先确认密钥/nonce 派生与镜像布局 |
| P1-5 | `encrypt_rsa_key.py` | ⬜ | 参考脚本输出 | 与 P1-4 共用密钥封装 |
| P1-6 | ITS `signature*`/`cipher` 节点 + AIC 头签名/加密联动 | 🟡 | `mkimage` 签名 FIT + 我们解析 | 独立 RSA/AES 已有；补节点生成与头字段 |
| P1-7 | `mkcpio` OTA（`ota-subimgs.cfg`、`ota_info.bin`、尺寸回填） | ✅ | `wk image ota` 生成 512B env + crc cpio；`cpio.exe -it` 可列出；size 回填实测 1024 | 2026-11-17 完成 |
| P1-8 | `simg_dump` 等价 CLI | ✅ | `wk image simg --dump` 输出头/chunk 表，单测覆盖 | 2026-11-17 完成 |

## P2 · 主机辅助工具

| ID | 项目 | 状态 | 验证基线 | 说明 |
|----|------|------|----------|------|
| P2-1 | `merge_files.py` | ✅ | `wk image merge` 按顺序字节拼接，实测 1,2,3 + 4,5 + 6,7,8,9 → 1..9 | 2026-11-17 完成 |
| P2-2 | `calc_linked_addr.py` | ✅ | `wk image linkaddr`：MEM_AUTO/显式 TEXT_BASE + 4 占位符替换；实测 text=0x400ef000/load=0x400eef00 | 2026-11-17 完成 |
| P2-3 | `linked_size.py` | ⬜ | 参考脚本输出 | 统计段/符号尺寸 |
| P2-4 | `gen_partition_file_list.py` / `partition_check.py` | ⬜ | 参考输出 | 依赖现有分区表解析 |
| P2-5 | `fsinstall.py` / `config_update.py` / `rtt2freertos.py` / `sdk_update.py` / `release_patch.py` / `panic_parse.py` / `build_mini_bootloader.py` | ⬜ | 逐脚本对照 | 按实际使用频率排序 |
| P2-6 | 官方文档 `topics/` 464 篇 + images/webhelp | ⬜ | 目录/链接完整性 | 体积大，建议按需生成离线包，不全量入库 |

## P3 · 生态与二进制

| ID | 项目 | 状态 | 说明 |
|----|------|------|------|
| P3-1 | `packages/artinchip`（ota/lvgl-ui/mpp/zipfs/uds 等 19 个） | ⏸ | 设备侧中间件，保留官方 |
| P3-2 | `packages/third-party`（lwIP/mbedTLS/cherryusb/sqlite/LVGL/MicroPython 等 44 个） | ⏸ | 同上 |
| P3-3 | `crc32/xxd/sed/cat/truncate` 等 exe | ✅ | 功能已被 Zig 实现覆盖；不迁移二进制 |
| P3-4 | `mtools`（mformat/mcopy） | ✅ | 已验证参考二进制可用，不重写 |

## 本轮建议顺序（2026-11-17）

1. P1-8 `simg --dump`（最小、可直接对照文本）
2. P2-1 `merge_files`（纯字节操作，易逐字节验证）
3. P1-7 mkcpio OTA（补尺寸回填，能直接服务烧写）
4. P1-1 FAT32（工作量大，单独一轮）
5. P1-2/3 littlefs/uffs（先拿参考 exe 做黑盒对照）

每个条目完成时：补单测/样本 → 与参考工具比对 → 在本表改状态 → `docs/决策记录.md` 记一条（含用户原话）。
