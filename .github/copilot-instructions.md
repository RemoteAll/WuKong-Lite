# WuKong-Lite · Copilot 协作指令

## 1. 项目定位

- 用 **Zig 0.17** 复刻 ArtInChip **Luban-Lite** 的主机侧能力：镜像格式、配置、打包、校验、烧写编排。
- 参考实现：`G:\Code\C\luban-lite`（官方仓库 `artinchip/luban-lite`）。
- 明确边界：bootloader/PBP、RTOS 内核、HAL/驱动仍属官方 SDK；本仓库不重复实现。
- 目标：能产出并验证可烧写镜像；能对上游更新做差异同步；能直接在仓库内写 Zig 裸机/工具代码。

## 2. 架构速览

| 目录 | 内容 |
|------|------|
| `src/bsp/common` | AIC 头/checksum/env/FW 包/GPT/分区 |
| `src/tools` | Kconfig、FIT/ITS/FDT、ELF→AIC、FAT、cpio、sparse、AES、RSA、flashpack |
| `src/kernel/common` | OSAL（线程/信号量/邮箱）、设备框架、堆 |
| `src/shell`、`src/application` | 模拟 shell 与示例应用 |
| `apps/hello_uart` | D13x 裸机 Zig 应用（UART0 输出） |
| `examples/zig_riscv` | Zig 与官方 GCC 混链示例 |
| `docs/` | 验证、烧写、审计、官方文档迁移 |

## 3. 常用命令

```powershell
zig build              # 构建 wk.exe
zig build test         # 94 项单测
.\zig-out\bin\wk.exe   # 查看命令
wk image flashpack --payload-dir payload --out-dir flash
powershell -File tools\fetch-upgcmd-deps.ps1 -SdkRoot G:\Code\C\luban-lite
powershell -File tools\build-zig-app.ps1 -App hello_uart
```

新增工具（均与参考脚本对拍过）：

```powershell
wk image rsakey -r key.pem [-a aes.key | -d des.key] [-o outdir]   # encrypt_rsa_key.py
wk panic -l panic.log [-e app.elf] [--addr2line <tool>]            # panic_parse.py
wk sdk-update --root <SDK根目录> [--write]                          # sdk_update.py
wk rtt2freertos <rt-thread_defconfig> [-o out]                      # rtt2freertos.py
wk upg frame --cmd 0x31 --payload '{"v":"1.0"}'                    # upgcmd 帧协议
wk upg burn --image x.img [--no-reboot] [--partition all]            # upg 请求（载荷对拍参考客户端）
wk upg decode -i frame.bin
```

## 4. 编码与验证纪律

- **实测优先**：任何格式/工具改动必须与参考工具比对（mkimage/mkenvimage/mcopy/openssl/upgcmd 等）；
  无法验证的必须明确标注“未实现/未验证”，不得声称等价。
- **分档验证**：`zig build test` → `zig build` → 单点实跑；不随意打包/全量同步。
- **中文提交**：`type(scope): 中文主题`；用 `git commit -F <UTF-8 文件>`，不要 `-m "中文"`。
- **PowerShell**：含中文的 `.ps1` 必须 **UTF-8 with BOM**；不要出现双 BOM。
- **Zig 0.17 要点**：`std.Io` 新 I/O；无 `**`（用 `@splat`）；`std.crypto.core.aes`；
  `@backingInt` 替代 `@intFromEnum`；递归函数显式错误集。
- **不破坏参考**：不修改 `G:\Code\C\luban-lite`；只读参考、复制所需文档/许可证。

## 5. 全量迁移与上游同步

- 缺口清单：`docs/MIGRATION_AUDIT.md`；执行清单：`docs/MIGRATION_BACKLOG.md`。
- 上游同步：`tools/sync-upstream.ps1`（拷贝 `doc/skills` 与许可证，写
  `docs/official/UPSTREAM.json` 记录 commit/哈希；`-Check` 只比对）。
- 官方仓库有更新时：先 `-Check` 看漂移 → 同步文档 → 在 backlog 中登记差异 → 再决定代码迁移。

## 6. 接续协议（每轮必做）

- 开工先读：本文件 → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` →
  `docs/MIGRATION_AUDIT.md` / `docs/决策记录.md` 最新节。
- 机器自愈：`tools/continuity/install-global-instruction.ps1`（`.vscode/tasks.json` 打开项目自动跑）。
- 收尾：① `docs/决策记录.md` 新增一节（含用户原话）；② 运行
  `tools/continuity/sync-memory.ps1`；③ 跑回归并如实汇报。

## 7. 用户关键决策（原话）

- “能不能一次性迁移完，这样子可以让我尽快烧写到芯片模组中试试” → 已交付 flashpack/upgcmd 直烧。
- “官方文档也要迁移过来吧” → 迁移 `doc/skills/aiburn` 到 `docs/official/`。
- “那还是直接在当前我们迁移的库上做开发吧，这样就不用那么麻烦了” → 增加 Zig 裸机应用链。
- “请继续，我要的是全量迁移，后续官方库有更新了，我也要同步，另外要帮我根据全局用户指令做接续相关的处理”
  → 建立 backlog + `sync-upstream` + 接续基建（本文件、项目记忆、自检任务）。
