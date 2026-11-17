# tools/continuity — 接续基建（自检 + 记忆同步）

> 属于「接续基建」体系：把个人工作偏好与跨项目接续协议以 VS Code 用户级指令形式就位于任意开发机；并把本机 Copilot 工作记忆回灌为仓库镜像。
> 幂等、可安全反复运行。

## 组成

| 文件 | 作用 |
|---|---|
| `install-global-instruction.ps1` | 幂等安装/更新用户级指令到本机 VS Code（拆分版：逐文件安装 5 个规则文件；带版本守卫，旧副本不会覆盖新版本） |
| `templates/跨项目接续协议.instructions.md` | 公共规则（`applyTo: **`） |
| `templates/Rust项目规范.instructions.md` | Rust / 编译 / 打包 / 镜像 / 依赖拉新 |
| `templates/服务端与数据规范.instructions.md` | HTTP/WAF、登录、数据库、Pek.RCode |
| `templates/前端规范.instructions.md` | 面板弹窗、后台配置页 |
| `templates/Zig项目规范.instructions.md` | Zig 异步/并发、串口与硬件调测 |
| `templates/用户级指令.instructions.md` | 兼容索引（不再承载规则，固定低版本防旧安装器覆盖） |
| `sync-memory.ps1` | 本机工作记忆 → `docs/项目记忆.md`（默认按脚本位置推导项目根，可用 `-ProjectPath` 显式指定；本机记忆为空时默认不覆盖已有镜像，`-Force` 强制） |
| `.vscode/tasks.json` | VS Code 打开项目时静默执行自检脚本（首次需点「允许自动任务」；仅 Windows 的 PowerShell 环境生效） |

## 手动运行

```powershell
powershell -ExecutionPolicy Bypass -File tools/continuity/install-global-instruction.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/continuity/sync-memory.ps1            # 或加 -ProjectPath <项目根>
```

## 说明

- 本项目与其他已装备仓库互为自愈锚点——任一台新电脑打开任一锚点仓库，即自动补齐/更新本机用户级指令；
- 模板变更时需同步所有已装备仓库的副本，并递增「版本：」行（版本守卫防旧覆盖新）；
- **新电脑首次回灌**：先把仓库镜像 `docs/项目记忆.md` 内容并入本机记忆再运行同步（防覆盖）；镜像随 git 版本化，误覆盖可从提交历史找回。
