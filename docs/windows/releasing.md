# Windows 构建与发布

.NET 10，Windows 10 19041+ x64。版本唯一来源 `windows/VERSION`。

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

此命令包含 Release 自包含发布，并从该目录生成 ZIP；不会替换默认运行目录。ZIP 与 `SHA256SUMS` 仍写入上述 `releases/`，同版本的本地包会被覆盖。当前 `windows/VERSION` 仍为 `0.2.0`，因此新生成的开发包同名于已发布版本，但包含未发布改动；本地打包不更新 GitHub Release。更新运行目录需另行退出 Perch，并显式停止由其管理的 dsh 宿主后再替换文件。

CI 检查按 windows/shared 路径触发，发布配置只在 `windows-v<版本>` tag 触发，先校验 VERSION，再测试、打包并取 Windows CHANGELOG 对应段落发布预览 Release。Actions 固定 commit SHA。0.2.0 已于 2026-10-10 通过该流程发布为预览版 Release（`windows-v0.2.0`）。普通 main 推送执行检查，不触发发布。

尚未实现安装器、签名、自动升级或开机自启动。当前使用便携包，不修改系统设置。
