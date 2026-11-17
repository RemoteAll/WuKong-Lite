# 官方上游同步（Luban-Lite）

本目录的 `skills/` 与 `LICENSE-3rd-party.txt` 来自官方 SDK，**不要手工编辑**；
需要更新时运行 `tools/sync-upstream.ps1`。

## 1. 来源与记录

| 项 | 值 |
|----|----|
| 官方仓库 | <https://github.com/artinchip/luban-lite> |
| 本地参考源 | `G:\Code\C\luban-lite`（只读） |
| 迁移范围 | `doc/skills/**`、`doc/license-3rd-party.txt` |
| 未迁移 | `doc/topics/**`、`doc/images/**`、`doc/webhelp/**`（体积大，按需离线打包） |
| 版本清单 | `docs/official/UPSTREAM.json`（commit/branch/时间/逐文件 SHA256） |

## 2. 命令

```powershell
# 只比对：0=一致，1=有漂移，2=源不可用
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-upstream.ps1 -Check

# 复制并刷新 UPSTREAM.json
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-upstream.ps1

# 额外查询 GitHub HEAD（网络失败只告警）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-upstream.ps1 -Github
```

## 3. 官方更新时的操作顺序

1. 更新本地参考 SDK（`git -C G:\Code\C\luban-lite pull`），确认 commit。
2. `tools\sync-upstream.ps1 -Check` 看漂移；`~` 为变更、`+` 为新增、`-` 为删除。
3. 运行不带 `-Check` 的同步，刷新 `docs/official/skills` 与 `UPSTREAM.json`。
4. 阅读变更的 `SKILL.md` / 脚本，判断是否有新的镜像格式或烧写流程；
   在 `docs/MIGRATION_BACKLOG.md` 登记新缺口，再决定代码迁移。
5. 跑 `zig build test`，提交中文信息：`docs(upstream): 同步官方文档 <旧commit>..<新commit>`。

## 4. 当前状态（2026-11-17）

- 本地源 commit：`c6e3a4771a483fc4b42519b2882be3a21a50ef61`（master）。
- 已同步 10 个文件：`skills/aiburn/**`（含 `scripts/aiburn/*.py`）+ 第三方许可证。
- `github_head` 为空：当前网络无法执行 `git ls-remote`；联网后带 `-Github` 重跑即可记录。
- 本目录的 `README.md`、`luban-lite-architecture.md`、`upgcmd-binary-map.md` 是本仓库自写说明，不会被同步覆盖。
