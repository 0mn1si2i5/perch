# 构建与发布

版本唯一来源为`macos/VERSION`。发布 tag 为 `macos-v<版本>`，应用 `CFBundleShortVersionString` 与 `CFBundleVersion` 同步使用该版本。改动说明写入 `macos/CHANGELOG.md`。

## 检查与打包

```bash
swift test --package-path macos
./macos/script/package-release.sh
```

打包脚本使用 release 优化，同时构建 arm64 和 x86_64，校验两个 Mach-O 架构及签名，生成：

- `macos/dist.noindex/releases/Perch-<版本>-universal.dmg`
- `macos/dist.noindex/releases/Perch-<版本>-universal.zip`
- `macos/dist.noindex/releases/SHA256SUMS`

DMG 包含 Perch.app 和 Applications 入口。ZIP 也可解压后把 Perch.app 拖入 Applications。替换应用不清除应用数据目录和偏好。校验下载内容：`shasum -a 256 -c SHA256SUMS`。

开发安装使用 `./macos/script/build_and_run.sh --install`，默认 debug；可指定 `PERCH_CONFIGURATION=release`。脚本先完成构建再替换运行中的应用，保持单一安装入口。

本地开发构建优先沿用已安装 Perch 的签名证书。首次安装或已安装版本为 ad-hoc 时，自动选择本机唯一有效的 Apple Development 签名身份；没有开发身份时使用 ad-hoc，存在多个开发身份时要求通过 `PERCH_SIGNING_IDENTITY` 明确选择。已安装版本使用稳定证书、但该证书不再可用时，脚本停止，不自动改用其他证书或降级为 ad-hoc。`PERCH_SIGNING_IDENTITY` 的显式值始终优先，包括用 `-` 选择 ad-hoc。

固定签名有助于让钥匙串识别后续构建为同一应用（[Apple 的 designated requirement 说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)）。首次从 ad-hoc 切换到证书签名时，系统仍可能要求重新授权一次；具体取决于对应钥匙串条目的访问规则。脚本不会修改钥匙串访问控制，也不保存密码。证书身份仅在本机选择，不写入仓库。

## 签名与公证

发布打包脚本默认使用 ad-hoc 签名，属于未公证的 GitHub 分发，不自动选用本机开发证书。当前发行包没有 Developer ID 发布签名或 Apple 公证，macOS 可能阻止首次打开。仅在确认下载来源后按系统“隐私与安全性”的提示允许，不全局关闭 Gatekeeper。

有 Developer ID Application 证书时，可设置 `PERCH_SIGNING_IDENTITY` 后重新打包；构建脚本会启用 hardened runtime 与时间戳。随后使用自己的 notarytool 钥匙串配置提交应用／磁盘映像，通过后 staple 并复核。单独传入签名身份不代表已经公证；不把证书、密码或 API 凭据加入仓库。

## GitHub 发布

1. 完成检查、核对产物与变更范围。
2. 提交到开发分支，合并 main，并正常推送 main；不强制推送。
3. 从 main 的已验证提交创建带注释的版本 tag 并推送。
4. 创建普通 GitHub Release，上传 DMG、ZIP 和校验文件，正文写明系统要求、变更及未公证状态。
5. 下载并校验发布资产，确认 Release tag 与 main 对齐。

仓库已公开。发布 tag 统一使用 `macos-v*`（1.0.0、1.0.1 的旧 Release 已移除，变更见 CHANGELOG）。main 可能包含尚未打包的修复，不能用历史发行包代表最新源码。CI 在 main 推送和 PR 上运行测试与 release 构建，不自动发布。

macOS 尚无自动发布 workflow。实际验证范围见 [验收说明](acceptance.md)。

2026-10-18 本机开发更新验证：从 ad-hoc 切换到已有开发证书完成构建和安装；再次运行构建时成功识别并沿用已安装证书，两次应用的 designated requirement 一致。后台 Claude 读取按未授权状态返回，无系统弹窗；尚未完成用户选择“始终允许”后的跨更新实测，不能承诺所有钥匙串条目永远不再要求授权。
