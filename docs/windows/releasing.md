# Windows 构建与发布

.NET 10，Windows 10 19041+ x64。版本唯一来源 `windows/VERSION`。

```powershell
windows/script/build.ps1 -Action Test
windows/script/build.ps1 -Action Publish
windows/script/build.ps1 -Action Package
```

无系统 SDK 时追加 `-Dotnet ./scratch/dotnet/dotnet.exe`。自包含程序在 `dist.noindex/windows/Perch/Perch.exe`；便携包在 `dist.noindex/windows/releases/Perch-Windows-<版本>-x64.zip`，同目录 `SHA256SUMS`。本机运行目录已直接更新，ZIP 是可选分发副本，不需要再次安装。

CI 检查按 windows/shared 路径触发，发布配置只在 `windows-v<版本>` tag 触发，先校验 VERSION，再测试、打包并取 Windows CHANGELOG 对应段落发布预览 Release。Actions 固定 commit SHA。当前尚未创建 Windows Release。普通 main 推送执行检查，不触发发布。

尚未实现安装器、签名、自动升级或开机自启动。当前使用便携包，不修改系统设置。
