# Perch 双端架构

Perch 在本机管理 Codex、Claude 桌面账号，读取任务与额度，对话状态变化时发通知。两端分别实现原生窗口和桌宠，平台代码不互相依赖。

- `macos/`：SwiftPM、AppKit/SwiftUI；[macOS 架构](macos/architecture.md)。偏好域迁移仍保留。
- `windows/src/Perch.Core/`：持久化、只读会话、进程隔离、额度、会话状态变化；不依赖 WPF/WinForms。
- `windows/src/Perch.App/`：WPF 视图、增量 ViewModel、主题、托盘、全局快捷键、桌宠。WinForms 仅托盘宿主；无第三方 UI 框架。
- `shared/assets/`：唯一品牌与精灵素材；`strings/`：共享文案；`fixtures/`：手工样本和期望值；`design/tokens.md`：设计依据；[功能对齐](../shared/parity.md)。Windows 消费共享文案和样本；macOS 会话测试消费 Claude 共享样本，新增桌宠文案读取共享 JSON，构建脚本将原文件复制进应用资源。此次 Mac 文案与桌宠改动的测试、构建及实机均待 Mac 验证，其余 Mac 文案尚未全部接入共享 JSON。

Windows 轮询通过进程内 Win32 查询，显示时 5 秒、全部隐藏时 20 秒。客户端发现使用 WinRT 包管理，API 不可用时只回退一次 PowerShell。按账号 profile/home 匹配主进程；不会把子渲染进程当账号。

会话数据库以 SQLite READONLY 打开。标题优先客户端元数据索引，不以提示词冒充生成标题。额度使用对应账号本地授权，Claude DPAPI 解密仅在内存中，向官方地址查询；第三方模式不假造官方订阅额度。

会话监控主要读取元数据，不自动发送聊天。两端 dsh Web 为判断最近回合的结束状态会请求最近一个消息事件窗口，正文可能随响应进入内存，但不搜索、不展示、不记录、不落盘；缓存仅保留事件游标与解析状态。详见 [dsh 数据边界](deepseek-harness.md#任务和余额)。文档接力和拆出需求已于 2026-10-21 从两端删除，数据目录里旧的 `handoffs/` 保留，不再读取。

dsh Web 在两端使用同一协议行为和 `shared/fixtures/dsh` 样本；macOS 通过已有 `.deepseek` 账号的可选 Web 配置融合到 provider 面板，原有 DSH Desktop／终端入口仍可用。Windows 保留 WPF 账号入口。后台宿主与锁分别使用本机进程机制，本机连接授权分别进入 macOS 钥匙串与 Windows DPAPI。两个钱包独立缓存，换连接时清除旧身份结果。共享行为与原生实现的边界见 [双端指南](deepseek-harness.md)。

Windows 版本来自 `windows/VERSION`，tag 为 `windows-v*`；macOS 版本来自 `macos/VERSION`，tag 为 `macos-v*`。CI 按目录分别运行。已发布的 macOS 1.0.x 保留旧 `v*` tag。Windows 0.2.0 已发布预览版，自包含 x64 ZIP 与 SHA256 可本地生成；尚无安装器、签名或开机启动。Windows 新增 dsh Web 支持，独立后台宿主与本机认证 RPC 不依赖 dsh 源码导入；详细模块与运行见 [Windows 架构](windows/architecture.md)。
