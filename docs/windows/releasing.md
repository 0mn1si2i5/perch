# Windows 构建与发布

构建使用 .NET 10，运行要求 Windows 10 19041+ x64。版本唯一来源 `windows/VERSION`；0.3.0 继续作为预览版发布，版本 tag 为 `windows-v0.3.0`。

```powershell
windows/script/build.ps1 -Action Test
windows/script/build.ps1 -Action Publish
windows/script/build.ps1 -Action Package
```

无系统 SDK 时追加 `-Dotnet ./scratch/dotnet/dotnet.exe`。默认自包含程序在 `dist.noindex/windows/Perch/Perch.exe`；便携包在 `dist.noindex/windows/releases/Perch-Windows-<版本>-x64.zip`，同目录 `SHA256SUMS`。构建和打包不会自动启动或重启应用。

若正常产品或 dsh 后台宿主正在占用默认目录，使用独立发布目录，保留个人客户端与服务：

```powershell
windows/script/build.ps1 -Action Package -OutputDirectory dist.noindex/windows/Perch-pr-review
```

此命令包含 Release 自包含发布，并从该目录生成 ZIP；不会替换默认运行目录。ZIP 与 `SHA256SUMS` 仍写入上述 `releases/`，同版本的本地包会被覆盖。0.3.0 的产物名为 `Perch-Windows-0.3.0-x64.zip`；本地打包不更新 GitHub Release。

## 发布流程

沿用 `.github/workflows/release-windows.yml`：CI 检查按 windows/shared 路径触发，发布仅由 `windows-v<版本>` tag 推送触发。工作流先校验 tag 与 VERSION 完全一致，再提取 `windows/CHANGELOG.md` 对应版本段落，执行 Core／WPF 测试和自包含打包，最后上传 ZIP 与 `SHA256SUMS` 并创建 GitHub 预览 Release。Actions 固定 commit SHA；普通 main 推送执行检查，不触发发布。

0.3.0 发布时应将 `windows-v0.3.0` 指向包含版本和发布说明的已合并提交。确认该提交的原生检查后创建 tag；发布成功以 tag 工作流完成、Release 附件与校验文件可下载为准。不要用本地 Package 成功代替已发布，也不要复用或覆盖已有版本 tag。

## 用户安装与升级

便携包已包含 .NET 运行时，用户无需安装 SDK 或 .NET；解压后运行 `Perch.exe`。程序未签名，首次运行可能出现 SmartScreen 提示；可用同一 Release 的 `SHA256SUMS` 检查下载包。尚未实现安装器、自动升级或开机自启动。

升级前先等待受管 dsh 任务结束，在账号菜单中显式停止所有由 Perch 启动的 dsh 服务，然后退出 Perch，再替换程序文件或解压到新目录。停止服务会中断仍在运行的任务；仅退出 Perch 不会停止独立后台宿主，旧目录仍可能被占用。手动连接的外部 dsh 服务无需因 Perch 升级而停止。保留 `%LOCALAPPDATA%\Perch`、账号目录与已有 `DSH_HOME`，不要随程序目录一起删除。

受管 dsh 需要另行安装符合所选包要求的 Node.js，并准备完整的 CLI／Web 构建；Perch 不安装或升级 dsh。连接已有本机 Web 实例不要求另装 Node。系统要求不等于所有系统组合已实机验收，Windows 10 回退和混合 DPI 等限制见 [验收记录](acceptance.md)。

## 0.3.0 验证边界

本版发布说明覆盖 dsh Web 的发现、启动、恢复连接、任务和双余额，鲸鱼娘桌宠，以及路径展开、缓存隔离、受管服务归属和自动刷新修复。双端实现共用协议样本、文案和角色资源；此工作流只生成 Windows 包。

原生 Core／WPF、DPAPI、隔离宿主与构建检查见 [PR #7 Checks](https://github.com/0mn1si2i5/perch/pull/7/checks)，tag 工作流会重新执行测试与打包。真实官方登录钱包、真实模型任务／完成通知、桌宠真实鼠标与媒体交互未在本轮全面重验；历史真实 API 余额或安装 smoke 仅代表其记录日期，不能由样本测试或 CI 推导为本轮已验收。详见 [Windows 验收记录](acceptance.md) 和 [双端 dsh 指南](../deepseek-harness.md)。
