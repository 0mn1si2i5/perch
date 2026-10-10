# Perch 双端架构

Perch 在本机管理 Codex、Claude 桌面账号，读取任务与额度，以指定 Markdown 文档接力。两端分别实现原生窗口和桌宠，平台代码不互相依赖。

- `macos/`：SwiftPM、AppKit/SwiftUI；[macOS 架构](macos/architecture.md)。偏好域迁移仍保留。
- `windows/src/Perch.Core/`：持久化、只读会话、进程隔离、额度、接力事务；不依赖 WPF/WinForms。
- `windows/src/Perch.App/`：WPF 视图、增量 ViewModel、主题、托盘、全局快捷键、桌宠。WinForms 仅托盘宿主；无第三方 UI 框架。
- `shared/assets/`：唯一品牌与精灵素材；`strings/`：共享文案；`fixtures/`：手工样本和期望值；`design/tokens.md`：设计依据；[功能对齐](../shared/parity.md)。Windows 消费共享文案和样本；macOS 会话测试也消费 Claude 共享样本，共享文案的 macOS 接入仍待单独处理。

Windows 轮询通过进程内 Win32 查询，显示时 5 秒、全部隐藏时 20 秒。客户端发现使用 WinRT 包管理，API 不可用时只回退一次 PowerShell。按账号 profile/home 匹配主进程；不会把子渲染进程当账号。

会话数据库以 SQLite READONLY 打开。标题优先客户端元数据索引，不以提示词冒充生成标题。额度使用对应账号本地授权，Claude DPAPI 解密仅在内存中，向官方地址查询；第三方模式不假造官方订阅额度。

接力按 Read → Clipboard → Commit → Clear 执行；复制失败保留待办且不产生记录或副本。只处理用户指定的 Markdown，不自动发送聊天。

Windows 版本来自 `windows/VERSION`，tag 为 `windows-v*`；macOS 版本来自 `macos/VERSION`，tag 为 `macos-v*`。CI 按目录分别运行。已发布的 macOS 1.0.x 保留旧 `v*` tag。Windows 自包含 x64 ZIP 与 SHA256 可本地生成；尚无远端发行包、安装器、签名或开机启动。Windows 详细模块与运行见 [Windows 架构](windows/architecture.md)。
