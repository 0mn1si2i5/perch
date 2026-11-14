# Windows 验证与验收

## 2026-11-14：PR #6 修复与双端协议回归

修复 home 路径检查与创建不一致、桌宠双击错用原生启动入口、重连沿用旧钱包；受管重连限制原进程的 origin。自动计费查询进入 30 秒缓存调度，API 网络请求保留 5 分钟缓存，手动刷新可立即查询。

Linux 上用 .NET SDK 10.0.404 完整交叉编译 Windows solution，0 警告、0 错误；`--dsh-contract-check` 实际运行通过，消费与 Mac 相同的 sessions/outcomes/wallet 样本。新增路径保存、两个隔离 RPC 实例缓存、受管重连及自动／手动节流回归已接入默认测试入口；WPF／DPAPI 和宿主回归由 Windows 原生 CI 执行，结果另行记录。没有启动或改动个人客户端。

## 2026-11-13：PR 准备复验

本轮在 `codex/windows-dsh` 的 `3776b7f` 源码基础上修正文档，未修改产品代码。运行环境为 Windows / .NET SDK 10.0.400。

- `windows/script/build.ps1 -Action Test` 通过：Core 与 WPF 两套回归均成功，覆盖 dsh 安装发现、认证 RPC、DPAPI、独立宿主、API 余额隔离、共享 JSON、账号布局及桌宠图集／切换／主题／生命周期。NuGet 漏洞数据源不可达，出现 NU1900，未获得本轮漏洞审计结果；图集加载另有 libpng iCCP 配置警告，未导致用例失败。
- `windows/script/build.ps1 -Action Package -OutputDirectory dist.noindex/windows/Perch-pr-review` 通过，包含 Release、win-x64 自包含发布及便携 ZIP／SHA256 生成。未覆盖正常产品目录、重启 Perch 或停止个人 dsh／Codex／Claude。
- 本地成品为 `dist.noindex/windows/Perch-pr-review/Perch.exe` 与 `dist.noindex/windows/releases/Perch-Windows-0.2.0-x64.zip`。ZIP 的 486 个条目通过 CRC 检查，SHA256 与 `SHA256SUMS` 一致；程序、运行时、两种图集、dsh 徽标、LICENSE 和 NOTICE 与本次发布目录一致，鲸鱼娘图集及许可文件也与仓库原文件一致。版本仍为 0.2.0，此包包含未发布改动，不等同于 GitHub 上已发布的 0.2.0 Release。
- 将 ZIP 解包后运行独立 `--demo`：DeepSeek 主题设置页／鲸鱼娘完成气泡，以及浅色 dsh npm 添加页，进程均成功退出。逐张检查确认角色、文案、主题、输入框和指引布局正常；不读取真实客户端。日志、包校验结果和截图在忽略目录 `scratch/pr-windows-dsh/`。
- 本轮没有重做真实 dsh 启动 smoke、真实模型任务／完成通知、官方登录钱包、鼠标拖动或媒体播放验收；此前日期记录仅代表当时验证。Mac 无可用环境，新增桌宠与共享 JSON 的 Swift 测试、构建、脱离仓库的应用资源加载和实机交互均未验证，待在 Mac 执行并补录。

## 2026-11-13：桌宠文案共享 JSON 重构

- Windows 与 macOS 的桌宠台词统一以 `shared/strings/zh-CN.json` 为源。Windows 继续嵌入程序集，macOS 构建时复制原文件到应用资源；Swift 中的姿势、角色台词和预览模板副本已移除。Pox 反馈也从通用键读取，鲸鱼娘仅使用其命名空间，浮球仍不显示台词。
- `windows/script/build.ps1 -Action Test` 通过：新增嵌入资源与源 JSON 一致性、全部姿势／反馈的角色分流和 Unicode／`{0}` 格式化检查；实际 WPF 窗口的预览、任务计数、完成标题、切换清理、浮球和安静模式回归通过。文案预期值从 JSON 读取，后续改台词无需同步测试字面量。
- `-Action Package -OutputDirectory dist.noindex/windows/Perch-shared-strings` 发布与打包通过，成品为该目录下的 `Perch.exe`；未替换运行中的 Perch。新成品的 135px 鲸鱼娘／Pox 完成气泡截图位于 `scratch/shared-strings-qa/{deepseek-whale,pox}/dark-pet.png`，逐张检查台词与角色对应、标题和特殊符号显示完整。
- Mac 构建脚本 `bash -n` 语法检查通过，但当前无 Swift／Mac 环境，Mac 编译、测试及脱离仓库的应用包运行仍待验收，不能以此语法检查代替。维护方式见 [文案说明](../../shared/strings/deepseek-whale-copy.md)。

## 2026-11-13：dsh 安装发现与手动添加

- 参照 dsh 官方 README 的 npm／npx 和源码启动说明，以及官方 Desktop 的私有 IPC 授权边界；未把本机安装目录写入产品规则。新增 PATH 包装器、npm 前缀／用户 npmrc 路径和 npx 缓存发现，验证 manifest 包名与 CLI 入口，列出来源／版本并去重；支持命令文件、manifest、包、前缀和项目目录的手动选择。
- 新建页与账号页提供手动添加入口，包含持久检查结果、Node 要求、官方命令复制／说明链接、已有实例连接和安装／DSH_HOME 区分。外部授权失败也保留在页面上。Desktop 原生宿主不接管。
- `windows/script/build.ps1 -Action Test` 通过（Core 与 WPF）；覆盖损坏包、缺失入口、npx 缓存清理、npm／PowerShell／自定义路径变量包装器、重复安装和手动连接引导。WPF 展开的完整指引已渲染检查；最终自包含程序的浅／深／Pox 添加页截图均通过，保存在忽略目录 `scratch/dsh-discovery-qa/`。
- 本机实际 `0.2.1-rc.5` 由 PATH 命令静态解析发现；用仓库 scratch 下新建的独立 home，经最终发布程序的后台宿主验证真实启动、动态端口、认证、空会话查询、手动 token URL 连接／断开及恢复不重复启动。未调用模型、读取或更改个人 home 的登录配置；只停止隔离测试服务。新版钱包、真实模型任务和 Desktop 原生窗口未随本次验证。
- 自包含 Package 成功，验证输出为 `dist.noindex/windows/Perch-discovery/Perch.exe`，便携包为 `dist.noindex/windows/releases/Perch-Windows-0.2.0-x64.zip`。只重启了 Perch 面板，将同一构建复制到正常入口 `dist.noindex/windows/Perch/Perch.exe` 并核对文件哈希；未停止个人 dsh／Codex／Claude，未发布远端版本。macOS 本次未修改、未构建。

## 2026-10-24：同步 upstream/main

在 Windows / .NET 10.0.400 上完成上游与 dsh 集成：Core 全套回归通过，Release 自包含发布和便携打包通过，三主题四页面及 dsh 补充页面共 15 次 demo 截图运行成功。采用上游删除接力的行为，保留旧数据；dsh 账号、监控、余额与后台服务保留。冲突文件、处理方式、输出路径与验收边界见 [上游同步记录](../upstream-sync.md)。以下旧日期记录是历史验证，接力功能不再属于当前验收范围。

## 2026-10-14：dsh 会话完成勾选

- Windows Test、Publish／Package 通过。回归覆盖明确完成、取消／中断／fork、错误／阻塞／输出上限、未知结束原因、新任务覆盖旧完成、待处理输入、事件接口失败降级、游标缓存与完成会话接力。
- 只读核对已有本机服务的 32 条根会话：25 条明确完成、7 条停止；逐条重新读取完成记录的最近事件，确认绿色勾选对应 `turn/end` 的 `completed`，未发送提示词、调用模型或保存正文。
- 最终自包含程序的演示与真实账号截图均已检查，完成会话显示绿色 ✓ 与“已完成”，停止会话显示红色 ! 与“已停止”。截图仅保存在忽略目录 `scratch/dsh-completion-ui-dark` 与 `scratch/dsh-completion-real-ui`。截图验收后以普通 `--show` 启动新版面板。
- 新版位于 `dist.noindex/windows/Perch-completion/Perch.exe`；原目录被 dsh 宿主占用，保留原宿主和 node 服务，只重启 Perch 面板。未关闭 Codex／Claude、修改登录配置或发布远端版本。实时模型任务的完成通知与完整人工接力流程仍待相应验收。

## 2026-10-14：独立 DeepSeek API 余额查询

- Windows Test、Publish、Package 通过；API 凭据解析与错误信息脱敏、官方固定端点／重定向拒绝、CNY／USD 十进制金额、限流／超时／鉴权失败、五分钟节流与手动刷新、Key／引用／home 变化和账号缓存隔离通过回归。环境／dotenv 来源不回退到文件 Key。
- 通过正常 DshService 查询本机已有账号的官方 API，取得非缓存的 CNY 总额／充值／赠送结果；没有输出 Key 或金额，没有复制密钥、修改登录或调用模型。官方登录账户仍为未登录，此结果不代表登录钱包验收。
- 使用最终自包含 Perch.exe，以 `--data-root` 在仓库 scratch 的隔离配置中复用 DPAPI 加密的已有本机授权，选择实际 home，正常查询并显示 API 余额；不是 demo，不依赖 dsh-cost-meter。截图检查了真实结果、浅／深主题演示卡片和外部实例的可选凭据目录。
- 演示截图位于 `scratch/api-balance-qa/light`、`dark`、`external`，真实产品截图位于 `scratch/api-balance-qa/real`；真实截图只留本机 scratch，不纳入版本控制。截图可使用 `--screenshot-delay-ms 20000` 等待异步刷新。
- 原发布目录被仍在运行的个人 dsh 宿主占用，新版输出到 `dist.noindex/windows/Perch-api-balance/Perch.exe`；便携 ZIP 在 `dist.noindex/windows/releases`。旧宿主保留运行，没有停止 dsh、Codex 或 Claude，也未发布远端 Release。便携包包含 YamlDotNet 的 MIT 版权与许可通知。

## 2026-10-14：dsh 徽标、登录／计费状态与会话标题修复

- 对照本机真实 `0.1.7-rc.2` RPC 验证：35 个根会话及其工作目录可读，32 个已命名会话与 Web 的 `projections.values.title` 字符串一致，其余无标题；未保存或输出真实标题及正文。
- 本机真实官方账户状态为 `signed-out`，默认模型提供方为 `deepseek-official`，脱敏凭据接口确认 API Key 已配置。修复后分别显示默认 API Key 计费通道与官方账户登录状态。API Key 余额不由 dsh 官方账户钱包接口提供，仍需在提供方查看。
- Windows Core 全套测试通过，增加字符串标题、历史标题、未配置密钥、第三方通道、过期登录和未知账户状态回归。测试依赖当前用户 DPAPI，需在当前用户环境运行；沙箱身份下的 DPAPI 失败不算通过。
- 最终自包含构建通过；真实源码／npm 两个隔离 home 的启动、认证、未配置密钥、手动断开与恢复连接 smoke 通过。明暗主题演示截图在 `scratch/qa-dsh-fix/`，白色鲸鱼在浅色主题使用深色底。
- 本地 `dist.noindex/windows/Perch/Perch.exe` 已替换并重启面板，原有 dsh 宿主保持运行，替换后真实连接复验通过。运行中的宿主锁定发布目录，直接 Package 的 Publish 步骤无法覆盖 apphost；改从已验证的独立发布目录打包同样的便携 ZIP，并保留旧构建供运行中的宿主使用。未发布远端 Release，未改变个人登录配置，未停止个人客户端。
- 真实网页登录官方账户的非空钱包余额仍待相应账户实测；已通过协议样本验证精度及错误分支。

## 2026-10-14：dsh Web 适配

- .NET 10.0.400 下 Test、Release Build、Publish、Package 通过，生成本地自包含便携包；未发布远端 Release。NuGet 直连 TLS 失败后，使用微软官方 dotnet-public 源下载原有依赖到仓库 scratch 缓存，未修改依赖来源配置。
- 回归覆盖源码／npm 本地安装解析、含空格路径、缺少 Node／Web 构建、旧排序兼容、DPAPI 加密、命名 RPC 参数与认证、请求相关性及错误／取消、钱包精度、缓存与接力保护。
- 独立测试进程启动服务后真正退出，服务仍存活；后台宿主异常退出后正确报告存活子进程且不重复启动；子进程退出后缓存转为未知、阻止来源接力；移除记录保留服务，外部实例断开不会停止它。
- 本机源码构建版和 npm 全局安装版均为 dsh `0.1.7-rc.2`。用两个隔离 home 验证真实启动、动态端口、认证、会话列表、手动连接／断开和恢复连接，并用最终自包含 Perch.exe 再次验证宿主路径。两个 home 均无会话，真实余额接口验证的是未登录返回，不是登录钱包或真实任务。
- 三主题下源码／npm／已有实例配置页及 dsh 会话／钱包卡片共 12 个演示渲染通过；检查了布局、文字和金额。演示不读取真实客户端。默认浏览器打开请求已执行，浏览器内容与完整鼠标／键盘创建流程未验收。
- 使用提供的测试 Markdown 验证 dsh 来源／目标的接力事务；未自动发送消息。官方登录余额、真实运行／等待／结束任务及源 agent 生成文档后目标 agent 实际接手仍待人工实测。

截图位于本机 `scratch/qa-dsh/`，真实复验入口和范围见 [dsh 指南](deepseek-harness.md)。上述测试只停止隔离测试服务，未关闭个人客户端或改变其登录配置。

本页汇总 2026-10-09 至 2026-10-10 的 Windows 本机交付记录。记录来自当时的 Windows 11 x64 / .NET 10.0.401 环境；不能当作本次在 macOS 上重做的 Windows 验证，也不代表已发布 GitHub Release。

## 已验证的范围

- Windows 回归程序及 Release 自包含构建、便携打包通过；覆盖配置保护、只读会话、文件缓存失效、排序持久化、共享文案／样本和接力事务。
- 实际面板显示默认客户端账号、Codex 任务及两类客户端实时额度；浅色、深色、Pox 三主题及账号／设置／信息／新建页已做渲染检查。
- 进程轮询不持续创建 PowerShell；一次五分钟采样未发现轮询子进程。桌宠、面板移动、设置切换与部分菜单路径已实测。
- 隔离测试账号实际创建并启动；测试 Markdown 实际复制并生成记录。剪贴板被锁时保留待办、不生成重复副本，界面显示失败提示。
- 会话右键菜单、六条以上接力记录折叠展开、信息折叠及滚动已检查；增量刷新保留列表对象与悬停状态。
- 仅对测试客户端执行过进程关闭／回收，未退出个人客户端或修改其登录配置。

## 仍需实机验收

- 两个个人账号同时登录隔离；第三方模式与个人模式共存不等于两个个人账号验证。
- 普通非提升权限、Windows 10 回退、混合 DPI 多屏与热插拔。
- 实际托盘连续切换、全部拖动路径、目录选择／删除确认与完整 Tab／回车路径。
- Codex 单实例真实对话跳转；多实例和 Claude 只调出账号窗口。
- 真实后台任务完成通知、媒体自动姿态与完整同步周期。未上报系统媒体会话的应用无法检测。

## 2026-10-21 删除接力和拆出需求（未在 Windows 运行）

会话右键菜单的“接力到…”“拆出需求到…”、待接力卡片、设置页的交接文件夹和接力记录、交接文档写好的托盘通知都已删除，对应的 Core 代码和回归测试一并去掉。对话状态通知保留。在 macOS 上用 `dotnet build windows/Perch.sln -c Release -p:EnableWindowsTargeting=true` 编译通过，0 警告 0 错误；回归程序没有在 Windows 上跑。需要在 Windows 上确认：

- 会话右键菜单只剩打开、复制会话文件路径、在资源管理器中显示；账号页顶部没有待接力卡片；设置页没有“文档接力”一节；信息页没有“文档接力”和交接目录。
- 跑一个 Codex 任务，结束时照常收到托盘通知。
- 旧版留下的 `%LOCALAPPDATA%\Perch\handoffs` 目录还在，内容没有被改动。

## 2026-10-20 通知与接力提醒（未在 Windows 运行）

在 macOS 上编译通过，0 警告 0 错误。`NoticeTests.cs` 是纯逻辑测试，在 Mac 上用临时工程单独跑过，Windows CI 推送后才会随回归程序一起跑。下面每项都需要在 Windows 上确认：

- 跑一个 Codex 任务和一个 Claude 对话，结束时各收到一条托盘通知，点通知调出所属客户端；设置里关掉后不再收到；启动时已经结束的对话不补发。

接力目标额度和交接文档写好提醒两项随接力在 2026-10-21 删除，不再验收。

## 2026-10-19 缺陷修复（界面未在 Windows 运行）

这一轮只修缺陷，在 macOS 上用 `dotnet build windows/Perch.sln -c Release -p:EnableWindowsTargeting=true` 编译通过。回归程序新增 `RegressionTests.cs`，依赖 Windows ACL 和 winsqlite3，2026-10-20 推送后在 Windows CI 运行通过。下面每项界面行为仍需在 Windows 上确认：

- 不带 `--show` 启动、不打开面板，桌宠能反映任务状态。
- 打开面板后点外部，面板收起，包括刚打开、正在后台刷新额度时。
- 面板贴着桌宠时，轮询不再改写 `accounts.json` 和 `preferences.json`（看修改时间）。
- 同一条损坏文件的恢复提示只弹一次；启动时就有的恢复提示能在托盘气泡或面板里看到。
- 运行超过 30 分钟没有更新的 Codex 会话显示为已停止。
- 最大化的客户端窗口调出后仍是最大化；客户端收到托盘后能调出。
- 客户端运行时勾选回收数据目录，被拒绝且账号未移除。
- 轮询和首次发现客户端时界面不卡顿。
- 有 Sonnet 周额度的 Claude 账号，额度行标签不换行；演示截图与改动前一致。

其中“继续接力”重试和 MSIX 客户端写入交接文档两项随接力在 2026-10-21 删除，不再验收。

## 当前限制与复验入口

### 2026-11-13：鲸鱼娘专属互动文案

- 八种姿势与任务数量、未知媒体、搬家、双击、完成气泡按 `deepseek-whale` 独立选择台词，包含白饭／鱼片／呆毛／鲸尾梗；[完整对照与参考](../../shared/strings/deepseek-whale-copy.md)。Pox 原文案和浮球无台词行为保留。
- `windows/script/build.ps1 -Action Test` 通过。WPF 实际窗口回归覆盖八种预览台词、135px 最小尺寸宽度、真实状态接口的任务计数和完成标题、切回 Pox 的台词恢复、浮球不显示、安静模式与切换清除反馈。任务数据使用隔离 fixture，不代表真实任务完成事件实测。
- `-Action Package -OutputDirectory dist.noindex/windows/Perch-whale-copy` 发布与打包通过。默认发布目录被运行中的 Perch 占用，未关闭该进程；新成品位于 `dist.noindex/windows/Perch-whale-copy/Perch.exe`。
- 隔离 `--demo` 截图位于 `scratch/whale-copy/{whale-lifted,whale-complete,pox-complete}/dark-pet.png`。逐张查看确认 135px 下提起文案、完成气泡、特殊符号完整显示；Pox 仍使用“搞定一个。”与“动作预览”。演示不读取个人客户端，未更改登录配置。macOS 同步代码与回归用例，构建和实机仍待 Mac 验收。

### 2026-11-13：DeepSeek 鲸鱼娘

- 设置 → 开启桌宠 → 角色可选“原生浮球 / Pox / DeepSeek 鲸鱼娘”。鲸鱼娘提供与 Pox 相同的大小、安静模式、媒体感知和八种动作预览；当前 Windows 实现启用鲸鱼娘使用 DeepSeek 暗色主题，启用 Pox 使用 Pox 主题，原生浮球或关闭桌宠跟随系统明暗。隐藏桌宠保留角色主题。macOS 鲸鱼娘跟随系统，其新增代码仍待 Mac 验证。
- .NET 10.0.400 下 Test、Publish、Package 均通过。新增 WPF 窗口回归检查真实图集裁剪、两种角色切换、预览到期恢复任务姿势、隐藏后偏好持久化、关闭停止活动、三种尺寸、安静模式和主题恢复；原有 Core 回归通过。
- 演示截图生成于 `dist.noindex/windows/whale-preview/`：浅色下全部八姿势 × 135/190/265 像素，深色下八姿势，完成气泡，以及原生浮球/Pox 回归。已检查三种尺寸全部姿势，角色主体、鳍耳和鲸尾完整，背景透明；浅色/深色设置页与 Pox 主题、完成气泡截图检查通过。
- 桌面工具可读取实际演示窗口的无障碍树；窗口截图捕获超时，坐标输入返回 `coordinate input geometry is unavailable`，因此鼠标拖动、通过真实下拉菜单切换、隐藏恢复和实际媒体播放仍待人工复验。上述 WPF 测试及离屏截图不替代这些项目。验收过程仅运行隔离演示数据，未修改个人客户端登录配置。
- 演示参数新增 `--pet-character native|pox|deepseek-whale`，独立于 `--theme light|dark|pox|deepseek`；未指定时保留原有默认映射。显式指定主题会覆盖角色的默认主题，因此下方 `--theme dark` 示例不代表正常产品的鲸鱼娘配色。`--pet-size 135|190|265` 可用于复验尺寸，`--pet-pose 0..7` 对应图集顺序，`--pet-complete` 展示完成气泡。这些参数仅用于 `--demo`。

```powershell
dist.noindex/windows/Perch/Perch.exe --demo --theme dark --pet-character deepseek-whale --pet-pose 5 --page settings --screenshot dist.noindex/windows/whale-preview/example
```

正常产品入口仍为 `dist.noindex/windows/Perch/Perch.exe`，验收截图不读取真实客户端。

尚无签名、安装器、自动升级或开机自启动；传统非 MSIX 客户端、Claude CLI projects 和 IndexedDB blob 额度回退不在当前 Windows 可用能力内。API Key 账号没有官方订阅额度数据不代表网关无限额度。

构建和运行见 [架构说明](architecture.md)，发布见 [发布说明](releasing.md)。`--demo --theme light|dark|pox|deepseek --page accounts|settings|info|add --screenshot <目录>` 使用演示数据生成截图；`--inspect` 仅提供任务栏入口，`--keep-open` 会改变失焦行为，因此两者都不能替代正常启动验收。
