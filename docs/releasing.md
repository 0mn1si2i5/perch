# 构建与发布

版本唯一来源为根目录 `VERSION`。发布 tag 为 `v<版本>`，应用 `CFBundleShortVersionString` 与 `CFBundleVersion` 同步使用该版本。改动说明写入 `CHANGELOG.md`。

## 检查与打包

```bash
swift test
./script/package-release.sh
```

打包脚本使用 release 优化，同时构建 arm64 和 x86_64，校验两个 Mach-O 架构及签名，生成：

- `dist.noindex/releases/Perch-<版本>-universal.dmg`
- `dist.noindex/releases/Perch-<版本>-universal.zip`
- `dist.noindex/releases/SHA256SUMS`

DMG 包含 Perch.app 和 Applications 入口。ZIP 也可解压后把 Perch.app 拖入 Applications。替换应用不清除应用数据目录和偏好。校验下载内容：`shasum -a 256 -c SHA256SUMS`。

开发安装使用 `./script/build_and_run.sh --install`，默认 debug；可指定 `PERCH_CONFIGURATION=release`。脚本先完成构建再替换运行中的应用，保持单一安装入口。

## 签名与公证

默认使用 ad-hoc 签名，属于未公证的 GitHub 分发。当前发行包没有 Developer ID 发布签名或 Apple 公证，macOS 可能阻止首次打开。仅在确认下载来源后按系统“隐私与安全性”的提示允许，不全局关闭 Gatekeeper。

有 Developer ID Application 证书时，可设置 `PERCH_SIGNING_IDENTITY` 后重新打包；构建脚本会启用 hardened runtime 与时间戳。随后使用自己的 notarytool 钥匙串配置提交应用／磁盘映像，通过后 staple 并复核。单独传入签名身份不代表已经公证；不把证书、密码或 API 凭据加入仓库。

## GitHub 发布

1. 完成检查、核对产物与变更范围。
2. 提交到开发分支，合并 main，并正常推送 main；不强制推送。
3. 从 main 的已验证提交创建带注释的版本 tag 并推送。
4. 创建普通 GitHub Release，上传 DMG、ZIP 和校验文件，正文写明系统要求、变更及未公证状态。
5. 下载并校验发布资产，确认 Release tag 与 main 对齐。

当前仓库为私有仓库，Release 只对有权限的用户可见，发布不会改变仓库可见性。CI 在 main 推送和 PR 上运行 macOS 测试与 release 构建，不自动发布。旧阶段计划、探针与设计过程已从日常文档中移除，已提交内容可从 Git 历史查阅；本轮整理前的完整工作区另有本机忽略备份。
