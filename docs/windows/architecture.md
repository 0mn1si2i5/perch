# Windows 架构与本地运行

Windows 版本来自 `windows/VERSION`，当前为 0.2.0。系统要求 Windows 10 19041+ x64，实际界面检查在 Windows 11 完成。使用 C# / .NET 10 / WPF，运行自包含便携包无需 SDK。

## 模块

- `windows/src/Perch.Core`：账号与偏好、进程查询、客户端定位、只读会话、额度、接力事务和屏幕定位策略。
- `windows/src/Perch.App`：WPF 页面、增量 ViewModel、系统明暗／Pox 主题、托盘、Ctrl+Alt+P 快捷键和桌宠。WinForms 仅用于托盘宿主。
- `windows/tests/Perch.Core.Tests`：独立回归程序，消费 `shared/fixtures` 手工样本；使用 Windows 原生 SQLite API。
- `shared/strings`、`assets`、`design`：共用文案、品牌与精灵素材、设计约定。平台差异见 [功能对齐](../../shared/parity.md)。

## 构建

在仓库根目录运行：

```powershell
./windows/script/build.ps1 -Action Test
./windows/script/build.ps1 -Action Run
./windows/script/build.ps1 -Action Publish
./windows/script/build.ps1 -Action Package
```

可通过 `-Dotnet <dotnet.exe 的路径>` 选择 SDK。输出为 `dist.noindex/windows/Perch/Perch.exe`；便携运行时保留整个目录。打包输出见 [发布说明](releasing.md)。

## 数据与客户端边界

- Perch 配置与接力文档位于 `%LOCALAPPDATA%\Perch`，新建客户端目录位于 `%USERPROFILE%\.perch\profiles\<短 ID>`；引用已有目录不迁移原数据。
- 新建数据目录禁用权限继承，仅当前 SID 完全控制；交接副本继承专用目录权限。
- 客户端发现使用 WinRT 包管理，无法使用时只做一次 PowerShell 回退；支持验签后的 MSIX 主程序，传统非 MSIX 客户端尚不支持。
- 进程查询在进程内执行，按 profile / home 匹配主进程；面板显示时每 5 秒轮询，全部隐藏时每 20 秒。
- Codex 以 READONLY 读取 SQLite，保留运行中 WAL 可见性，标题优先索引元数据；Claude 按各 profile 读取桌面会话 JSON 与 audit 尾部。未变化的文件使用缓存。
- Codex 用原生 RPC 查询额度；Claude 通过当前账号授权访问官方 usage 服务，DPAPI 解密仅在内存。第三方模式不假造官方订阅额度。
- 接力执行 Read → Clipboard → Commit → Clear；复制失败保留待办，不生成记录或副本。不读取原聊天生成文档、不调用模型或自动发送消息。
- 原生浮球保持系统主题；Pox 主题在隐藏桌宠后保留。媒体感知只读取播放状态及类型，不读取歌曲、视频或窗口标题。

历史探针和逐项开发计划已归档到整理前的备份；当前可用范围与未验收项集中见 [验收说明](acceptance.md)。
