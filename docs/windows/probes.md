# Windows 版探针清单

本文写给在 **Windows 电脑**上工作的 agent。你只能看到 Perch 仓库，没有之前的对话上下文；读完本文就能开工。

## 背景

Perch 是 macOS 菜单栏应用，用 Swift 写成，代码在本仓库。它的功能：

- 管理本机多个 Codex / Claude 桌面客户端账号。每个账号是一个独立的 Chromium `--user-data-dir`；Codex 账号另有自己的 `CODEX_HOME`。
- 启动或调出对应客户端，显示任务状态和最近会话。
- 显示两个客户端的额度：5 小时窗口和每周窗口的用量与重置时间。
- 跨账号文档接力。
- 可选的桌宠。

产品说明见 `README.md`，架构见 `docs/architecture.md`，数据边界也在这两个文件里。

主人打算做 Windows 版。按计划，Windows 版不移植 Swift 代码，而是用 Windows 原生技术重写外壳；技术选型待定，倾向 C# / .NET 8 + WPF 或 WinUI 3。动手之前，必须先在真实 Windows 机器上确认：macOS 版依赖的每一个外部事实，在 Windows 上是否成立、换成了什么。这就是本文的任务。

**你的交付物是一份探针报告，不是 Windows 版代码。**

## 规则

1. **不碰用户数据。** 不删除、不修改 Codex / Claude 客户端的任何数据目录、数据库或配置。
   - 读 SQLite 时用只读方式，例如 `file:...?mode=ro` 或 `immutable=1`；遇到锁就先复制到临时目录再读。
   - 启动测试只用你自己新建的空目录，统一放在 `%USERPROFILE%\perch-probe\` 下。
   - 测试结束后，只清理你自己创建的东西，而且移到回收站，不要永久删除。
2. **不泄露隐私。** 报告、日志、提交里一律不得出现以下内容：
   - 邮箱、token、cookie、钥匙或密码；
   - 聊天正文、对话标题；
   - 完整的组织或账号 UUID。

   需要举例时只写字段名、类型、长度，或打码后的片段，例如 `a46b…`。
3. **不替主人登录、不发消息、不消耗额度。**
   - 需要已登录账号的探针，先检查本机有没有现成登录。没有就在报告里标“需主人配合”，写清楚主人要做哪一步，然后继续做其他探针。
   - 会触发模型调用的操作一律不做。查询额度接口不算模型调用，可以做。
4. **每条结论都要有证据。** 证据包括：实际执行的命令（PowerShell）、脱敏后的关键输出、客户端版本号。做不到的写“未验证”，并说明原因，不要猜。
5. **探针脚本放在 `scratch/windows-probes/`。** 这个目录已被 `.gitignore` 忽略，脚本不提交，只提交报告。
6. **工作分支 `windows/probes`。** 报告写到 `docs/windows/probe-report.md`，提交后推送这个分支。不要改 main，不要改 macOS 代码。提交信息末尾加一行：
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## 参考：前人的 Windows 经验（只作线索，都需要实测）

Perch 的前身是 Electron 版 agent-desk，公开仓库在 <https://github.com/shuqianglin1997/agent-desk>（`main` 分支）。它在 Windows 上做过适配，主要在 `src/windows.js`、`src/apps.js`、`src/process.js`、`src/cli-discovery.js` 和 `test/windows.test.js`。可以浅克隆到 `scratch/` 里参考，**不要运行里面的任何代码**。

它当时的假设如下。**这些都是线索，不是结论，你要逐条验证：**

- **Claude**
  - 可执行文件：`Claude.exe`。
  - 安装位置：旧版用 Squirrel 装在 `%LOCALAPPDATA%\AnthropicClaude\app-<版本>\`；新版是 MSIX，包族名 `Claude_pzs8sxrjxfjjc`，位于 `C:\Program Files\WindowsApps\Claude_<版本>_x64__pzs8sxrjxfjjc\app\Claude.exe`；执行别名在 `%LOCALAPPDATA%\Microsoft\WindowsApps\Claude.exe`。
  - 数据目录：`%APPDATA%\Claude`。如果是 MSIX 版，AppData 可能被虚拟化到 `%LOCALAPPDATA%\Packages\<包族名>\LocalCache\Roaming\Claude`。
- **Codex**
  - 可执行文件：`Codex.exe`，MSIX 包族名 `OpenAI.Codex_2p2nqsd0c76g0`，或装在 `Program Files\OpenAI\Codex`。
  - 注意：macOS 上 Codex 桌面版现在以 `ChatGPT.app` 的形式发布，Windows 上的形态需要你确认。
  - 会话数据默认在 `%USERPROFILE%\.codex`。
- **Claude Code CLI 会话**：`%USERPROFILE%\.claude\projects\`。
- **进程命令行**：用 `Get-CimInstance Win32_Process | Select ProcessId,ParentProcessId,CommandLine` 读取。新版 Windows 11 默认已移除 WMIC。
- **独立账号的数据目录**：agent-desk 放在 `%USERPROFILE%\.agentdesk\profiles\<app>\<id>`，有意不放在 AppData 下，以避开 MSIX 虚拟化。

## 探针清单

每个探针都对应 macOS 版的一段代码。先读那段代码，理解 macOS 上是怎么做的，再去 Windows 上找对应的东西。

### W0 环境盘点

- 记录以下信息：
  - Windows 版本和构建号、CPU 架构；
  - PowerShell 版本；
  - 是否装了 .NET SDK（`dotnet --info`）、`git`、`sqlite3`、Node / npm。
- 列出已安装的 Codex / Claude 客户端，记录每个的版本和安装方式：Microsoft Store/MSIX、exe 安装器或 winget。可用 `Get-AppxPackage *Claude*`、`Get-AppxPackage *Codex*`、`Get-AppxPackage *OpenAI*`、`winget list`。
- 记录是否装了 `codex` CLI 和 `claude` CLI，以及它们的位置（`where.exe codex`、`where.exe claude`）。

### W1 定位客户端，并确认是官方的

- macOS 做法：`Sources/PerchCore/Launcher/AppLocator.swift`。按名字找到 `.app`，再核对 bundle id（`com.openai.codex` / `com.anthropic.claudefordesktop`），防止同名的冒牌 App。
- 需要确认：
  - 两个客户端的真实 exe 路径，各种安装方式都要覆盖；
  - MSIX 包族名；
  - 执行别名的位置。
- Windows 上用什么代替 bundle id 做身份校验？候选：
  - `Get-AuthenticodeSignature` 查看签名者（发布者名称）；
  - MSIX 的 `PackageFamilyName` / `Publisher`。
- 产出：一条可靠的定位顺序，以及身份校验规则。

### W2 默认数据目录

- macOS 做法：`Sources/PerchCore/Accounts/Account.swift` 中的 `defaultProfilePath` / `defaultSessionRoot`。
  - Claude 的数据目录在 `~/Library/Application Support/Claude`，会话根就是这个目录本身。
  - Codex 的 Chromium 数据目录在 `~/Library/Application Support/Codex`，会话在 `~/.codex`。
- 需要确认：
  - 客户端正常打开（不带参数）时，Chromium 数据目录实际在哪里。
  - MSIX 版是否被虚拟化到 `LocalCache`。确认方法：看哪个目录的修改时间随客户端使用而更新。
  - 目录里能证明“这是该客户端数据目录”的标志文件，例如 `Local State`、`config.json`、`claude-code-sessions`。
- 产出：每个客户端、每种安装方式对应的默认数据目录和会话根。

### W3 多账号启动（最关键）

- macOS 做法：`Sources/PerchCore/Launcher/LaunchCommand.swift`，使用 `open -n -a <App> [--env CODEX_HOME=…] --args --user-data-dir=<目录>`。
  - `-n` 强制开新实例；
  - 每个账号的登录和数据完全独立；
  - Codex 另外通过环境变量 `CODEX_HOME` 指定会话目录。
- 在 Windows 上实测，**两个客户端分别测**：
  1. 默认实例已在运行时，用 `--user-data-dir=%USERPROFILE%\perch-probe\<app>-a` 启动第二个实例。
     - 能否真的开出第二个窗口和进程？还是被单实例锁转回第一个实例？
     - 新实例是否显示全新的登录界面？这证明数据隔离。不需要真的登录。
  2. 经过执行别名、经过 MSIX 包、直接运行 exe，三种方式下，命令行参数能否传进去？
  3. Codex：给新实例设置 `CODEX_HOME=%USERPROFILE%\perch-probe\codex-a\codex-home` 环境变量，它是否生效？
     - 判断方法：启动后该目录下是否生成了 Codex 的文件。
     - 重点确认：MSIX 应用能否继承启动者的环境变量。
  4. 如果把 `--user-data-dir` 指向 AppData 下的路径，是否会被虚拟化？
- 产出：能用的启动命令模板，以及哪种安装方式下不可行。不可行时写降级方案，比如“只支持默认实例”或“只支持 exe 安装版”。

### W4 判断哪个账号正在运行

- macOS 做法：`Sources/PerchCore/Launcher/ProcessMatcher.swift`。
  - 读取所有进程的命令行，找到带有该账号 `--user-data-dir=<目录>` 的**主进程**；带 `--type=` 的是辅助进程，要排除。
  - 不带这个参数的主进程，属于默认数据目录的账号。
- 需要确认：
  - Windows 上主进程和辅助进程的命令行长什么样；
  - 用 CIM 读一次全部进程命令行要多久（Perch 每 5 秒轮询一次）；
  - 普通权限下能否读到这些命令行。
- 产出：匹配规则，以及性能数据。

### W5 把已运行的实例调到前台

- macOS 做法：在 `Sources/PerchCore/Launcher/Launcher.swift` 里，已在运行就激活对应的 pid，不重复启动。
- Windows 对 `SetForegroundWindow` 有限制。用一小段 PowerShell + P/Invoke 实测：
  - 能否从后台程序把指定 pid 的主窗口调到前台；
  - 窗口最小化时能否恢复；
  - 常见变通方法（`AllowSetForegroundWindow`、先 `ShowWindow(SW_RESTORE)` 等）是否有效。
- 产出：可行的做法，以及限制。

### W6 Codex 任务数据

- macOS 做法：`Sources/PerchCore/CodexTasks/CodexReader.swift`，读取 `CODEX_HOME` 下的三样东西：
  - `state_5.sqlite` 的 `threads` 表；
  - `thread_history_1.sqlite` 的 `thread_turns` 表；
  - `sessions/` 下的 rollout `.jsonl` 文件末尾的回合事件。
- 需要确认：
  - 文件名和表结构是否一致。用 `PRAGMA table_info(...)` 看列名，不要输出行内容。
  - Codex 运行时只读打开会不会被锁（`SQLITE_BUSY`）。
  - rollout 的路径格式，包括反斜杠和盘符。
- 产出：差异清单。

### W7 Claude 会话数据

- macOS 做法：`Sources/PerchCore/ClaudeSessions/ClaudeSessionReader.swift`，读取 `~/.claude/projects/<项目>/<会话>.jsonl`，只看记录类型、`cwd`、`custom-title` 和最后一个回合的结构。
- 需要确认：
  - Windows 上对应的目录；
  - 项目目录名怎么由 Windows 路径编码而来；
  - 记录结构是否相同。只统计字段名和 `type` 的取值，不要输出正文。
  - Claude 桌面版的 Code 标签页会话存在哪里：数据目录下的 `claude-code-sessions\`，还是也写进 `.claude\projects`。
- 产出：路径和差异。

### W8 Codex 额度

- macOS 做法：
  - `Sources/PerchCore/Quota/CodexCLI.swift` 负责找到 `codex` CLI。顺序是：环境变量、PATH、npm 全局目录、客户端自带的副本；npm 包内的原生二进制优先。
  - `Sources/PerchCore/Quota/CodexAppServer.swift` 以该账号的 `CODEX_HOME` 运行 `codex app-server --listen stdio://`，通过 JSON-RPC 依次发送 `initialize`、`initialized`、`account/read`、`account/rateLimits/read`，读到结果后结束进程，超时 10 秒。
  - 回退方案见 `Sources/PerchCore/Quota/QuotaCache.swift`：从 rollout 文件末尾的 `token_count` 事件里取 `rate_limits`。
- 需要确认：
  - Windows 上 `codex` 的位置：`%APPDATA%\npm\codex.cmd`、npm 包里的原生 `codex.exe`，或客户端安装目录里自带的副本。
  - `.cmd` 包装脚本和原生 exe，哪个适合直接用 stdio 通讯。
  - 用一个已登录账号的 `CODEX_HOME` 跑一遍上面的 JSON-RPC 流程。记录返回结构的字段名和窗口时长，去掉 `email` 等身份字段。
  - 超时后能否把整个进程树干净地结束。macOS 上曾经遗留孤儿子进程。
- 产出：可行性、命令、响应结构。

### W9 Claude 额度

macOS 版有两条路，Windows 上分别验证。

**本地缓存**（`Sources/PerchCore/Quota/ClaudeQuotaCache.swift`）：
- 读取数据目录下的 `plan-usage-history.json`；
- 读取 `IndexedDB\https_claude.ai_0.indexeddb.blob\` 里缓存的 Claude Code `rate_limit_event`。这类文件以 `FF 11 02` 开头，后面是 Snappy 压缩的 V8 序列化数据。
- 需要确认：Windows 数据目录下这些文件是否存在、格式是否相同。

**实时查询**（`Sources/PerchCore/Quota/ClaudeQuota.swift`）：
- macOS 上的做法：
  - 读取数据目录 `config.json` 里的 `lastKnownAccountUuid` 和 `oauth:tokenCacheV2`；
  - 后者是 Electron safeStorage 加密的数据，在 macOS 上用钥匙串里的 “Claude Safe Storage” 钥匙解开；
  - 选出与当前账号、组织匹配且带 `user:profile` scope 的 token；
  - 只在内存里使用它，请求 `https://api.anthropic.com/api/oauth/usage`，请求头带 `anthropic-beta: oauth-2025-04-20`。
- 主人已经接受“读取对应账号的登录授权、只在内存使用”这一做法，Windows 版沿用同一口径。
- 在 Windows 上，Electron safeStorage 通常是这样实现的：
  - `Local State` 文件里的 `os_crypt.encrypted_key`，经 base64 解码、去掉 `DPAPI` 前缀后，用 DPAPI（`CryptUnprotectData`，当前用户）解出 AES-256 钥匙；
  - 密文以 `v10` 开头，后面是 12 字节 nonce、AES-GCM 密文和 16 字节 tag。
- 需要逐项实测：
  - `config.json` 里是否有同名字段；
  - 加密格式是否如上；
  - 在内存中能否解出 JSON，以及条目 key 的格式是否和 macOS 一致（形如 `acct:<uuid>|…:https://api.anthropic.com:<scopes>`）；
  - 请求接口时只记录 HTTP 状态码和响应的顶层字段名（`five_hour`、`seven_day` 等）。
- **任何情况下都不得输出、保存 token 或钥匙。**
- 产出：两条路各自是否可行。

### W10 深链

- macOS 结论在 `Sources/PerchCore/Launcher/SessionRouting.swift`：
  - `codex://threads/<id>` 能打开指定对话，但多个实例同时运行时，无法保证由哪个实例接收；
  - Claude 没有可用的会话深链。
- 需要确认：
  - Windows 上 `codex://`、`claude://` 是否已注册（查注册表 `HKCU\Software\Classes`）；
  - 多个实例同时运行时由哪个实例接收；
  - Claude 是否有能打开指定会话的链接。

### W11 Codex 运行目录的路径长度

- macOS 问题见 `Sources/PerchCore/Launcher/RuntimeHome.swift`：Codex 会在 `CODEX_HOME\ipc\` 下建 Unix socket，而 macOS 限制 socket 路径不超过 104 字节，长路径要借助软链接。
- 需要确认：
  - Windows 上 Codex 在 `CODEX_HOME` 下建了什么：socket、命名管道，或者什么都没有；
  - 很长的 `CODEX_HOME` 路径是否会出问题。

### W12 Perch 自身的数据位置（不用实测，给出建议即可）

macOS 上 Perch 的数据放在 `~/Library/Application Support/Perch/`：`accounts.json`、`handoffs\`、`log.jsonl`。

- Windows 上建议放在 `%APPDATA%\Perch\`，还是别处？
- 如果 Perch 本身用 MSIX 打包，它自己的 AppData 也会被虚拟化。请说明这对放置位置有什么影响。
- 交接文档要求目录权限 0700、文件 0600，Windows 上用什么 ACL 达到同等效果？

## 报告格式（`docs/windows/probe-report.md`）

开头写环境概要，也就是 W0 的结果。然后一张总表：

| 探针 | 结论 | 一句话说明 | 对 Windows 版的影响 / 降级方案 |
|---|---|---|---|
| W1 | 可行 / 有条件可行 / 不可行 / 未验证（需主人配合） | … | … |

总表之后，每个探针一节，写清楚：

- 执行的命令；
- 脱敏后的关键输出；
- 客户端版本；
- 结论；
- 和 macOS 版的差异；
- 遗留问题。

最后一节写“建议的 Windows 版 MVP 范围”。根据探针结果，列出第一版能做哪些功能、哪些要降级、哪些先不做，以及哪些地方需要主人配合，比如登录第二个账号测试多开。

完成后推送 `windows/probes` 分支，并向主人报告：报告位置、总表、需要主人配合的事项。
