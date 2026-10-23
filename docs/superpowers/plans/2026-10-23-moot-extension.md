# Perch Moot 扩展 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS Perch 中交付可安装、更新、卸载的 Moot 扩展，支持按能力自动委派、审核、订阅工具生图与可恢复的多模型圆桌，并展示真实过程和产物。

**Architecture:** Perch 原生 SwiftUI／AppKit 界面负责管理与查看；独立 Moot 执行程序负责配置、路由、后台进程和运行记录。技能让当前对话 agent 发起任务并担任主持人，Perch 不代替主持模型。共享版本化的 JSON 契约，界面不复制另一套路由逻辑。

**Tech Stack:** 现有 Swift Package（Swift tools 6.0、Swift language mode 5、macOS 14）、SwiftUI、AppKit、XCTest；Moot 延续 Node ESM 与 `node:test`，分发包自带受支持的 Node 运行时；API 凭据使用 macOS Keychain。

**Spec:** [2026-10-23-moot-extension-design.md](../specs/2026-10-23-moot-extension-design.md)。实施者先读设计，再读本计划。下列新增文件、接口和命令是实施安排，不表示它们已经存在。

**本轮边界：** 只更新设计和计划。所有复选框保持未完成；不执行模型探测、安装、迁移、构建或产品代码改动。用户后续明确要求开始后，才执行任务。公开发布不包含在自动执行范围内。

## Global Constraints

- 首版 macOS，Windows 后续跟进；保留现有 macOS 14 最低版本与 arm64／x86_64 分发架构约定，Intel 未实测需单列。
- 圆桌自动发起单独设置开关，默认关闭；用户明确要求圆桌时仍可发起。普通委派和审核在已配置范围内自动调用。
- 订阅调用优先；API 默认关闭，仅在用户事先开启并配置后作为备用。
- 用户明确指定模型时，遵从指定；不可用时说明原因，不擅自替换。
- 第一轮独立发言，后续轮次能看到其他参与者观点并回应分歧。每轮主持人归纳；达到轮数上限后收尾并保留未解决问题。
- 关闭 Perch 不影响已经启动的任务；主持对话停止后，会议可停在等待主持人，不能伪造后续总结。
- 正式界面使用 SwiftUI／AppKit，融入 Perch 的系统浅色／深色与 Pox 主题；不嵌入 HTML 原型，不另起品牌视觉。
- 主界面使用「交给谁」「怎么完成」；具体模型、工具和路径放进展开的详细配置。
- 按公开扩展设计，但先完成本机验证；不硬编码个人账号、个人绝对路径或开发机全局 Node。
- 保留 `com.pox.desktop` → `com.omnis.perch` 偏好迁移；不改变真实客户端登录，不自动开放未选定账号，不采集任意私人聊天正文。
- 本仓库是唯一产品集成位置；外部 Moot 仓库只作读取参考。复用前记录源版本及许可证依据，禁止把未经授权的代码直接作为 MIT 资产分发。
- Git 提交只描述改动，不加 AI 署名；已推送历史不改写，同一功能的本地分步提交在获准推送前整理成线性、简明提交。

## Review Focus

| 容易遗漏的实际条件 | 期望行为 | 负责验证的任务 |
| --- | --- | --- |
| Perch 从 Finder 启动，PATH 短且账号名／路径含空格或非 ASCII 字符；Claude 桌面账号不等于 Claude Code 登录 | 采用已验证的独立 CLI 绑定，参数数组传递，不错用默认账号 | 任务 1、3、5 |
| API 环境变量已存在，或配置中同时开启／关闭不同层级的许可 | 订阅优先与关闭开关在执行端生效；不意外产生 API 调用 | 任务 2、6 |
| 单个席位失败、重复提交主持人小结、恢复请求到达两次 | 保留部分结果；不重复轮次，不在缺席时宣称共识 | 任务 7 |
| 在运行时更新／卸载，或关闭 Perch、主持对话退出 | 任务版本固定、UI 退出不杀任务、等待主持人可恢复、卸载不损坏结果 | 任务 3、4、7 |
| 运行日志增长时用户正编辑表单、阅读长发言或使用 Pox 外观 | 无焦点／滚动丢失；主题一致；首击、键盘和缩放后可用 | 任务 5、8、9 |

这些检查各归属一个任务，避免另外建立重复的验收框架。fixture 用于故障与契约测试，真实客户端调用、原生 UI 和安装包分别验收。

## 代码位置与依赖

一个集成计划，按可验证的能力拆任务，不拆成彼此等待的多个项目。复用现有 Perch 的组织方式，不重构无关模块。

| 目录／文件 | 责任 |
| --- | --- |
| `extensions/moot/`（新增） | 可分发执行程序、技能、配置契约、适配器和 Node 测试；外部 Moot 的授权复用代码在此集成 |
| `extensions/moot/bin/moot.js`、`lib/rpc.js` | CLI 与机器接口；保留已有 delegate／audit 用户入口的兼容层 |
| `extensions/moot/lib/config.js`、`routing.js`、`protocol.js` | 唯一配置写入、候选选择与协议校验 |
| `extensions/moot/lib/runner.js`、`worker.js`、`runs.js`、`adapters/` | 独立任务进程、快照、事件、取消、供应商转换 |
| `extensions/moot/lib/meeting.js`、`meeting-prompts.js` | 圆桌阶段转换、每轮材料与主持人衔接 |
| `extensions/moot/skills/` | `moot-delegate`、`moot-review`、`moot-roundtable`；共享契约，按工作方式分入口 |
| `macos/Sources/PerchCore/Moot/`（新增） | Codable 契约、RPC 客户端、安装器、账号绑定映射、只读历史兼容 |
| `macos/Sources/Perch/App/MootModel.swift`（新增） | 原生界面的状态、加载和动作；调用 RPC，不自己重做调度 |
| `macos/Sources/Perch/App/MootWindowController.swift`（新增） | 单实例可调整大小的原生窗口、激活、首击与主题同步 |
| `macos/Sources/Perch/UI/Moot/`（新增） | 扩展设置行、能力、接入、圆桌预设、运行详情与分歧视图 |
| `macos/Sources/PerchMootCredentials/main.swift`（新增 target） | 无 GUI 的 Keychain 桥接，供独立执行程序使用；不依赖 Perch 正在运行 |
| `macos/Tests/PerchCoreTests/Moot*Tests.swift`、`macos/Tests/PerchTests/Moot*Tests.swift` | 配置／安装契约、账号映射、状态与原生窗口集成测试 |
| `macos/script/package-moot.sh`（新增） | 打包各架构扩展、运行时、技能与清单；不自动上传 |
| `docs/macos/moot.md`、`docs/macos/moot-acceptance.md`（新增） | 使用说明、实际验证结果与明确未验证项 |

现有接入点：`App/App.swift`、`UI/SettingsView.swift`、`UI/PerchPanel.swift`、`UI/PanelDisclosure.swift`、`UI/CompanionTheme.swift`、`UI/ReadableStatusColor.swift`、`UI/FirstMouseHostingController.swift`、`PerchCore/Accounts/Account.swift`、`PerchCore/Support/ToolPaths.swift`、`macos/Package.swift`。保持 `AccountStore` 的旧 API 账号迁移规则不变；扩展 API 接入不重新加入 `AppKind`。

## 共享契约：后续任务统一使用

### 路径与版本

建议新管理根目录为 `~/Library/Application Support/Perch/Extensions/Moot/`，实际由可注入的 `MootPaths(root:)` 提供。其下包含 `versions/<version>/`、`current`、`config.json`、`runs/`、`backups/` 与 `install-receipt.json`。旧 `~/.moot/` 和两个旧委派记录目录通过明确迁移／只读兼容接入，不搬动客户端自己的账号目录。

独立入口 `~/.local/bin/moot` 只在未冲突或明确接管后安装；技能内使用安装时生成的稳定入口路径，不依赖 PATH。每个 worker 在启动时解析并固定版本，不能执行到一半跟随 `current` 切换。

### JSON 类型（JS 对象，Swift 为同名 Codable 类型）

- `MootConfig`：`schemaVersion=1`、`revision`、`apiEnabled=false`、`automaticRoundtable=false`、`connections[]`、`capabilities[]`、`meetingPreset`。
- `MootConnection`：`id`、可选 `perchAccountID`、`adapter`、`authMode(subscription|api)`、`enabled`、`executable`、`accountRoot`、`defaultModel`、可选 `credentialRef`、`tools[]`、`verification`。API 与订阅分别存储；绝不存明文密钥。
- `MootCapability`：`id`、`enabled`、`description`、`primaryConnectionID`、可选 `modelOverride`、`completionMode`、`requiredTools[]`、`fallbackConnectionIDs[]`、`instructions`。`completionMode` 为 `delegate|audit|draft|image`；前端任务使用 delegate 并在说明中限定项目范围。
- `MootMeetingPreset`：`seats[]`（`seatID,connectionID,model,role,instructions`）、`maxRounds`、`allowEarlyFinish=false`。起始界面允许 2–6 席位、1–10 轮，这只是本版配置范围。
- `MootTaskRequest`：`requestID`、`mode(delegate|audit|roundtable)`、`trigger(userRequested|automatic)`、`capabilityID`、可选 `explicitConnectionID/explicitModel`、`briefPath`、`workdir`、`hostRef`、可选 `meetingOverride`。`hostRef` 是不含会话正文的发起关联 ID。
- `MootRoute`：`connectionID`、`model`、`authMode`、`completionMode`、`requiredTools`、`reason`。返回决定或有类型的错误，不通过空数组暗示成功。
- `MootRunSnapshot`：`format="perch-moot"`、`schemaVersion=1`、`revision`、`id`、`requestID`、`runtimeVersion`、`configSnapshot`、`hostRef`、`state`、`timestamps`、`route`、`rounds[]`、`artifacts[]`、`issues[]`。旧 Moot 格式独立解析，不混用其 `version` 字段。
- `MootHostSummary`：`round`、`inputRevision`、`commonGround[]`、`hostJudgment`、`issues[]`（稳定 `issueID`、立场与 `round/seatID/messageID` 引用、状态、依据、下一步）。
- `MootInstallReceipt`：`version`、`architecture`、`ownedFiles[]`、`skillLinks[]`、`backupRefs[]`；`MootInstallState=notInstalled|installed|updating|pendingUninstall|failed`。失败包含原因及仍可用版本，不能将它抹成未安装。

运行快照固定本次计划与已用配置，但不冻结未来调用许可。每次准备新的 API 备用调用前再次检查当前总开关、接入和能力许可；撤销许可后不再新增 API 请求。已经发出的请求据实保留状态，不能假称可以撤回已产生的费用。

### 机器入口

`moot rpc` 从 stdin 接收一份 `{protocolVersion:1, requestID, operation, payload}`，stdout 只返回 `{protocolVersion:1,requestID,ok,data?,error?}`；日志走 stderr，不包含凭据。开始任务返回 `runID` 和初始快照，不把 CLI 请求一直绑定到模型执行结束。

上述请求／响应在 Swift 中分别命名为 `MootRPCRequest`／`MootRPCResponse`。`error` 包含稳定 `code` 与用户可读 `message`；协议数据保留原始状态枚举，展示文案由界面层映射。

操作：`config.read`、`config.write`（带 `expectedRevision`）、`connection.check`、`delegate.start`、`audit.start`、`meeting.start`、`run.list`、`run.read`、`run.cancel`、`meeting.summary`、`meeting.advance`、`runtime.quiesce`。这些名字是本计划的新接口；既有 `moot delegate/audit` 命令包装成同一条执行路径，不维护第二套权限规则。

Swift 公共接口：`MootRPCClient.call(_ request: MootRPCRequest) async throws -> MootRPCResponse`；`MootPaths.init(root: URL)`；`MootInstaller.install(package: URL) async throws -> MootInstallReceipt`；`MootInstaller.uninstall(policy: MootUninstallPolicy) async throws -> MootInstallState`。`MootUninstallPolicy` 仅有 `afterRunsFinish` 与用户显式选择的 `cancelRuns`。

---

### Task 1: 在隔离目录验证实际接入和宿主主持路径

**Files:**
- Create: `docs/macos/moot-feasibility.md`
- Read: 现有 Moot 的 `lib/adapters/`、`lib/env.js`、`lib/sandbox.js`、`lib/commands/delegate.js`；Perch 的账号／本地供应商实现。
- Temporary only: `scratch/moot-feasibility/`，不纳入源码或提交真实正文。

**Interfaces:**
- Consumes: 设计中的账号、订阅和主持人约束。
- Produces: 每个接入的可执行路径发现规则、账号绑定依据、模型／工具检查方式、实际可用的异步启动与结果回读方法；记录命令形状而不提交个人路径或凭据。

- [ ] **Step 1:** 在隔离临时任务中，分别验证 Codex／Claude 作为发起端能发现技能、调用独立入口、回读一次简单结果并继续当前对话；记录桌面应用与 CLI 两种宿主实际覆盖范围，不以 CLI 通过冒充桌面通过。
- [ ] **Step 2:** 验证候选执行接入的账号归属；特别检查 Claude 桌面 profile 与 Claude Code CLI 的区别、Gemini CLI 与 Antigravity 的区别。无法可靠映射时要求明确选择独立 CLI 绑定，不能默认为当前登录。
- [ ] **Step 3:** 用一个不含私人资料的小型生图任务验证 `agy` 订阅内置工具、图片文件回收与失败结果；API 开关保持关闭。不能以官方产品存在工具代替无头调用实测。
- [ ] **Step 4:** 验证最小脱离调用端的进程能在调用端退出后保存最终记录；在后续产品实现中复用该机制，不使用退出时会转发 SIGHUP 杀 worker 的旧调用结构。
- [ ] **Step 5:** 在 `moot-feasibility.md` 写明每条路径的 `PASS/FAIL/NOT_RUN`、适配决策和限制。核对外部 Moot 代码来源与可复用授权；授权不明时仅参考行为重新实现，不直接复制未授权源文件。

**验收：** 获得可实施的真实通路或具体不可用原因。某一工具不可用不阻断其他任务，但对应能力保持未验证，不把整项功能宣称完成。除这里的必要探测外，不做全供应商功能扩张。

### Task 2: 实现共享配置与执行端路由

**Files:**
- Create: `extensions/moot/package.json`、`bin/moot.js`、`lib/protocol.js`、`lib/config.js`、`lib/routing.js`、`lib/rpc.js`
- Create: `extensions/moot/test/config.test.js`、`routing.test.js`、`protocol.test.js`
- Create: `macos/Sources/PerchCore/Moot/MootContracts.swift`、`MootPaths.swift`
- Test: `macos/Tests/PerchCoreTests/MootContractTests.swift`

**Interfaces:**
- Produces: `loadConfig(root) -> MootConfig`、`saveConfig(root, config, expectedRevision) -> MootConfig`、`resolveRoute(config, task, availability) -> MootRoute`、`handleRequest(request, context) -> Promise<RPCResponse>`。
- Produces: 共享契约中的 Swift Codable 类型；`config.read/write` 操作可用。

- [ ] **Step 1:** 增加会失败的 Node 用例：`explicit model never falls back`、`disabled API ignores ambient keys`、`automatic roundtable requires opt in`、`user requested roundtable works with opt in off`、`unconfigured capability uses general`、`stale config revision does not overwrite`、`revoked API permission prevents new fallback`。断言分别为指定不可用报错、API 候选不选中、自动拒绝、显式允许、通用路由、冲突返回且原文件不变、旧快照不能绕过新关闭开关。
- [ ] **Step 2:** 运行 `node --test extensions/moot/test/config.test.js extensions/moot/test/routing.test.js extensions/moot/test/protocol.test.js`，确认失败对应缺少实现，然后实现上述接口和原子配置写入。所有订阅入口过滤可能改变计费通路的环境变量，API 候选只有许可成立才解析凭据。
- [ ] **Step 3:** 使用同一份非敏感 JSON fixture 验证 Swift 解码、默认两个开关均为 false、未知协议版本报不兼容、无效引用不保存。运行 `swift test --package-path macos --filter MootContractTests`。
- [ ] **Step 4:** 重跑本任务 Node 用例，要求全部通过；确认原始账号文件和偏好迁移未被修改。提交本任务的配置与契约实现。

### Task 3: 交付独立委派／审核执行与技能回读

**Files:**
- Create: `extensions/moot/lib/runner.js`、`worker.js`、`runs.js`、`adapters/codex.js`、`adapters/claude.js`、`adapters/agy.js`
- Create: `extensions/moot/skills/moot-delegate/SKILL.md`、`skills/moot-review/SKILL.md`
- Test: `extensions/moot/test/runner.test.js`、`adapters.test.js`、`host-flow.test.js`
- Create: `macos/Sources/PerchCore/Moot/MootRPCClient.swift`
- Test: `macos/Tests/PerchCoreTests/MootRPCClientTests.swift`

**Interfaces:**
- Consumes: Task 2 route／config／RPC。
- Produces: `startRun(root, task, route) -> Promise<MootRunSnapshot>`、`readRun(root,id) -> MootRunSnapshot`、`listRuns(root,query) -> MootRunSnapshot[]`、`cancelRun(root,id) -> Promise<MootRunSnapshot>`。
- Adapter contract: `buildInvocation(route, context) -> {executable,args,env,cwd}`、`parseEvent(raw) -> events[]`；上下文包含已授权工作目录、输出目录、权限模式及可选恢复 ID。
- Produces: `delegate.start`、`audit.start`、`run.list/read/cancel` 与 Swift RPC 客户端。

- [ ] **Step 1:** 写失败测试 `parent exit leaves worker alive`、`same request ID starts once`、`cancellation retains partial output`、`failed worker never becomes completed`、`paths with spaces stay single arguments`。用可控假 CLI 模拟长任务、错误与部分输出，不调用真实服务完成故障测试。
- [ ] **Step 2:** 运行 `node --test extensions/moot/test/runner.test.js extensions/moot/test/adapters.test.js` 确认失败，按 Task 1 的真实机制实现独立 worker、版本固定、请求幂等与事件存储。默认工作模式沿用已验证的项目范围隔离；不要引入无界权限。
- [ ] **Step 3:** 实现 Swift RPC 调用，显式使用扩展自己的程序路径和 stdin JSON，避免 shell 字符串拼接。测试结构化错误、超时和非 JSON stdout；短 RPC 超时不结束已派发 worker。运行 `swift test --package-path macos --filter MootRPCClientTests`。
- [ ] **Step 4:** 写两份供应商无关技能：自行读配置、只传必要背景、开始后回读结果、继续主持交付；审核不提前发送主持人结论；用户的提交规则优先，禁止携入旧技能固定 `--no-ff` 要求。
- [ ] **Step 5:** 运行 `node --test extensions/moot/test/host-flow.test.js`，断言 brief→start→status→results 的完整回读；再从 Task 1 确认的两个宿主各完成一次真实低风险委派／审核。记录真实执行者与结果，提交本任务。

### Task 4: 安装、更新、独立运行时与卸载

**Files:**
- Create: `macos/Sources/PerchCore/Moot/MootInstaller.swift`、`MootInstallReceipt.swift`
- Create: `macos/script/package-moot.sh`、`extensions/moot/release/manifest.schema.json`
- Create: `extensions/moot/lib/install-state.js`
- Test: `macos/Tests/PerchCoreTests/MootInstallerTests.swift`、`extensions/moot/test/install-state.test.js`

**Interfaces:**
- Consumes: Task 3 worker 版本记录、run 状态。
- Produces: 共享契约中的 `MootInstaller`；包清单包含 `version,protocolVersion,platform,architecture,minOS,sha256,files`，receipt 记录本扩展拥有的入口和迁移前备份。
- Produces: `runtime.quiesce`，拒绝新任务并返回仍活动的运行 ID；等待卸载时 worker 退出后可完成剩余清理，不能依赖 Perch 窗口一直存在。

`quiesce` 只拒绝创建新运行，不禁止已有会议的主持人归纳、续轮和取消。等待主持人的会议仍计为未完成任务；界面明确显示等待原因，不能因当前没有模型子进程就提前删除执行程序。

- [ ] **Step 1:** 写失败用例：`invalid package leaves previous version active`、`update pins active worker version`、`uninstall preserves config runs artifacts and foreign skills`、`pending uninstall completes after worker exit with UI closed`。用临时根目录和最小测试包。
- [ ] **Step 2:** 实现隔离 staging→校验→切换、receipt 与 owned-only 移除；兼容性不符时保留旧版。下载源在执行阶段从官方项目发布元数据生成，不把本机预览地址写入产品。
- [ ] **Step 3:** 打包受维护的 Node 运行时和必要许可证，版本在清单锁定；生成 arm64、x86_64 独立扩展包。`bash macos/script/package-moot.sh --local` 只生成本地文件，不上传。包内入口不能依赖开发机 Node。
- [ ] **Step 4:** 用测试下载端点走实际下载／安装代码；运行 `swift test --package-path macos --filter MootInstallerTests` 和 `node --test extensions/moot/test/install-state.test.js`，全部通过后，验证运行中更新和延后卸载。提交本任务。

### Task 5: 原生扩展窗口、能力与账号接入配置

**Files:**
- Create: `macos/Sources/Perch/App/MootModel.swift`、`MootWindowController.swift`
- Create: `macos/Sources/Perch/UI/Moot/MootExtensionSettings.swift`、`MootRootView.swift`、`MootCapabilityView.swift`、`MootConnectionView.swift`
- Create: `macos/Sources/PerchCore/Moot/MootAccountBinding.swift`
- Modify: `macos/Sources/Perch/App/App.swift`、`UI/SettingsView.swift`、`UI/PerchPanel.swift`
- Test: `macos/Tests/PerchCoreTests/MootAccountBindingTests.swift`、`macos/Tests/PerchTests/MootConfigurationTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4。
- Produces: `@MainActor MootModel`：发布 `config,installation,connections,runs,error`；`reload() async`、`saveConfig(_ config: MootConfig) async`、`install(package: URL) async`。
- Produces: `MootWindowController.show(section: MootSection)`，`MootSection=capabilities|connections|meeting|runs`；`MootAccountBinding.candidates(accounts:[Account]) -> [MootBindingCandidate]`，候选带独立 CLI 验证状态。

- [ ] **Step 1:** 写失败集成测试：未安装只显示安装入口；已有外部技能冲突不覆盖；选定账号才进入配置；Claude 桌面 profile 不能自动冒充 CLI 绑定；RPC 保存失败保留输入；窗口多次打开聚焦同一实例。运行 `swift test --package-path macos --filter Moot` 确认新用例失败。
- [ ] **Step 2:** 在现有设置中加入「扩展 → Moot」入口，安装后显示打开／版本／更新／卸载。保持主面板 340 × 570pt，不把扩展窗口模拟成放大的菜单栏 popover。正文窗口采用 `NSWindowController` + SwiftUI，不引入 WebView。
- [ ] **Step 3:** 实现能力列表、交给谁、怎么完成、补充要求、详细配置及候选备用；新增自定义能力走同一数据类型。接入页引用 Perch 账号并执行 Task 1 的验证规则，不恢复已删除的主账号 API 类型。
- [ ] **Step 4:** 复用 `PanelDisclosure`、`CompanionTheme`、系统符号和状态色处理。初始扩展窗口建议 900 × 650pt、可调整大小，最低 700 × 500pt；这只是布局起点。系统外观使用窗口适配材质，Pox 沿用现有深色／金色。详细发言字号与文本选择服务阅读，不照搬网页的白底蓝色卡片。
- [ ] **Step 5:** 验证浅色／深色／Pox 同步、首次点击、Tab、Esc、窗口关闭和表单焦点。运行 `swift test --package-path macos --filter MootConfigurationTests` 与 `macos/script/build_and_run.sh --build`；进行一次真实配置→技能委派→返回结果路径，提交本任务。

### Task 6: 订阅生图及显式开启的 API 备用

**Files:**
- Create: `extensions/moot/lib/image-task.js`、`adapters/google-image-api.js`
- Modify: `extensions/moot/lib/adapters/agy.js`、`lib/routing.js`、`lib/rpc.js`、`skills/moot-delegate/SKILL.md`
- Create: `macos/Sources/PerchMootCredentials/main.swift`、`macos/Sources/PerchCore/Moot/MootCredentialStore.swift`
- Modify: `macos/Package.swift`、`macos/script/package-moot.sh`、`macos/Sources/Perch/UI/Moot/MootConnectionView.swift`
- Test: `extensions/moot/test/image-task.test.js`、`google-image-api.test.js`；`macos/Tests/PerchCoreTests/MootCredentialTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5 的实际工具形状和 API 路由许可。
- Produces: `validateImageArtifacts(paths, allowedOutputRoot) -> Artifact[]`；`generateImage(route, request, outputRoot) -> Promise<Artifact[]>`。
- Produces: `MootCredentialStore.put(ref:String,secret:Data)`、`read(ref:String)->Data`、`remove(ref:String)`，Keychain service 为 `com.omnis.perch.moot`。独立桥接程序通过私有进程管道交付凭据，不写临时明文文件、命令行参数或事件日志。

- [ ] **Step 1:** 写失败用例：返回提示词没有文件不是成功；工具失败且 API 关闭时 HTTP 调用次数为 0；API 打开但未配置候选也不调用；图像文件不可读报部分失败；凭据不出现在记录或错误中。运行 `node --test extensions/moot/test/image-task.test.js extensions/moot/test/google-image-api.test.js`。
- [ ] **Step 2:** 根据 Task 1 证据让 Gemini 收到必需工具要求并回收真实图片；工具不可用明确显示未验证／不可用，不编造 Nano Banana 的 CLI 参数。保留工具模型与对话模型的区别。
- [ ] **Step 3:** 实现首个 Google 图像 API 备用适配器和 Keychain 桥接；调用细节在实施时核对官方文档，不将订阅 OAuth 直接用于 API。扩展执行程序退出 UI 后仍可使用已授权凭据；权限不足返回明确状态，不后台循环弹授权。
- [ ] **Step 4:** 运行上述 Node 用例及 `swift test --package-path macos --filter MootCredentialTests`。用隔离凭据引用测试存取；不改用户原有凭据 ACL 或登录。
- [ ] **Step 5:** 在关闭 API 的配置下完成真实订阅生图并在原生窗口打开图片。真实 API 调用只在用户确实开启并提供该接入后验证；否则记录 `NOT_RUN`，不能宣称 API 实测通过。提交本任务。

### Task 7: 圆桌引擎、自动开关与原生预设

**Files:**
- Create: `extensions/moot/lib/meeting.js`、`meeting-prompts.js`、`skills/moot-roundtable/SKILL.md`
- Modify: `extensions/moot/lib/rpc.js`、`runs.js`
- Create: `macos/Sources/Perch/UI/Moot/MootMeetingPresetView.swift`
- Modify: `macos/Sources/Perch/App/MootModel.swift`、`UI/Moot/MootRootView.swift`
- Test: `extensions/moot/test/meeting.test.js`、`meeting-host.test.js`；`macos/Tests/PerchTests/MootMeetingPresetTests.swift`

**Interfaces:**
- Consumes: 配置、独立 worker、事件与宿主回读。
- Produces: `startMeeting(root,task) -> Promise<MootRunSnapshot>`、`submitHostSummary(root,runID,summary:MootHostSummary) -> MootRunSnapshot`、`advanceMeeting(root,runID,expectedRound) -> Promise<MootRunSnapshot>`。
- 状态：`runningRound -> awaitingHost -> readyForNextRound -> runningRound|ended`；失败席位保留在轮次中。`meeting.summary` 接受主持人结果；`meeting.advance` 仅在当前轮归纳已写入后可推进。

- [ ] **Step 1:** 写失败用例：首轮各席位输入无同轮他人发言；第二轮都收到相同的上一轮材料；同模型不同席位仍分开记录；未提交小结不能推进；第 3 轮上限后不能生成第 4 轮；结束后 open issues 不自动清空。
- [ ] **Step 2:** 增加故障用例：`duplicate advance does not rerun a round`、`retry does not replay completed seats`、`host disappearance preserves awaitingHost`、`partial round never claims consensus`。运行 `node --test extensions/moot/test/meeting.test.js extensions/moot/test/meeting-host.test.js` 确认失败，再实现状态机和轮间材料。
- [ ] **Step 3:** 实现自动发起开关默认关闭；RPC 的 `trigger=automatic` 拒绝未开启请求，`userRequested` 允许明确召集。宿主技能准确传递来源；该字段不是不可伪造的安全证明，不能把它宣传成独立权限沙箱。
- [ ] **Step 4:** 实现席位增删、模型／账号、角色职责、轮数及提前结束配置。角色文本不改变执行权限。用 `MootMeetingPresetTests` 验证两个开关独立、保存失败不丢输入、非法席位／轮数阻止提交。
- [ ] **Step 5:** 用一个真实议题跑完 3 模型、3 轮会议，验证主持人回读与归纳、回应分歧、上限停止；中途关闭 Perch 后仍能继续，停止主持对话则保留等待状态。记录实际支持的宿主范围，提交本任务。

### Task 8: 原生运行展示、发言与分歧追溯

**Files:**
- Create: `macos/Sources/Perch/UI/Moot/MootRunListView.swift`、`MootRunDetailView.swift`、`MootRoundView.swift`、`MootSummaryView.swift`、`MootIssuesView.swift`
- Create: `macos/Sources/PerchCore/Moot/MootRunPresentation.swift`
- Modify: `macos/Sources/Perch/App/MootModel.swift`、`UI/Moot/MootRootView.swift`
- Test: `macos/Tests/PerchCoreTests/MootRunPresentationTests.swift`、`macos/Tests/PerchTests/MootRunNavigationTests.swift`

**Interfaces:**
- Consumes: `run.list/read` 与不可变运行快照。
- Produces: `MootRunPresentation.make(snapshot: MootRunSnapshot) -> MootRunPresentation`；`MootModel.showMessage(runID:String,round:Int,seatID:String,messageID:String)`。
- 更新：窗口可见时每 5 秒读取增量状态，隐藏时仅为运行摘要每 20 秒更新；无活动运行时不轮询执行服务。缓存未变文件／快照，不反复加载全部原始日志。

- [ ] **Step 1:** 写失败测试：结束与共识状态分离；未提供用量显示未知；配置修改不重写会议快照；分歧引用准确定位到某轮某席位；缺失原文明确显示缺失而不跳到别人的发言。
- [ ] **Step 2:** 实现运行列表、筛选、状态、选择原因及备用记录；圆桌提供逐轮发言、主持人总结、未解决分歧、产物。总结区分共同建议和主持人判断，不渲染未返回的内部思考。
- [ ] **Step 3:** 实现结果复制、Markdown 导出、图片预览与 Finder 产物定位；运行中只对本运行输出目录索引产物，不扫描私人聊天文件。导出使用用户选定位置。
- [ ] **Step 4:** 运行 `swift test --package-path macos --filter MootRun`。用持续增长的合成事件验证用户编辑状态和阅读滚动不跳；再用 Task 6／7 的真实记录核对原文、图片和分歧链接。
- [ ] **Step 5:** 同屏查看 Perch 账号面板与扩展窗口，检查浅色／深色／Pox、首击、键盘、文字选择及窗口缩小后的长文本；修正后提交本任务，不做与行为无关的快照测试堆积。

### Task 9: 旧技能迁移、完整安装包与本机交付记录

**Files:**
- Create: `macos/Sources/PerchCore/Moot/MootMigration.swift`、`MootLegacyRunReader.swift`
- Test: `macos/Tests/PerchCoreTests/MootMigrationTests.swift`、`MootLegacyRunReaderTests.swift`
- Modify: `macos/script/package-moot.sh`、`docs/macos/moot.md`、`docs/macos/moot-acceptance.md`、`shared/parity.md`、`README.md`、`NOTICE`（仅在确有新增分发依赖时）

**Interfaces:**
- Consumes: receipt、版本清单和新技能入口。
- Produces: `MootMigration.inspect(root:URL,skillRoots:[URL]) -> MootMigrationProposal`；`apply(_ proposal:MootMigrationProposal) throws -> MootMigrationReceipt`；`restore(_ receipt:MootMigrationReceipt) throws`。
- Produces: `MootLegacyRunReader.read(root:URL) -> [MootRunSnapshot]`，标记旧格式缺失字段，不伪造角色、轮次或验收状态。

- [ ] **Step 1:** 测试旧 `moot-delegate`、`codex-delegate`、`gemini-delegate` 存在、自建同名技能、迁移一半失败、恢复和卸载场景；断言无未选账号修改、无非自有文件删除、旧记录仍可读。
- [ ] **Step 2:** 实现发现与迁移预览，明确选择后安装统一家族并收起已接管旧入口；不把个人文风或仓库专属规则打进公共技能。保留可恢复 receipt。
- [ ] **Step 3:** 运行 `node --test extensions/moot/test/*.test.js`、`swift test --package-path macos`、`macos/script/build_and_run.sh --build`、`bash macos/script/package-moot.sh --local`。构建签名沿用项目现行规则，不清理个人客户端登录。
- [ ] **Step 4:** 从本地产生的包走安装 UI，选账号→配能力→真实委派／审核→生图→圆桌→查看产物；退出并重开 Perch，再验证更新和普通卸载。所有真实过程与失败路径写入本机验收记录，私人材料不提交。
- [ ] **Step 5:** 更新用户文档和 `shared/parity.md`：macOS 按证据标记，Windows 明确未实现；分别列出 API 未实测、Intel 未实测等真实缺口。提供公开可用包结构、校验值及第三方说明，但不创建公开 Release、不上传、不推送。
- [ ] **Step 6:** 检查最终 diff、版本、源码归属、包内个人路径与凭据泄漏；提交本地交付文档。需要公开发布时，另按用户授权执行发布流程，已推送历史不改写。

## 实施顺序与交付判断

顺序：1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9。生图与圆桌内部工作可拆，但配置／协议／原生 UI 的集成由一个负责人维护，避免共享模型接口漂移。

- 任务 1 结束：已知真实接入范围，不宣称产品可用。
- 任务 5 结束：安装和自动委派／审核的原生闭环可用，仍不宣称全功能完成。
- 任务 8 结束：图像与圆桌结果可在原生界面查看；任何未通过的真实通路继续明确列出。
- 任务 9 结束：完整本地扩展交付。公开发布是后续操作，Windows 是后续平台工作。

## 计划自检与当前状态

设计覆盖：生命周期→任务 4／9；路由与账号→任务 1／2／5；委派审核→任务 3；订阅工具与 API→任务 6；圆桌协议→任务 7；结果与分歧→任务 8；Perch 风格→任务 5／8；迁移与公开分发准备→任务 9。

接口自检：Node 与 Swift 共用协议／配置 fixture；只由 Moot 写用户配置；新记录与旧格式分别识别；主界面和执行端都不会凭模型名称推断工具／登录能力。Review Focus 的五项均已分配给具体用例与真实验证步骤。

当前只完成计划文档和自检，未执行上述任务，也未确定正式实施时采用单 agent 还是分任务委派。用户明确要求暂不写产品代码，后续实施指令到来前停在这里。
