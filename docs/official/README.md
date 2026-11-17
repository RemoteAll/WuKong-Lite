# 官方文档迁移（Luban-Lite）

本目录原样迁移自参考工程 `G:\Code\C\luban-lite\doc`（ArtInChip Luban-Lite），
保留原始内容与许可证，便于离线查阅与工具复用。

## 已迁移

| 路径 | 源路径 | 说明 |
|------|--------|------|
| `skills/aiburn/` | `doc/skills/aiburn/` | AIBURN 烧写技能：`SKILL.md`、`README.md`、`scripts/aiburn.py` 及协议客户端 |
| `LICENSE-3rd-party.txt` | `doc/license-3rd-party.txt` | 官方第三方许可证清单 |

## 未迁移（及原因）

| 路径 | 大小 | 原因 |
|------|------|------|
| `doc/webhelp/` | ≈80 MB | DITA-OT 生成的离线站点（CSS/JS/搜索索引），与 `topics/` 内容重复 |
| `doc/topics/` | ≈17 MB / 464 个 HTML | 官方文档正文；如需全文离线查阅，可按需同步指定主题 |
| `doc/images/` | ≈19 MB / 358 个图 | 供 `topics/` 引用 |
| `doc/*.html/.xml` | — | 站点首页、搜索页、sitemap 等生成物 |

> 如需把某篇官方文档（例如 `topics/sdk/burnsys/burn_spinor.html`）也迁进来，
> 复制该 HTML 与它引用的 `company-logo.png` 即可；样式表缺失不影响阅读。

## 来源与许可证

- 来源：ArtInChip Luban-Lite SDK（本机路径 `G:\Code\C\luban-lite`）。
- 官方仓库：<https://github.com/artinchip/luban-lite>（设备端 aicupg 源码）、
  <https://github.com/artinchip/tools>（AiBurn / AiBurnPro / AiBurnID 安装包）。
- `skills/aiburn` 在 `SKILL.md` 中声明 `license: Apache-2.0`。
- 其余第三方组件许可见 `LICENSE-3rd-party.txt`。
- 迁移仅用于本仓库的离线参考与工具调用，未修改原文。

## 与本仓库的关系

- `docs/official/luban-lite-architecture.md`：官方 `luban-lite` 仓库的定位与分层说明
  （它是完整固件 SDK，OS 只是其中一层）。
- `docs/FLASHING.md` 是面向 WuKong-Lite 的烧写说明（官方 upgcmd 直烧 + AIBURN 两种路径 + 本机实测结论）。
- `tools/fetch-upgcmd-deps.ps1` 补齐 upgcmd 依赖（UsbDkHelper/libgcc/libwinpthread），
  产物在 `wk/image/tools/upgcmd`（已 gitignore）。
- `wk image flashpack` 默认调用 `docs/official/skills/aiburn/scripts/aiburn.py` 生成
  `flash-aiburn.ps1`，同时生成 `flash-upgcmd.ps1`（直烧，不需要 9100 server）。
