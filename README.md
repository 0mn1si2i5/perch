# Perch

**在 macOS 菜单栏或 Windows 系统托盘管理 Codex / Claude 账号，查看任务与额度，用文档接力。**

[macOS 下载](https://github.com/0mn1si2i5/perch/releases/tag/v1.0.1) · [Windows 本地构建](#windows) · [快速上手](#快速上手) · [更新记录](CHANGELOG.md)

| 平台 | 系统要求 | 当前交付 |
| --- | --- | --- |
| macOS | macOS 14+，Apple Silicon / Intel | 已发布 1.0.1，提供通用 DMG / ZIP；main 另含后续面板与会话修复 |
| Windows | Windows 10 19041+ x64；已在 Windows 11 验证部分路径 | 原生 0.2.0 源码与本地自包含便携包构建；尚无 GitHub Release |

仓库已公开。macOS 发行包尚未经过 Apple 公证；Windows 便携包尚未签名。安装与打包说明分别见 [macOS](docs/macos/releasing.md) 和 [Windows](docs/windows/releasing.md)。两端各自管理本机数据，不跨设备同步。

<p align="center">
  <img src="docs/images/perch-overview.png" alt="Perch macOS 面板示意：账号、会话、额度与可选桌宠" width="100%">
</p>

上图为 macOS 界面示意，使用演示数据；Windows 使用原生 WPF 面板，提供系统浅色、深色和 Pox 主题。

## 打开面板，就能看到

| 多账号集中管理 | 任务与会话 | 额度与重置时间 |
| --- | --- | --- |
| 按 Codex / Claude 分组，启动或调出对应客户端；支持独立本地配置目录。 | 查看活动任务与最近会话；分组、账号和会话支持拖动排序。 | 显示已用比例与重置时间，支持手动刷新和定期同步；查询失败时保留并标注缓存。 |

## 按你的习惯使用

| 默认界面 | 原生桌宠 | Pox |
| --- | --- | --- |
| 桌宠默认关闭。macOS 使用系统毛玻璃，Windows 跟随系统明暗与强调色。 | 静态浮球入口，可拖到顺手的位置，单击打开面板；保留系统主题。 | 内置角色与配套面板主题；隐藏角色后仍保留所选主题。 |

设置中开启桌宠能力并选择角色后，底栏爪印控制显示与隐藏。设置、信息和账号列表在同一个面板内切换。

## 换账号，继续同一个任务

![文档接力示意：在源对话生成交接文档，复制到目标新对话继续](docs/images/handoff-flow.png)

1. 右键已停下的会话，选择“接力到…”及目标账号。
2. Perch 复制提示词并调出源客户端；在原对话粘贴发送，让 agent 将交接文档写到指定绝对路径。
3. 文档生成后回到面板点“继续接力”，复制正文与路径并调出目标客户端。
4. 在目标新对话粘贴发送，继续任务。

也可使用已有 Markdown。待接力状态重启后保留；记录默认显示最近 5 次，可展开、定位文档或删除记录。**不自动复制原对话，不自动发送消息。**

## 快速上手

1. 安装并打开 Perch：macOS 点击菜单栏图标；Windows 点击系统托盘图标，也可按 `Ctrl+Alt+P`。
2. 点“新建账号”添加 Codex 或 Claude，再在对应客户端登录。Perch 中的账号是本地客户端配置入口。
3. 查看任务与额度；点账号旁的刷新按钮手动同步，在设置中管理定期同步。
4. 需要桌面入口时，在设置开启桌宠，选择原生浮球或 Pox。

点击外部或按 Esc 收起面板；底栏 ⓘ 可查看用法。收起面板后应用继续在后台运行，可从设置或菜单退出。

<details>
<summary>会话与账号限制</summary>

- Codex 单实例可使用对话深链；多实例时只调出所属客户端，避免跳错账号。Claude 目前只调出客户端，具体会话需自行选择。
- Claude 桌面会话从各账号配置目录读取。macOS 默认客户端卡片另显示本机 Claude Code 历史，并标记 `Code`；不能据此确认 Code 与桌面客户端使用相同登录。Windows 目前不读取 CLI projects 历史。
- 会话排序保存在 Perch，不修改原会话文件；macOS 限同账号、同活动状态分区，Windows 保持活动／最近分区。
- 额度依赖客户端授权及服务可用性，百分比为已用额度。失败时的缓存时间不是重置时间；悬停可查看原因。API Key / 第三方账号不提供官方订阅额度数据，“不限”不代表第三方网关没有限制。
- 桌宠可选；主题与显示状态分离。媒体感知只读取系统播放状态与类型，不读取媒体标题；应用未上报时无法检测。
- 双个人账号同时登录、完整跨账号接力及部分多屏交互仍需实测。具体证据见 [macOS 验收](docs/macos/acceptance.md)、[Windows 验收](docs/windows/acceptance.md) 与 [功能对齐](shared/parity.md)。

</details>

## 构建

### macOS

需要 Xcode Swift / clang 工具链。无需额外下载媒体依赖或提供 API key。

```bash
swift test --package-path macos
./macos/script/build_and_run.sh --build     # macos/dist.noindex/Perch.app
./macos/script/build_and_run.sh --install   # 安装到 ~/Applications/Perch.app 并启动
./macos/script/build_and_run.sh --verify    # 安装并检查进程，不替代交互验收
./macos/script/package-release.sh          # macos/dist.noindex/releases/ 下生成 DMG、ZIP、SHA256SUMS
```

### Windows

在 Windows 上使用 .NET 10 SDK；运行自包含包无需安装 SDK。

```powershell
./windows/script/build.ps1 -Action Test
./windows/script/build.ps1 -Action Run
./windows/script/build.ps1 -Action Publish  # dist.noindex/windows/Perch/Perch.exe
./windows/script/build.ps1 -Action Package  # dist.noindex/windows/releases/ 下生成 ZIP 与 SHA256SUMS
```

便携运行时保留完整的 `Perch` 目录。构建、架构与发布说明见 [Windows 文档](docs/windows/architecture.md)。CI 分别检查两端；Windows tag 发布流程已配置，不代表已有发行包。

## 本机数据与隐私

| 数据 | macOS | Windows |
| --- | --- | --- |
| Perch 配置与接力文档 | `~/Library/Application Support/Perch/` | `%LOCALAPPDATA%\Perch\` |
| 新建客户端配置 | 上述目录下的 `Profiles/` | `%USERPROFILE%\.perch\profiles\` |
| 偏好 | `com.omnis.perch`，保留旧偏好域的一次性迁移 | Perch 数据目录下的 `preferences.json` |

现有客户端目录原地引用，导入 agent-desk 配置不删除其数据。交接提示词使用展开后的绝对路径，文档不放在应用包内。macOS 数据使用私有目录／文件权限，Windows 新建数据目录限制为当前用户访问。

平时只保留会话标题、状态、工作目录等元数据。接力仅处理指定的 Markdown；额度授权只在内存中用于官方服务请求，不保存到 Perch 文件或日志，不自动发送聊天。macOS 媒体适配器来源与许可证见 [MediaRemote Adapter](macos/Vendor/MediaRemoteAdapter/UPSTREAM.md)。

## 仓库结构

```text
macos/    SwiftPM、AppKit / SwiftUI、测试与打包脚本
windows/  .NET Core、WPF App、回归测试与打包脚本
shared/   共用素材、中文文案、手工样本与设计约定
docs/     双端架构、验收与发布说明
```

`macos/Sources`、`Tests`、`Vendor` 保留 Swift 命名约定；Windows 使用 `src`、`tests`。构建产物、个人账号配置与临时验收材料均不提交。详见 [架构说明](docs/architecture.md)。
