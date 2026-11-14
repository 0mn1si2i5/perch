# 2026-10-24 上游同步记录

同步前工作区干净，仓库只有本地 `main` 分支，指向 `08d489d`，与 `origin/main` 一致。抓取两个远端后比较：

| 项目 | 结果 |
|---|---|
| 共同祖先 | `575d35b` |
| 本地独有 | 7 个提交，39 个文件，新增 2073 行、删除 65 行；主要为 Windows dsh 集成与文档 |
| 上游独有 | 35 个提交，125 个文件，新增 4687 行、删除 1926 行；含合并提交 |
| 上游主分支 | `7fc13dd`，2026-10-22；移除接力与子 agent 面板，保留对话状态通知 |
| 同步分支 | 从原 `main` 创建 `codex/align-upstream-main`，合并 `upstream/main`，保留双方历史 |

## 实际冲突

Git 报告 15 个内容冲突文件，没有新增／删除冲突：

| 冲突文件 | 原因与处理 |
|---|---|
| `NOTICE` | 合并本地 YamlDotNet／DeepSeek 通知与上游 Antigravity 版权说明 |
| `README.md`、`docs/windows/architecture.md`、`shared/parity.md`、`windows/CHANGELOG.md` | 上游删除接力，本地新增 dsh 及接力描述；采用上游移除方向，保留 dsh 账号、任务、钱包、API 余额与后台服务，更新当前使用说明 |
| `shared/strings/zh-CN.json` | 保留通知与 dsh 文案，删除接力设置文案，确认 JSON 可解析 |
| `windows/src/Perch.App/ViewModels/Models.cs`、`windows/src/Perch.App/ViewModels/PanelModel.cs` | 上游拆分账号／演示／通知 partial 并移除接力；将 dsh 创建、启动、重新定位和演示接入新结构，删除历史记录模型与接力代码 |
| `windows/src/Perch.App/Views/InfoPage.xaml`、`QuotaRows.xaml`、`ViewMenus.cs` | 保留 dsh 说明、钱包和账号菜单，采用上游可伸缩额度标签列与无接力的会话菜单 |
| `windows/src/Perch.Core/Clients.cs`、`Models.cs`、`QuotaService.cs` | 同时保留上游窗口恢复、配置少写盘／恢复提示与本地 dsh 数据模型；额度回退在后台执行，dsh 失败不误读 Codex／Claude 历史 |
| `windows/tests/Perch.Core.Tests/Program.cs` | 同时执行上游回归／通知测试和 dsh 测试，移除已删除功能的 dsh 接力用例 |

文本自动合并之外，还调整了 dsh 专用代码、上游新增 partial 和使用指南，避免残留对已删除 `Handoffs` 的引用；点击 dsh 通知通过专用启动入口打开 Web。旧的用户 `handoffs/` 文件不删除、不再读取。

## 本地验证与边界

- .NET 10.0.400：`windows/script/build.ps1 -Action Test` 通过；包括上游回归／通知、dsh RPC／DPAPI／独立宿主生命周期与 API 余额测试。宿主测试使用隔离测试服务。
- `windows/script/build.ps1 -Action Package -OutputDirectory dist.noindex/windows/Perch-upstream-sync` 通过，包含 Release 自包含发布与 ZIP／SHA256 生成；未覆盖原产品程序目录。
- 发布包 `--demo` 三主题四页面，加 dsh npm、已有实例和余额卡片，共 15 次截图运行成功；抽查新建页、设置／信息页和 dsh 卡片，截图在忽略目录 `scratch/upstream-sync-qa/`。
- 贡献差异 `git diff --cached --check upstream/main` 通过。相对原 `main` 的完整检查仅报告上游 `docs/macos/providers.md` 已有的末尾空行，未为此修改上游文件。macOS 目录与 `upstream/main` 一致，保留 Pox 偏好一次迁移；本机是 Windows，没有进行 Mac 构建或验收。
- 本次没有重新验证个人客户端、真实 dsh 模型任务或官方登录钱包，没有改变登录配置、停止个人服务、推送远端或发布 Release。旧日期的验收记录保留为历史证据，不代表本次重做。

完成后的同步分支包含上述上游主分支的全部提交，落后 0 个提交；相对上游领先 8 个提交（原 7 个提交加本次合并提交）。原 `main` 与 `origin/main` 保留在 `08d489d`。
