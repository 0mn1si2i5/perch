# Windows：DeepSeek Harness

跨平台能力及 Mac 原有供应商融合见 [双端 dsh 指南](../deepseek-harness.md)。本页保留 Windows 的安装、DPAPI 和验收细节。

Windows 的账号列表支持 dsh Web。原兼容基线为 `0.1.7-rc.2`；`0.2.1-rc.5` 已验证自动发现、隔离 Web 启动、认证、会话查询和手动连接恢复。可使用源码构建版、npm 全局／项目本地安装版、官方 npx 缓存，或连接已经启动的本机 Web 实例。Electron Desktop 原生宿主、离线历史日志、子 agent 树和第三方提供方计费查询不在本次范围内；新版钱包与真实模型任务未随本次重验。

## 添加与启动

1. 点“新建账号”→“dsh”，填写名称。
2. 选择启动方式：源码构建版选择 deepseek-harness 仓库根目录；npm 版点击“重新识别”，从带来源和版本的列表选择安装。也可填写或选择 `dsh.cmd`／`dsh.ps1`、`package.json`、`@deepseek-ai/dsh` 包目录、npm 前缀或包含本地安装的项目目录，点“检查配置”。检查只验证启动文件与配置，不启动服务、不替代 Node 版本要求。
3. 数据目录留空会创建独立 `DSH_HOME`；要使用已有模型与登录环境，选择已有 home（默认通常是 `%USERPROFILE%\.dsh`）。安装目录和账号数据目录是两件事，引用已有 home 不会复制凭据。
4. 高级设置可选择 `node.exe` 和 Web profile，默认自动发现 Node、使用 `web`。自定义 profile 须已创建并包含 Web 能力，`desktop` 不可用。
5. 创建并启动后，在浏览器的 dsh 中登录或配置模型。Perch 不代填凭据，也不发送提示词。

源码版本须先完成 `pnpm install` 和 `pnpm run build`，包含构建后的 CLI 与 Web 资源。Perch 不自动构建、安装依赖或升级 dsh。npm 版本从 package manifest 解析 CLI，再由 Node 直接启动，不依赖 `.ps1` 执行策略。Node 须满足所安装 dsh 版本的要求。

每个受管 home 使用 `--host 127.0.0.1 --port 0 --no-open`，由系统分配空闲端口。Perch 从本次启动输出取得真实授权 URL，认证成功后打开浏览器；不同 home 可同时运行。同一个 home 不由 Perch 重复启动。

### 自动识别范围与失败后的添加方式

以 [dsh 官方 README](https://github.com/deepseek-ai/deepseek-harness#run) 的 npm／npx 与源码方式为依据。识别检查当前进程和系统保存的 PATH、其中的 dsh 命令包装器、`npm_config_prefix`、用户 `.npmrc` 的 `prefix`／`cache`、默认 npm 全局目录，以及 npm 缓存 `_npx/<实例>/node_modules/@deepseek-ai/dsh`。只接受包名正确且 manifest 声明的 CLI 入口存在的安装；损坏安装跳过，重复位置去重。PATH 来源优先，npx 缓存按最近修改排序；有多份时由用户确认版本，不自动安装或升级。

识别过程只读安装元数据和包装器，不执行 npm、npx 或包装脚本；`.npmrc` 只使用 prefix／cache 路径字段。相对 PATH 项不搜索，不递归扫描整个磁盘，不读取 dsh 登录凭据。仅支持可静态解析的常见 npm／PowerShell 和路径变量包装器，任意自定义脚本可改用包目录或已有实例。

- 已安装但未识别：在账号页点“没有发现 dsh？手动添加…”，或新建页展开“未识别到？手动添加指引”。终端运行 `where.exe dsh` 后选择输出的命令文件；或运行 `npm.cmd root -g`，选择输出目录下的 `@deepseek-ai/dsh`。
- 尚未安装：按官方说明安装满足要求的 Node.js，运行 `npx.cmd @deepseek-ai/dsh web`（Windows 使用 `.cmd` 避免 PowerShell 脚本执行策略问题）。页面可复制命令并打开官方说明。启动后重新识别 npx 缓存，或切换“连接已有实例”，粘贴终端输出的完整 token URL。
- npx 缓存会被 npm 清理；缓存不存在后需重新识别或选择稳定的安装目录。Perch 不在后台重新下载。
- 官方 Desktop 的原生宿主采用私有 IPC 授权，不能从窗口地址建立 Web 连接。不要将 Electron EXE 当成 node.exe 或选择 `desktop` profile；可按官方 Web 命令另开 Web 服务并连接。参见 [官方 Desktop 运行与授权说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/README.md)。

识别到安装只会提示添加，需确认账号名称与实际 `DSH_HOME` 后创建。不会把安装目录当作数据目录，也不会自动引用其他实例的登录环境。配置检查与授权错误会留在添加页，并展开指引；修正输入后可重试。

## 连接、后台运行和移除

“连接已有实例”只需要 dsh 启动时输出的完整 `http://127.0.0.1:<端口>/?token=…`（也支持 localhost／IPv6 回环）授权 URL，不需要安装目录。普通不带 token 的页面地址不能建立新连接。认证失效时，账号右键“重新连接…”并粘贴当前启动的 URL。

Perch 的 dsh RPC 只连接本机回环地址，不读取浏览器 cookie。授权 URL、会话 cookie 和恢复连接信息使用当前用户 DPAPI 加密，保存在 `%LOCALAPPDATA%\Perch\dsh\<实例标识>\runtime.bin`；普通账号 JSON 只保存安装与数据目录等配置。原始 stdout／stderr 和 RPC 响应不落盘。DeepSeek API 余额另按下述边界只读已有凭据，并向官方 HTTPS 接口查询。

已有实例如需查询 API 余额，可在账号配置中选择实际 `DSH_HOME` 作为“余额凭据目录”；留空不读取 Key。受管账号使用已有账号数据目录。更改外部实例的余额目录不要求再次粘贴授权 URL，也不会重启 dsh。

退出 Perch 只断开面板连接，独立后台宿主和 dsh 继续运行。重开 Perch 后自动读取现有连接，点击账号不会重复启动。右键“停止 dsh 服务…”并确认才会中断受管任务；手动连接的实例只能“断开连接”，不会被停止。移除账号保留服务和 home，不提供回收 dsh 数据目录的选项。更换启动配置前先停止受管服务；更新 Perch 程序文件前也应先停止这些后台宿主。

## 会话和余额

- 根会话标题、工作目录、更新时间与运行状态来自 `session/list`；标题使用 `projections.values.title` 字符串，与 Web 列表相同。过滤明确标记 `blank=true` 且未运行的预建空白会话；运行中记录始终保留，缺少 `blank` 时不推断为空。无标题的实际会话显示“未命名会话”。点击会话打开对应 Web，具体对话在 dsh 内选择。
- 对空闲／未运行会话，通过不激活 Agent 的 `session/projections` 获取当前事件游标，再用 `session/page` 读取最近一个消息窗口，仅提取最新 `turn/start`／`turn/end` 的生命周期。只有明确 `reason.kind=completed` 才显示绿色 ✓ 与“已完成”；中断／取消／fork 关闭显示“已停止”，错误／阻塞／输出上限显示“遇到问题”，未知原因显示“状态未知”。没有结束证据或接口不可用时保留空闲／未运行，待处理输入不会沿用旧勾选。读取结束后再次查询列表，新提示或运行状态优先于历史完成。正文可能随事件窗口进入内存，但不搜索、不展示、不记录、不落盘；缓存仅保留事件游标和解析状态，同一游标不重复请求事件窗口。
- 面板或桌宠可见时每 5 秒、全部隐藏时每 20 秒异步刷新。断连保留上次元数据并标注缓存时间，任务状态变为未知，不触发成功通知。
- 官方登录钱包与 DeepSeek API 余额独立展示，不同查询失败互不覆盖。官方钱包按币种显示充值、赠送；API 余额按币种显示总额、充值、赠送，保留十进制精度，不折算百分比或重置时间。使用 `session/modelCatalog`、`settings/describe` 和 `credentials/describe` 确认默认提供方、Key 引用及来源；配置存在不等于服务端验证成功，模型列表存在也不代表密钥存在。不同会话可使用不同模型，默认通道不代表所有会话。
- 不依赖 dsh-cost-meter。仅当默认提供方为 `deepseek-official`、凭据来源为 `file`、模型端点没有明确指向第三方时，读取对应 home 的 `.credentials.yaml`（`version: 1` 的 `refs[apiKeyEnv]`）。只读、不迁移、不保存密钥副本。环境注入、项目／home `.env`、未知来源及自定义凭据文件路径暂不支持，不回退到较低优先级的 Key，也不读取其他进程环境。已有实例的 home 由用户指定，须与连接的实例对应。
- Key 会在 Perch 内存中用于 Bearer 鉴权，仅请求固定的 `https://api.deepseek.com/user/balance`；拒绝重定向，保留系统证书验证，不记录 Key、请求头或原始错误正文。没有把 Key 放到 URL、账号 JSON、DPAPI 连接记录或演示数据中。dsh 自己的凭据文件并非 Perch 加密存储；读取已有文件不会增强或改变其原有保护。
- 账户与计费状态自动查询间隔为 30 秒，API 余额网络请求每 5 分钟一次，手动刷新立即查询。每次检查重新读取目标凭据，Key、引用、home 或来源变化清除旧 API 缓存；同一凭据查询失败保留上次成功结果并注明缓存时间，首次失败显示不可用，不显示“不限”或虚构零余额。第三方余额仍需到提供方查看。
- 分组使用 dsh 官方白色鲸鱼 SVG 徽标，浅色主题加深色底以保持可见。
- 文档接力与拆出需求已随上游移除；旧版 `handoffs/` 数据保留，不再读取。dsh 的账号、服务、会话与余额功能保留。

## 复验入口

```powershell
windows/script/build.ps1 -Action Test
windows/script/build.ps1 -Action Publish
windows/script/build.ps1 -Action Package

# 运行中的 dsh 宿主锁定原发布目录时，输出到另一个目录，不停止个人任务
windows/script/build.ps1 -Action Package -OutputDirectory dist.noindex/windows/Perch-api-balance

# 显式选择真实已配置账号复验；只输出成功状态，不输出 Key 或金额
dotnet run --project windows/tests/Perch.Core.Tests -- --dsh-api-balance-check <Perch数据目录> <dsh账号ID>

# 可选：真实 dsh 包的隔离 smoke，不发提示词、不调用模型
dotnet run --project windows/tests/Perch.Core.Tests -- --dsh-discovery-smoke

# 使用最终发布程序作为独立宿主
dotnet run --project windows/tests/Perch.Core.Tests -- --dsh-discovery-smoke <Perch.exe绝对路径>

# 旧版源码／npm 双安装 smoke
dotnet run --project windows/tests/Perch.Core.Tests -- --dsh-smoke <源码仓库> <npm包目录>

# 以自包含 Perch.exe 为宿主；可加 --browser 请求打开测试页面并保留 45 秒
dotnet run --project windows/tests/Perch.Core.Tests -- --dsh-smoke-published <源码仓库> <npm包目录> <Perch.exe绝对路径>

# 演示新增页面，不读取真实客户端
dist.noindex/windows/Perch/Perch.exe --demo --page add --client dsh --dsh-mode source --theme dark --screenshot scratch/dsh-add
```

真实 smoke 在仓库 `scratch/dsh-smoke-<ID>` 下建立两个独立 home，验证真实启动、授权交换、会话列表、未登录余额返回、手动连接／断开及恢复连接，结束时只停止测试服务。`--data-root <目录>` 可用于正常产品路径的隔离 UI 验收；它不是 demo，仍会发现本机 Codex／Claude，验证时不要添加或改变个人登录配置。

官方登录余额与真实任务状态需要相应测试账户与用户在客户端发送消息；未执行时必须单独标记，不可用演示或样本替代。
