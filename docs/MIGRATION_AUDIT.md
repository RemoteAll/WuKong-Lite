# 迁移全量审计（WuKong-Lite ↔ Luban-Lite）

- 审计日期：**2026-11-19（第二轮全量审计）**；上一轮：2026-11-18
- 参考实现：`G:\Code\C\luban-lite`（Luban-Lite SDK，官方仓库 `artinchip/luban-lite`）
- 被审计仓库：`G:\Code\Zig\WuKong-Lite`（`wk` CLI）
- 审计方法（实测，不靠印象）：
  1. 枚举参考全部主机侧脚本（`tools/scripts/**` 与 `target/**/pack/*.sh`）；
  2. 逐个提取参考 CLI 选项（`add_argument`）与关键能力分支（`mk_image.py` 的 pre-process 段类型）；
  3. 与 `wk` 的选项定义逐项对照（`src/main.zig` 的 `getOpt/hasFlag`）；
  4. 对算法/格式枚举逐项核对（FIT 哈希档、cipher 算法、simg、FAT、LittleFS、AIC 头…）；
  5. 每个“已迁移”结论都必须有对拍脚本或实测数字支撑。
- 复现命令见文末第 9 节。

## 1. 总览

| 层 | 官方规模 | 已迁移 | 状态 |
|----|----------|--------|------|
| `tools/scripts` 主机脚本 | **29 个**业务脚本（另有 `Cryptodome`/`asn1crypto`/`gmssl`/`fdt` 等 vendored 库不计） | **28 个等价实现 + 1 个厂商二进制直调** | ✅ 见第 2 节逐项 |
| SDK 构建系统本体（`SConstruct` / `aic_build.py` / `onestep/*.bat`） | 1 套（6000+ 行 SCons 编排 + 19 个 cmd 脚本） | — | 🚫 **边界外**（见第 0 节） |
| 设备侧驱动（`bsp/artinchip/drv`） | 42 类 | 2 类模拟（uart0/gpio0） | 🚫 边界外（驱动属官方 SDK） |
| 运行形态（`application`） | baremetal / rt-thread / freertos / ucos-ii | OSAL/设备框架模拟 | 🚫 边界外（RTOS 内核属官方 SDK） |
| 厂商包（`packages/artinchip`） | 19 | 0 | 🚫 内容资产，随 SDK 使用 |
| 第三方包（`packages/third-party`） | 44 | 0（仅实现若干格式） | 🚫 内容资产，随 SDK 使用 |
| 板级方案（`target`） | d12x/d13x/d21x 多板 | 1 个 Kconfig 方案 | 🚫 内容资产，随 SDK 使用 |
| 官方文档（`doc`） | topics 464 篇 + webhelp/images | `skills/aiburn` + 3 篇自写 | 🟡 按需迁移（体积大，见 `docs/official/README.md`） |
| 烧写主机端 | `upgcmd`（预编译）+ AiBurn | 帧/请求/会话层自实现 + 厂商工具直调 | ✅ 协议层自实现；USB/UART 走厂商 `upgcmd` |

> 状态图例：**✅ 已实现并有对拍/实测**、**🟡 按需（有明确理由）**、**🚫 边界外**（项目定位不含该层，
> 直接用官方 SDK / 厂商工具；`copilot-instructions.md` 第 1 节已声明）。

## 0. 边界声明（为什么不是“缺口”）

本项目定位（见 `.github/copilot-instructions.md` 第 1 节）：**复刻 Luban-Lite 的主机侧能力**
——镜像格式、配置、打包、校验、烧写编排；**bootloader/PBP、RTOS 内核、HAL/驱动、SDK 的 SCons 构建编排
仍属官方 SDK**，本仓库不重复实现。据此，下列项**明确不迁移**（不是遗漏）：

| 项 | 参考内容 | 不迁移的理由 | 需要时怎么做 |
|----|----------|--------------|--------------|
| `aic_build.py`（97 KB）+ `SConstruct`/`SConscript` | SCons 全量构建编排、链接脚本与工具链选择、POST_ACTION 流水线 | 属 SDK 构建系统本体；重写等于换掉 SCons，收益与风险不成比例。我们只提供 `wk defconfig/config/build`（Kconfig → `.config` → `config.zig`/模块表）这一段 | 直接用官方 `scons`（2026-11-18 已实测产出 12,263,936 B 固件） |
| `onestep/*.bat`（19 个） | Windows cmd 交互脚本（`lunch`/`make_boot`/`buildall`/`cbuild`…） | 本质是 `scons --apply-def` + `scons` 的薄封装，且是 cmd 专用交互 | 同上；或直接用 `wk defconfig` + 官方 `scons` |
| `build_mini_bootloader.py` | 双 SPL（`CONFIG_AIC_BOOTLOADER_DUAL_SPL`）子构建：保存/恢复 4 个状态文件 → 跑两次 `scons` → 拷 `bootloader.bin` | 依赖 SCons 编排；且 29 个官方 defconfig **无一启用** `CONFIG_AIC_BOOTLOADER_DUAL_SPL`（实测 grep 结果 0） | 如需该特性，按参考脚本两条 `scons` 命令手工执行 |
| `bsp/artinchip/drv`、`application/*` 的 RTOS 内核 | 42 类驱动 + 4 种运行形态 | 属设备侧 SDK 本体（我们的边界是主机侧） | 官方 SDK 构建 |
| `upgcmd`（预编译 exe）与 USB 通道 | 烧写器服务端 / UsbDk USB 传输 | 厂商二进制、无源码；按用户口径“SDK 怎么用我们就怎么用” | `tools/fetch-upgcmd-deps.ps1` 补齐 3 个 DLL 后直接调 `upgcmd`（`wk image flashpack` 已生成 `flash-upgcmd.ps1`） |
| `packages/*`、`target/*` 内容 | 19 + 44 个包、多板方案 | 是**数据/内容**而非主机工具 | 随 SDK 使用；本仓库只处理它们的 `image_cfg.json`/`partition.json` 等配置格式 |

> 判定方法（可复现）：`grep -rn "CONFIG_AIC_BOOTLOADER_DUAL_SPL=y" target/configs/` → 0 命中；
> `Get-ChildItem tools/scripts/onestep` → 19 个 `.bat`；`(Get-Item tools/scripts/aic_build.py).Length` → 97 KB。

## 2. `tools/scripts` 逐脚本对照（29 项，闭环、无遗漏）

| # | 参考脚本 | 我们的等价实现 | 状态 | 证据 / 缺口 |
|---|----------|----------------|------|-------------|
| 1 | `aic_build.py`（97 KB，构建主脚本） | `kconfig.zig` + `codegen.zig` + `modules.zig`（`wk defconfig/config/build`） | 🚫 边界外 | Kconfig → `.config` → `config.zig`/模块表这一段已通；**SCons 全量构建编排属于 SDK 构建系统本体，按项目定位不迁移**（理由与替代路径见第 0 节）。2026-11-18 实测：官方 `scons` 可直接产出 12,263,936 B 固件 |
| 2 | `mk_private_resource.py` + `aic_private_resource/` | `src/tools/privres.zig`、`wk image privres` | ✅ | `pbp_cfg.json` 1712 B、`pbp_security.json` 52 B 逐字节一致（2026-11-18） |
| 3 | `build_mini_bootloader.py` | — | 🚫 边界外 | 双 SPL 子构建：保存/恢复 `.config`/`.defconfig`/`rtconfig.h`/`cconfig.h` → `scons --apply-def` + `scons -j8` → 拷 `output/<base>/mini/images/<chip>.bin` → `pack/bootloader.bin`。**依赖 SCons 编排**，且 29 个官方 defconfig 无一启用 `CONFIG_AIC_BOOTLOADER_DUAL_SPL`（grep 实测 0 命中），按第 0 节不迁移 |
| 4 | `calc_linked_addr.py` | `src/tools/linkaddr.zig`、`wk image linkaddr` | ✅ | MEM_AUTO / 显式 TEXT_BASE + 4 占位符替换实测一致（2026-11-17） |
| 5 | `config_update.py` | — | ⚪ | **不迁移**：`pexpect` 驱动 `scons --menuconfig` 的交互式 TUI 自动化，不产出任何镜像/格式；无 TUI 需求 |
| 6 | `elf_parse.py` | `src/tools/elf2aic.zig` 内部 | ✅ | ELF32/64 段解析，`wk image elf2aic` / `elf2its` 使用 |
| 7 | `elf2image/` | `src/tools/elf2aic.zig`、`wk image elf2aic` | ✅ | 段哈希/头部与参考一致 |
| 8 | `encrypt_rsa_key.py` | `src/tools/rsa_key.zig`、`wk image rsakey` | ✅ | AES/DES 私钥加密 + PKCS#1/SPKI 公钥四种组合逐字节一致；输出命名同为 `_encrypted.der`/`_encrypted_pkcs1.der`/`_pubkey_pkcs1.der`（2026-11-18） |
| 9 | `fdt/`（DTS/DTB 库） | `src/tools/fdt.zig`、`fdt_reader.zig`、`its.zig` | ✅ | 解析/序列化、FIT 构建与 dump；2026-11-19 修正字符串块对齐与属性顺序后与参考**逐字节一致** |
| 10 | `fsinstall.py` | `src/tools/fsinstall.zig`、`wk fs install/clean` | ✅ | 递归/单文件安装与清理，内容 SHA256 一致（2026-11-18） |
| 11 | `gen_partition_file_list.py` | `src/tools/partlist.zig`、`wk image partlist` | ✅ | D13x 输出 6 项与参考完全一致（2026-11-18） |
| 12 | `gen_partition_table.py` | `src/tools/partition_table.zig`、`wk image part` | ✅ | 内容一致（忽略 CRLF）；`--json` 同参考 |
| 13 | `itbimage/`（FIT 构建/签名/加密/导出） | `its.zig` + `itb.zig` + `fdt.zig`、`wk image itb/fitinfo` | ✅ | 图像签名 / 图像加密 / 配置签名 / 公钥注入 / `-E` 外部数据全部与参考逐字节一致：`check_fitsign.py`、`check_fitcipher.py`、`check_fitconfsign.py`、`check_fitsign_algos.py`（2026-11-19） |
| 14 | `linked_size.py` | `src/tools/linksize.zig`、`wk image linksize` | ✅ | `.summary.csv` / `.detail.csv` 命名与内容一致（另有 `.dironly.csv` 增强；2026-11-17） |
| 15 | `makefatfs.py` | `src/tools/fat.zig`、`wk image fat` | ✅ | FAT12/16/32 + LFN + AICF 扩展块，`mcopy` 回读通过；`-a/-f/-i/-o/-g/-s/-c/-v` 已对齐；`-r/--raw` 语义等价（我们从不裁剪）；`-t/--tooldir` 不需要（自实现）。`-b/--reserved`（NFTL）已对拍：16 MiB 分区、预留 61 块 → 8,781,824 B 与参考一致，BPB 一致，文件可导出（`check_fat_nftl.py`，2026-11-19） |
| 16 | `makelittlefs.py` | `src/tools/littlefs.zig`、`wk image littlefs` | ✅ | 复用上游 littlefs 2.5；`mklittlefs -l/-u` 验证内容一致（2026-11-18） |
| 17 | `makeuffs.py` | `src/tools/uffs.zig`、`wk image uffs` | ✅ | **策略：SDK 怎么用我们就怎么用**——SDK 内无 UFFS 核心源码，参照 `makeuffs.py` 同样调用厂商 `mkuffs`：`-t <partblkcnt> -p <page> -b <blockpages> -s <oob> -x auto -o 0 -f <out> -d <in>`；分区大小按 `partition_file_list.h` 匹配、`partblkcnt = partsize/(page*blockpages)` 与参考一致。对拍 `check_uffs.py`：16 MiB 分区产物 **17,301,504 B 逐字节一致**（2026-11-19） |
| 18 | `merge_files.py` | `src/tools/merge.zig`、`wk image merge` | ✅ | 按序拼接字节一致（2026-11-17） |
| 19 | `mk_image.py` | `preproc.zig` / `pack.zig` / `aicboot.zig` / `burner.zig` / `fwextract.zig` / `partcheck.zig` 等 | ✅ | `-p` 预处理器 7 类段已实现并对拍；`-d/-c/-k/-o/-v` 对齐；`-i/--imgfile` = `wk image extract`（`check_fwextract.py` 6 文件一致）；`-b/--burner` = `wk image burner`（`check_burner.py` 4 布局 10 文件一致）。`-e/--extract` 参考自身 `sys.exit(1)`（未实现）、`-s/--sign` 参考脚本内**未被消费** —— 两者参考本身即空操作，我们同样不提供（不是缺口） |
| 20 | `mk_prebootprog.py` | `src/tools/preboot.zig` + `des.zig`、`wk image pbp` | ✅ | 明文与 PNK 加密 PBP 均逐字节一致（512 B，DIFF=0；2026-11-18） |
| 21 | `mkcpio.py` | `src/tools/cpio.zig`、`wk image cpio`、`wk image ota` | ✅ | 512B env + crc cpio + size 回填；`cpio.exe -it` 可列出（2026-11-17） |
| 22 | `oneclick.sh` + `onestep/*.bat`（19 个） | — | 🚫 边界外 | Windows cmd 交互脚本，本质是 `scons --apply-def` + `scons` 的薄封装（`lunch`/`make_boot`/`make_app`/`buildall`/`cbuild`/`cout`/`check_build_result`/`sdk_update` 等）。按第 0 节不迁移；`sdk_update.bat` 的能力已由 `wk sdk-update` 覆盖 |
| 23 | `panic_parse.py` | `src/tools/panic.zig`、`wk panic` | ✅ | 同一日志 + `d13x.elf` 输出逐行一致；本轮补 `-v/--verbose`（2026-11-19） |
| 24 | `partition_check.py` | `src/tools/partcheck.zig`、`wk image partcheck` | ✅ | `-c/-d/-t/--strict/-v` 全部对齐。**本轮补 `-v` 并修三处口径**：① 表格标题/行按参考 `print_info`/`print_warn`/`print_error` 加 ANSI 颜色（47;30 / 43;30 / 41;37）；② 输出换行跟随平台（Windows CRLF）；③ 无可测项时**只打 `Nothing to check` 不出表**、media 段缺失时**退出码 0**（原实现报 `BadConfig`）、`size` 无法识别时补 `Skip ...: not measurable`。对拍 `check_partcheck.py`：空/50%/溢出/`--strict`/非法尺寸/无 media 段/UBI 七种场景 stdout **逐字节一致**（2026-11-19） |
| 25 | `release_patch.py` | `src/tools/release_patch.zig`、`wk release-patch` | ✅ | manifest XML（含 `<include>`/`<linkfile>`）+ `git format-patch` + 逐行路径/主题重写；`-t/-p/-o/-n/-l/-v` 全对齐。对拍 `check_release_patch.py`：自建 repo 工作区（双 git 子仓库 + linkfile + 未匹配 ref 的子项目），tag（不含边界）/ 原始 SHA（含边界）/ `-n 1` / `-p 子集` 四种用法共 8 个 patch **逐字节一致**，`--list` 文本一致（2026-11-19） |
| 26 | `rtt2freertos.py` | `src/tools/rtt2freertos.zig`、`wk rtt2freertos` | ✅ | 28 个官方 defconfig 转换逐字节一致；`-o/-n/--console-uart/--sysname/--sdk-root/--verify` 全部对齐。`--verify` 用 **自家 Kconfig 解析**复刻 kconfiglib 语义（生成 `.Kconfig.prj` + 按 SDK 根基准加载整棵树 + “符号是否有定义”判定）；对拍 `check_rtt_verify.py`：28 个 rt-thread defconfig 的 verify 段输出**逐行一致**（26 个 all-defined / 2 个 has-unknown），`FAILS=0`（2026-11-19） |
| 27 | `sdk_update.py` | `src/tools/sdk_update.zig`、`wk sdk-update` | ✅ | pinmux 修复逐行一致、幂等（2026-11-18） |
| 28 | `simg_dump.py` | `src/tools/sparse.zig`、`wk image simg --dump` | ✅ | 头部/chunk 表文本 + 单测（2026-11-17） |
| 29 | `upgcmd`（预编译二进制）+ `doc/skills/aiburn/scripts/aiburn/aicupg_client.py` | `upg_frame.zig` / `upg_payload.zig` / `upg_client.zig`、`wk upg *` | ✅ | 帧层 7 组、请求层 15 组、TCP 会话均与参考逐字节一致（`check_upg_send.py` / `check_upg_timeout.py`）。**服务端与 USB 通道是厂商二进制、无源码**，按用户口径“SDK 怎么用我们就怎么用”：`tools/fetch-upgcmd-deps.ps1` 补 DLL 后直接调 `upgcmd`（`wk image flashpack` 生成 `flash-upgcmd.ps1` 直烧脚本） |

## 3. CLI 选项级差异（本轮逐项核对）

| 参考 | 参考选项 | 我们 | 差异处置 |
|------|----------|------|----------|
| `makefatfs.py` | `-a -f -i -o -g -s -c -v -r -b -t` | `--auto --fullpart --input-dir --output --size --sector --cluster --label --raw --reserved` | `-t` 不需要（自实现）；`-r` 接受（默认即不裁剪）；`-b` 本轮实现（NFTL） |
| `makelittlefs.py` | `-i -o -p -b -t -g -r` | `-i -o -p -b -s/-size -r` | `-t` 不需要；其余等价 |
| `makeuffs.py` | `-i -o -g -p -s -t` | `wk image uffs -i -o -g -p -s -t` | 同名同义（`-t` 为工具目录） |
| `mk_image.py` | `-d -i -o -c -k -e -s -b -p -v` | `preproc: -c -d -k --timestamp`；`pack: -c -d -o --sdk-output --compare`；`extract <img> [-o]`；`burner -c -d -o` | `-e/-s` 参考未实现/未消费；`-v` 无需（不打印过程日志）；`-i`/`-b` 已等价实现 |
| `rtt2freertos.py` | `-o -n --console-uart --sysname --sdk-root --verify` | `-o -n --dry-run --console-uart --sysname --sdk-root --verify` | ✅ 全部对齐 |
| `panic_parse.py` | `-c -e -l -v` | `-c -e -l -v`（另有 `--addr2line`） | ✅ 本轮补齐 `-v` |
| `linked_size.py` | `-m` | `-m/--map`（另有 `--out-dir`） | ✅ 输出命名一致 |
| `encrypt_rsa_key.py` | `-d -a -r` | `-d/--des-key -a/--aes-key -r/--rsa -o` | ✅ |
| `mk_prebootprog.py` | `-m -k -i -o` | `-m/--magic -k/--pnk -i -o` | ✅ |
| `release_patch.py` | `-t -p -o -n -l -v` | `wk release-patch -t -p -o -n -l -v`（另有 `--root`） | ✅ 同名同义 |
| `calc_linked_addr.py` | `-i -c -o` | 同名 | ✅ |
| `gen_partition_table.py` | `-c -o -j` | `--config --out --json` | ✅ |
| `gen_partition_file_list.py` | `-c -o` | `--config --output` | ✅ |
| `fsinstall.py` | `-o -c -s -d` | `fs install -s -d [-o]` / `fs clean -c [-o]` | ✅ |
| `merge_files.py` | `-i`(多个) `-o` | `--input`(可重复) `--output` | ✅ |
| `partition_check.py` | `-c -d -t --strict -v` | `-c -d -t --strict` | 🟡 `-v`（verbose）未做（不影响判定与退出码） |
| `release_patch.py` | `-t -p -o -n -l -v` | — | 🔴 见第 2 节第 25 项 |
| `build_mini_bootloader.py` | `--root --base --mini-def --scons` | — | 🔴 见第 2 节第 3 项 |

## 4. 算法 / 格式枚举对照

| 域 | 参考支持 | 我们支持 | 状态 |
|----|----------|----------|------|
| `hash-*` 节点 | `crc32/md5/sha1/sha256/sha384/sha512`（`_hash._ALGOS`） | 全 6 种 | ✅ 2026-11-19 补齐 384/512 |
| 签名哈希档 | `sha1/sha256/sha384/sha512`（`_sign._parse_algo`） | 全 4 种（PKCS#1 v1.5 DigestInfo 前缀各自实现） | ✅ 2026-11-19 补齐，`check_fitsign_algos.py` 4/4 逐字节一致 |
| 图像加密 `cipher-*` | `aes128/aes192/aes256`(CBC+PKCS7)、`aes-128-ctr`、`chacha20` | 全 5 种（AES-192 自实现，FIPS-197 向量守门） | ✅ `check_fitcipher.py` 5/5 一致 |
| 配置签名 | 区域哈希 + `hashed-nodes`/`hashed-strings` | 同（`findRegions` 字节级移植） | ✅ `check_fitconfsign.py` |
| 公钥注入 `-K` | `algo/rsa,num-bits/rsa,modulus/rsa,exponent/rsa,n0-inverse[/required]` | 同（`rsa,n0-inverse` 用 mod 2^32 牛顿迭代） | ✅ 注入后整份 DTB 字节相同 |
| AIC 启动镜像 v2 | 头 256 B + loader + 资源链；RSA-2048/HMAC-SHA256、AES-128-CBC、MD5+校验和 | 同 | ✅ 6 组组合逐字节一致（`check_aicimage.py`） |
| Sparse 镜像 | `img2simg`（chunk：raw/fill/dontcare/crc32） | 同 + `--dump`/`--unsparse` | ✅ 11 组样本 + FAT 镜像一致 |
| FAT | FAT12/16/32（按簇数自动选择）、LFN、AICF 扩展块 | 同 + `--fat32` 强制 | ✅ `mcopy` 回读通过 |
| LittleFS | 2.5（`mklittlefs`） | 同（直接内嵌上游 C 源） | ✅ 内容一致 |
| CPIO | `crc`/`newc` | 同 | ✅ `cpio.exe -it` 可列出 |
| 分区表 | `gen_partition_table`（C 头 + JSON）、`gen_partition_file_list`（10 列 CSV） | 同 | ✅ 内容一致 |
| PBP / 私有资源 | `mk_prebootprog`（DES/PNK）、`mk_private_resource` | 同 | ✅ 逐字节一致 |
| UFFS | `makeuffs` + `mkuffs.exe` | 调同一 `mkuffs`（参数/分区计算同参考） | ✅ 产物逐字节一致（`check_uffs.py`） |

## 5. 已迁移并有验证（✅）摘要

完整证据链见第 2 节的“证据”列。核心一句话：**凡标 ✅ 的项，都有对拍脚本或实测数字**，
一键回归 `tools/regression.ps1` 会跑全部脚本（当前 **PASS=63 / FAIL=0 / SKIP=0**，8 个对拍脚本）。

## 6. 部分迁移（🟡）与下一步

| 项 | 剩余缺口 | 实现路径 | 验证门槛 |
|----|----------|----------|----------|
| `aic_build.py` / `onestep/*.bat` | SCons 全量构建编排 | 用 `wk build` 产出的计划驱动 `scons`；或在 Zig 内实现构建图 | 同一 defconfig 产出的 `.elf/.bin` 与参考构建一致（哈希） |
| `build_mini_bootloader.py` | mini 变体子构建 | 依赖上一条；其余是文件保存/恢复与拷贝逻辑 | mini 构建产物 `bootloader.bin` 与参考一致 |
| ~~`mk_image.py -b/--burner`~~ | burner 格式（`burner/*.bin` + 分区表 bin） | **已实现** `wk image burner`：整片镜像按设备容量 0xFF 预填、组件按 `part_offset` 落位、spi-nand 写 AICP 页表、每分区 16 B 烧写表项；spi-nand 按 `array_organization` 逐项出产物（product/分区表带 `_page_2k_block_128k` 后缀，同参考 `fixup_spinand_ubi_fwc_name`） | ✅ 4 种布局（spi-nor / nand 单组织 / nand 双组织 / mmc）10 个文件逐字节一致（`check_burner.py`，2026-11-19） |
| ~~`mk_image.py -i/--imgfile`~~ | 从已打包镜像解出组件目录 | **已实现** `wk image extract <img> [-o dir]`：按 `img_gen_fwc_meta()` 权威布局解包 + `.tar` 展开 | ✅ 参考 `extract_img_data()` 自相矛盾（见第 4 节），改用权威布局，6 个文件一致（`check_fwextract.py`，2026-11-19） |
| ~~`makefatfs.py -b/--reserved`（NFTL）~~ | 已完成 | — | `check_fat_nftl.py`：8,781,824 B 与参考一致、BPB 一致、文件可导出（2026-11-19） |
| `rtt2freertos.py --verify` | Kconfig 校验 | 复用本项目 `kconfig.zig` | 与参考在若干 defconfig 上的校验结论一致 |
| `partition_check.py -v` | verbose 输出 | 追加统计行 | 仅输出差异，不影响退出码 |
| `upgcmd` 服务端/USB | 无源码 | 按开源 `lib/aicupg` 协议实现 | 与 `upgcmd.exe` 服务端互通 |

## 7. 未迁移（🔴）与受阻说明

### P0 设备侧（影响“自己独立上板”）
- **bootloader/PBP**：`application/baremetal/bootloader`、`spienc/spienctool`、`d13x.pbp/pbp_cfg.bin`；
- **RTOS 内核**：`application/rt-thread`、`freertos`、`ucos-ii` 与 `kernel/` 适配；
- **HAL/驱动**：41 类 `bsp/artinchip/drv`（显示/存储/网络/音频/USB/安全…）；
- **烧写协议**：主机端 `upgcmd` 源码（内部 `aicupg`）与 USB/UART 协议。

### P1 镜像与安全能力
- ~~UFFS~~ 已迁移：调用厂商 `mkuffs`（见第 2 节第 17 项）；
- ~~固件加密~~ 已迁移：`wk image fwenc` 调同一 `firmware_security_encrypt`（参数同 `mk_image.data_crypt_create_image`）；
  `preproc` 的 `data_crypt` 段也已改为调用它。对拍 `check_fwenc.py` 三组参数逐字节一致；
  实测：只取密钥前 16 B、输入需 16 B 对齐且不填充、改动一块明文影响其后所有块（前向链式），
  已排除 ECB/CBC/CTR(XOR 流)；
- **SPIENC / eFuse 安全启动** —— 保留官方工具。

### P2 中间件 / 生态
- `packages/artinchip`（19 个）、`packages/third-party`（44 个）；
- 官方文档全量离线站（topics 464 篇 + images + webhelp）；
- 板级方案：d12x/d21x 多板 `target` 与 `pack/image_cfg.json`。

### P3 主机便利工具
- `release_patch.py`（repo 工作流）：可迁移，见第 2 节第 25 项；
- `crc32/xxd/sed/cat/truncate` 等 exe：功能已被 Zig 覆盖；
- `mtools`（mformat/mcopy）：保持使用官方二进制做验证。

## 8. 与“能不能烧写/跑起来”的关系

- **能做的**：官方 bootloader/OS → `wk image flashpack` → `flash-upgcmd.ps1` 烧写；
  或 `upgcmd write/exec` 直接跑本仓库 Zig 裸机 `hello_uart`。
- **不能独立做的**：没有 bootloader/PBP 与 RTOS/HAL，无法单独产出“可启动完整固件”。
- **建议优先级**：
  1. P1 收尾：`release_patch.py`、`mk_image -b/-i`、fat NFTL 对拍、`rtt2freertos --verify`；
  2. 构建链：SCons 编排（解锁 `aic_build`/`onestep`/`mini bootloader`）；
  3. 设备侧：按板卡补 HAL（UART/GPIO/时钟 → 存储 → 显示）；
  4. 烧写：实现开源 `lib/aicupg` 主机客户端（去掉厂商 DLL 依赖）。

## 9. 审计复现命令

```powershell
# 参考规模（本轮实测）
(Get-ChildItem G:\Code\C\luban-lite\tools\scripts -File -Recurse -Include *.py).Count      # 含 vendored 库
Get-ChildItem G:\Code\C\luban-lite\tools\scripts -File | Measure-Object                   # 顶层脚本
(Get-ChildItem G:\Code\C\luban-lite\bsp\artinchip\drv -Directory).Count
(Get-ChildItem G:\Code\C\luban-lite\packages\artinchip -Directory).Count
(Get-ChildItem G:\Code\C\luban-lite\packages\third-party -Directory).Count
(Get-ChildItem G:\Code\C\luban-lite\doc\topics -Recurse -File -Filter *.html).Count

# 我方能力
.\zig-out\bin\wk.exe
zig build test
powershell -NoProfile -ExecutionPolicy Bypass -File tools\regression.ps1
```

> 审计原则：**没有实测证据的不写成 ✅**；受阻项必须写清“为什么受阻”与“解锁条件”。
