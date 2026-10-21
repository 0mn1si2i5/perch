# macOS 供应商管理

在面板底部选择“新建账号”。点击“自动获取可用供应商”主动扫描，可搜索名称并逐项添加。主页不显示发现条幅，扫描不会自动添加账号：

- Codex、Claude：保留原有独立账号、登录和额度流程。
- Gemini CLI、Antigravity CLI、DeepSeek Harness、Gemini 应用：扫描并引用本机已有配置。添加不会复制凭据，也不会改变原客户端登录。启动后在客户端完成认证。

新建页的手动添加只提供 Codex 和 Claude；其他客户端只能通过扫描添加。

已添加的本机客户端换了位置（例如 agy 装到了别的目录，DSH Desktop.app 移动过）后，再扫描一次：数据目录相同、启动位置不同的账号会显示“更新启动位置”，点了只改启动位置，名称、顺序和数据目录不变。数据目录本身不在了，就删除账号后重新扫描添加。

## 已删除的类型

之前开发版里的 API 供应商和自定义客户端（包括网页入口）已删除。升级后第一次启动时，这些账号从 `accounts.json` 移到 Perch 数据目录的 `removed-accounts.json`（权限 0600），内容原样保留，账号列表不再显示。重复启动不会重复写入。

Perch 不删除钥匙串里保存过的 API 密钥。需要清理时打开“钥匙串访问”，搜索 `com.omnis.perch.api-provider`，删除对应条目。信息页在有备份文件时也会显示这段说明。

## 本机适配

| 客户端 | 查找 | 数据 | 启动与限制 |
|---|---|---|---|
| Gemini CLI | `gemini`，含用户 npm、local、bun 和 Homebrew 路径 | `~/.gemini` | `GEMINI_CLI_HOME` 指向 `.gemini` 的父目录；读取 `tmp/*/chats/session-*.json` 和 `.jsonl` 的元数据 |
| Antigravity CLI | `agy` | `~/.gemini/antigravity-cli` | 沿用本机登录，不提供未经验证的 home 隔离；只读 `conversation_summaries.db`，数据库是 WAL 模式且没有 `-wal` 文件时按不可变文件打开 |
| DeepSeek Harness | 优先已安装的 `DSH Desktop.app`，否则 `dsh` | `~/.dsh` | DSH Desktop 直接打开既有本机应用，读取其数据目录设置中的 `activeHome`（没有设置时为 `~/.dsh`）；CLI 使用 `DSH_HOME` 和 `--profile web --host 127.0.0.1 --port 3080`，再点击“打开本机网页” |
| Gemini macOS | 验证 `Gemini.app` 的 bundle ID | 原生应用数据目录 | 作为独立 Gemini 分组添加；打开应用内 Antigravity 后，通过其本机服务查询额度，不解密账户存储 |

DSH Desktop 是本机第三方桌面封装；Perch 不安装或升级它。本次本机旧 npm CLI 与现有凭据格式不兼容，已通过其兼容的桌面版接入，没有修改凭据。

终端客户端通过 Terminal 打开私有 `.command` 文件，登录信息仍由客户端读取。绿色运行标记只确认由 Perch 启动且仍存在的终端进程；点击“终端”调出 Terminal，不保证选中具体标签页。会话行调出客户端，暂不自动定位新供应商会话。

会话列表每次只看最新的 60 个会话文件，按路径、修改时间和大小缓存，文件没变就不再解析。超过 2 MB 的会话只读文件开头的元数据，仍然出现在列表里。没有有效时间的会话（例如 Antigravity 记录的 0001-01-01）显示“时间未知”，排在最后。

新增供应商不冒用 Codex/Claude 额度查询。没有可靠状态的本地会话标为“本地记录”，不声称已完成。Antigravity 额度以 Gemini 应用为准。Antigravity CLI 卡片不自动查询，点击刷新时运行一次官方 `/usage` 只读命令，显示周额度、5 小时额度和重置时间；agy 不会在后台启动。DeepSeek 显示充值与赠送余额，不伪造百分比。Gemini CLI 不再查询额度：之前的查询要从 CLI 安装目录的 JS 里读取 OAuth client，个人账号也只会返回迁移提示。原生 Gemini 登录独立保存；Perch 从已运行的原生应用内 Antigravity 本地服务查询 Gemini 模型额度，不复用 CLI 凭据。应用未启动或 Antigravity 尚未打开时，显示打开应用的提示。Windows 尚未实现这些新增类型；两端账号文件是各自本地存储，不要把 macOS 新账号文件直接复制到旧 Windows 版本。

## 本机验证入口

```sh
swift test --package-path macos
macos/script/build_and_run.sh --build
macos/dist.noindex/Perch.app/Contents/MacOS/Perch --diagnose-providers
```

`--diagnose-providers` 只输出配置是否可用、会话数量和终端进程状态，不输出会话标题、正文或密钥。

`--import-local-providers` 是明确的写入操作：引用扫描到的本机账户，保留已有账号，并在 Perch 应用支持目录生成权限为 0600 的 `accounts-before-providers-*.json` 备份。重复运行不会重复添加。升级前先退出旧版 Perch，避免旧版读取新账号类型；回退旧版时同时恢复旧账号备份。

## 协议依据

- [Gemini CLI 认证](https://geminicli.com/docs/get-started/authentication/)
- [Antigravity CLI](https://www.antigravity.google/docs/cli/install/)
- [DeepSeek Harness CLI](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/README.md)（本机版本可能早于当前文档，启动参数按已安装实现验证）
- [DeepSeek API](https://api-docs.deepseek.com/)

## 首轮供应商管理验证（2026-10-18）

- `swift test --package-path macos`：Core 114 项通过；App 18 项中 17 项通过、1 项可选预览导出跳过。预览导出另行启用运行通过，已检查 340 pt 内容布局。
- `macos/script/build_and_run.sh --build`：构建与应用签名检查通过；工具链提示 x86_64 对当前宿主部署目标已弃用，未进行 Intel 真机验收。
- 使用生产 API 连接代码实际获取 OpenRouter 公开模型列表；未使用真实 API Key，未发起推理。
- Keychain 创建、读取、更新、删除用一次性测试条目验证通过，测试条目已删除。
- 本机新版应用启动；原有 4 个账号字段保持不变，新增 4 个本机入口。原应用和账号文件已备份至 Perch 本机应用支持目录。
- 实际打开 DSH Desktop 原生窗口，并从既有索引读取会话；没有更改登录配置。旧 npm CLI 的凭据格式不兼容是本机环境问题，入口改用已有兼容桌面版。
- 通过 macOS 辅助功能实际点击菜单栏、“新建账号”和“API 供应商”，确认配置字段存在。未自动登录任何供应商、发送消息或验收模型推理。Windows 未构建或修改。

## 额度与主动扫描更新（2026-10-18）

- 主页移除发现条幅；新建页主动扫描，包含旧客户端默认账号和新增本机入口。扫描不修改账号清单。
- Gemini、DeepSeek 分组使用本机安装应用的图标；Antigravity 使用官网识别图标，归属见 `NOTICE`。无安装图标时保留系统符号。
- 本机 DeepSeek 平台授权与余额接口实际返回成功；单次 Anthropic 兼容最小请求成功，无工具或仓库内容。
- 本机 agy 只读 `/usage` 返回模型分组及两类时间窗口；独立临时目录内单次最小调用成功，未发生工具调用。请求的自定义 agent 空工具列表未被客户端严格采纳，不将其描述为工具已禁用。
- 本机 Gemini CLI OAuth 刷新与健康检查成功，额度和最小推理均返回 `403 / SUBSCRIPTION_REQUIRED`。这属于个人账号服务迁移，不是登录失效或零额度。
- 原生 Gemini 应用的内嵌 Antigravity 页面显示已登录及 Pro 方案；在项目外的一条最小测试请求成功。原生应用和 CLI 数值不同，未据此假定两者使用同一账号。
- [官方 Gemini CLI 个人服务迁移公告](https://github.com/google-gemini/gemini-cli/discussions/28017)、[Antigravity 额度规则](https://www.antigravity.google/docs/plans)、[Gemini Apps 使用限制](https://support.google.com/gemini/answer/16275805)。普通 Gemini 对话、内嵌 Antigravity 与 API 计费模式需区分；同一订阅不代表所有产品共享同一额度。

集成验收：Core 129 项、App 18 项测试无失败（首次跳过的可选预览随后启用并通过）；完整应用构建与签名检查通过。生产 Swift 适配器对本机 Antigravity 和 DeepSeek 均返回 4 项指标，Gemini CLI 返回迁移提示。新版已安装到 `~/Applications/Perch.app`，安装后确认二进制与构建结果相同，6 个既有账号的存储字节不变。更新前应用与账号备份保留在本机 Perch `Backups/provider-usage-*` 目录。

已检查 340 pt SwiftUI 预览中的额度行、重置时间、迁移提示和新建入口；此次计算机使用工具读取菜单栏 Perch 时持续超时，因此不将预览声称为新版实际菜单栏点击验收。Gemini 原生客户端的实际 UI 登录、额度页和最小调用已另行验证。Windows 未构建或修改。

## 原生 Gemini 内 Antigravity 接入（2026-10-18）

- 新增独立 Gemini 分组，扫描后逐项添加；旧 Gemini CLI 仍保留独立类型和迁移提示。
- 原生额度来自运行中的 Gemini 内嵌 helper 的本机 `RetrieveUserQuotaSummary` 服务。连接动态端口，CSRF 仅在内存中使用；不读取或解密原生登录存储，不自动启动客户端。
- 原生界面只显示 Gemini 模型组；Perch 同样显示该组的周额度、5 小时额度及重置时间，不将底层额外返回的模型组解释成原生界面的模型权限。
- 本机原生 `GetUserStatus` 返回的账号标识，与 agy CLI 当前登录记录中的标识在内存中比对一致；强制刷新后的同名额度桶数值也吻合。身份、token、完整响应均未写入仓库。
- 之前看到的原生与 CLI 模型组数量不同来自原生前端过滤；旧原生页面上的百分比不是同步刷新快照，不能据此判断账号或额度池不同。上述结论仅针对当前账号的 Antigravity 模式，不扩展到普通 Gemini 聊天额度。
- 从访达重新打开 Perch 现在会显示面板；此前工具激活一个没有常驻窗口的菜单栏应用会超时。已通过访达入口读取真实面板，点击新建、扫描、名称过滤和取消，确认扫描后既有 6 个账号文件字节不变。

实际面板补验：通过新版真实菜单栏面板完成新建、主动扫描、搜索、取消以及单独添加原生 Gemini；添加后立即显示两项真实额度，手动刷新将更新时间从 03:45 推进到 03:50。原有 6 条账号记录保持不变，只增加原生 Gemini 一条，未添加旧 Gemini CLI。

核实过程有一项测试副作用：一次 `agy -p /status` 被客户端当作模型对话处理，而非只读状态命令，留下 “System Status Check” 测试会话。记录有 4 次 `view_file`（均指向 agy 自身配置目录）与 1 次 `manage_task`，无 Perch 仓库路径；进程已停止、会话为空闲，未删除记录。后续查询仅使用已核实的 `/usage` 和本地额度 RPC。

额度卡片默认只显示简洁摘要：各模型组的周／5 小时剩余，以及按币种汇总的余额；重置时间、原始余额分项、数据来源与更新时间在“明细”中展开。查询失败仍直接显示；刷新失败时保留的历史数值会明确标记。

本机额度查询曾出现 CLI 与原生短暂返回不同百分比；随后对同一可执行文件和相同参数复查，各工作目录均恢复一致，未发现目录级账号覆盖，不能把一次差值解释为不同账号。账号一致结论来自标识比对；同一 Antigravity 额度由同步查询佐证。

最终本机验收（03:58）：Core 141 项测试通过，App 23 项中 22 项通过、1 项可选预览跳过；实际模型组名称和余额排版调整后 5 项展示测试再次通过。完整构建、嵌套签名校验通过；构建与安装二进制一致。已安装证书签名版本并重启，7 条账号保留、原有 6 条记录完整不变。真实面板已检查简洁摘要、Gemini/DeepSeek 明细展开与收起、Gemini 刷新时间推进、新建页主动扫描及取消；扫描排除已添加的 Gemini，只提供尚未添加的 Gemini CLI。

账号一致已核实，但最终面板中 CLI 的 5 小时读数仍有 95.9% 与原生 96.6% 的差异，不能将部分同步查询吻合提升为“所有时刻完全共用同一额度”的保证。Perch 保留各客户端真实返回值，没有强行合并或改写数字。Windows 未验收。

签名更新后，Claude 后台读取未弹授权框，界面显示需手动授权和缓存状态；尚未替用户完成新的钥匙串授权。用户可在 Claude 卡片手动刷新并在系统授权框选择始终允许（若提供）；后续开发构建保留同一签名。未保存系统密码、未修改钥匙串访问控制。

## Google 额度池复核与统一显示（2026-10-18）

这次结论是：当前同一 Google 个人账号的 Gemini Mac 内嵌 Antigravity 与 agy CLI 使用同一 Antigravity Google 模型额度池。它不代表普通 Gemini 聊天或 Gemini API 的额度。依据包括：

- [官方认证说明](https://antigravity.google/docs/ide/extensions)说明 App、CLI 和 IDE 扩展采用统一认证，登录决定模型权益和额度；[官方额度池说明](https://antigravity.google/blog/changes-to-antigravity-plans/)明确所有 Gemini 模型共用一个池，第三方模型另算。
- 两个已安装客户端使用同一 `RetrieveUserQuotaSummary` 后端方法；其后端请求字段是 `project`，没有客户端或工作目录维度。原生外层 RPC 的 `forceRefresh` 参数位置无误。此前已在内存中比对登录账号标识一致。
- 04:04 顺序采样“原生强制刷新 → CLI /usage → 原生强制刷新”：两端 Google 桶均为 `gemini-weekly`、`gemini-5h`，重置时间一致。周剩余原生 0.96794605 / CLI 0.9679460525512695，5 小时剩余原生 0.96604335 / CLI 0.9660433530807495，差别仅为 JSON 浮点精度。
- 随后用 Foundation Process 原样运行生产命令，以及复制当前 Finder 启动的 Perch 环境、移除工具环境的 Google 变量分别复查，均返回相同结果。环境变量或工作目录造成不同账号／池的假设未得到支持。04:08 实际 Perch 两张卡片也均显示剩余 96.8% / 96.6%。

此前 95.9% / 96.6% 的差值来自不同查询快照，并非 Perch 百分比计算错误或额外额度池。尚不能区分差值具体来自 CLI 内存缓存、原生缓存或服务端更新延迟。日志证明 `/usage` 请求 `force=true`；退出时取消额外后台刷新不能单独证明返回值陈旧。未修改或清空客户端缓存、未更改登录、未用模型调用消耗额度来制造验证事件。本轮只执行已核实的只读 `/usage` 与额度 RPC。

展示改为直接复用 Claude/Codex 的 `QuotaRowView`、`QuotaWindowView`、`QuotaFreshnessView`：按 5h／周分行、显示已用整数百分比、右侧重置倒计时，悬停显示剩余与完整日期；缓存／错误提示位于标题。Antigravity CLI 仅接受 `gemini-` 桶，第三方额度不显示。DeepSeek 使用相同字号和行对齐，但保留金额语义，精确分项置于悬停提示。两张 Google 卡片保留各自的真实查询结果，不相加、不强行覆盖为同一个数。

本轮交付验收（04:10）：Core 142 项通过，App 25 项中 24 项通过、1 项可选预览跳过；完整构建和签名校验通过。新版已安装至 `~/Applications/Perch.app` 并重启，安装二进制与构建一致，7 条账号文件与更新前备份字节一致。真实菜单栏已检查两张 Google 卡片的 5h／周已用 3%、一致的重置时间、第三方模型隐藏及 DeepSeek 余额排版；点击 Antigravity 刷新后按钮恢复可用，数值与原生 Gemini 保持一致。更新前应用与账号备份位于本机 `Backups/unified-quota-20261018-040843`。Windows 未构建或验收。

## Argon 周额度单独标注（2026-10-19）

本机 `/usage` 现在多返回一个“Gemini 4 Argon”分组，桶 id 为 `gemini-argon-wtu-weekly`，重置时间与主池周额度不同。它以 `gemini-` 开头，之前被当作主池的又一个周额度，卡片上出现两行“周”。官方说明 Pro 方案的 Argon 额度单独计算。

现在桶 id 含 `argon` 的额度标为 Argon 池，CLI 和原生 Gemini 两张卡片都显示为“Argon 周”，排在主池 5h、周之后。主池标签不变。

验收：macOS 测试 148 项通过；新版已构建、签名并安装到 `~/Applications/Perch.app`，安装二进制与构建一致。用当前 `/usage` 实际返回离屏渲染额度行，显示 5h 0%、周 4%、Argon 周 2%。没有在真实菜单栏面板中点击查看；原生 Gemini 按同一规则解析，未单独抓取其返回。Windows 未改动。

## 阶段 1 缺陷修复（2026-10-19）

一、删除的内容：API 供应商、自定义客户端、网页入口、供应商编辑页、Gemini CLI 额度查询和从 CLI 的 JS 读取 OAuth client 的代码。新建页去掉 4 个只提示去扫描的类型。

二、Antigravity 额度：只保留 Gemini 应用这一个自动来源。CLI 卡片默认不显示额度行，手动刷新后才显示结果。

三、会话列表：按路径、修改时间、大小缓存，只解析最新 60 个文件；长会话读开头元数据；0001-01-01 按无日期处理；WAL 数据库缺 `-wal` 时按不可变文件打开，之前这种情况每 5 秒报一次“unable to open database file”，列表为空。

四、验证：`swift test --package-path macos` 通过（Core 149 项，App 29 项中 1 项可选预览跳过），`macos/script/build_and_run.sh --build` 成功。用本机真实数据只读运行会话读取：Antigravity 列出 21 条（1 条无日期），Gemini CLI 的 `.jsonl` 会话 1 条，DSH 7 条，第二次读取没有重新解析文件，数据库旁没有生成 `-wal` 文件。没有安装新版，也没有在真实菜单栏面板上点击检查。

五、复审后补的修复（2026-10-20）：

- 接力重试比较副本目录时改用路径字符串。之前 handoffs 目录在启动时不存在，目录 URL 不带结尾斜杠，比较总是失败，重试又多存一份副本。
- 交接文档在上次复制之后被改写过，重试会重新复制，不再粘贴旧副本。
- 扫描结果里加入“更新启动位置”，见本页开头。启动位置失效时，启动失败提示写明怎么修。
- Antigravity 会话数据库打开或查询失败时不缓存，保留上次的列表，下次轮询重读。
- 子进程退出后最多再读 2 秒管道就返回，然后照常结束整个进程组。之前要等管道全部关闭，agy 留下的后台进程会让手动刷新等到 35 秒超时。

