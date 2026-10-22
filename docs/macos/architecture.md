# 架构

Perch 是独立的 macOS 菜单栏应用。Pox 是可选角色，不依赖 Pox 飞书服务或 agent-desk 进程。

## 目录

| 目录 | 职责 |
| --- | --- |
| `macos/Sources/Perch/App` | AppKit 应用生命周期、popover、账号状态协调、通知 |
| `macos/Sources/Perch/UI` | SwiftUI 面板、账号和会话、设置、信息、主题与状态颜色 |
| `macos/Sources/Perch/Companion` | 桌宠模型、窗口与拖动、姿态、可选媒体感知 |
| `macos/Sources/PerchCore/Accounts` | 账号配置、分组及默认客户端数据发现 |
| `macos/Sources/PerchCore/Launcher` | 客户端定位、进程归属、启动、运行目录和会话路由 |
| `macos/Sources/PerchCore/CodexTasks` / `ClaudeSessions` | 本地会话元数据与状态 |
| `macos/Sources/PerchCore/Quota` | 额度解析、缓存、实时查询与刷新状态 |
| `macos/Tests` | 核心行为与应用状态回归测试 |
| `shared/assets` / `macos/Vendor` | 应用图标、角色素材、固定版本的媒体适配器及其许可证 |
| `macos/script` | 开发构建、安装、通用架构发行包 |

Swift 约定目录使用大写，文档和脚本目录使用小写；第三方源码保持上游命名。构建产物和本机恢复快照位于被忽略的 `.build/` 与 `dist.noindex/`，不提交。

## 运行路径

AppDelegate 管理菜单栏、桌宠窗口和一个由 SwiftUI 承载的 popover。面板为固定 340 × 570pt，底栏始终存在；账号、信息、设置和新建账号在内部切换并滚动，页面状态保留。关闭行为由应用显式控制，避免首次聚焦或内容变化使 popover 意外关闭。

PerchModel 协调账号、任务、额度与动作，后台队列读取本机状态，主线程发布 UI 更新。任务元数据在面板打开时每 5 秒轮询，面板隐藏时每 20 秒轮询；Claude 桌面会话按每个账号的 `profilePath/local-agent-mode-sessions` 读取元数据 JSON 和固定位置的 audit 尾部，分别缓存文件长度与修改时间。本机 `~/.claude/projects` 的 Code 历史只显示在使用默认 Claude profile 的卡片，标记 Code；这是本机历史展示约定，不能证明 Code 与桌面账号登录一致，独立 profile 不混入这些记录。额度独立每 5 分钟同步，可在设置关闭，打开面板和手动刷新也可触发。自动请求遵守节流；读取旧式钥匙串时使用受串行锁保护的临时交互开关，禁止后台弹窗，完成后恢复开关。手动请求允许系统请求授权。并发请求去重，服务限流时退避。

Codex 使用所属账号的 app-server 查询额度，本地 rollout 尾部记录提供回退。Claude 使用所选桌面配置中当前账号的 profile 授权查询 usage 服务，并用客户端历史与 IndexedDB 额度事件回退。账号 UUID、组织与 scope 必须匹配；旧组织历史不阻断唯一有效的新登录。同一账号同时属于多个组织（例如个人和 Team）且历史里没有可用的组织记录时，提示这个原因，不随意选一个。额度显示记录所属账号，客户端换了登录账号后不再显示旧账号的额度；历史样本按组织过滤，已知属于其他账号的组织不参与回退。成功替换缓存；失败保留原始观测时间，不能用更旧的缓存覆盖实时快照。Claude 端点不是承诺稳定的公开集成 API，变更、授权过期或限流均明确显示原因。

外部命令（ps、lsof、open、agy、媒体组件、Codex app-server）统一由 `Subprocess` 运行。每个子进程放进独立进程组，超时先发 TERM，0.5 秒后对整组发 KILL，不留下孙进程。阻塞等待在 DispatchQueue 上进行，异步调用通过 continuation 取回结果，不占用 Swift 并发线程。不跟随重定向、不缓存、不保存 cookie 的 URLSession 统一由 `PrivateHTTP` 创建。钥匙串只在额度队列上读取。

## 数据与兼容

- 数据根目录：`~/Library/Application Support/Perch/`。`accounts.json` 保存账号槽；客户端原目录继续原地引用。
- 删除账号并把数据目录移到废纸篓前重新运行 `ps`：客户端仍在使用这个目录时拒绝，`ps` 失败时也拒绝，账号保留。客户端默认数据和本机供应商引用的目录不提供回收。
- `removed-accounts.json`：升级时从 `accounts.json` 移出的旧 API 供应商和自定义客户端账号（0600），只写不读。
- `session-order.json` 按账号保存会话 ID 顺序（0600），不改客户端记录。只允许在同一账号、同一活动状态分区内拖动；新会话保留来序，活动会话仍显示在上方。
- `handoffs/`：旧版文档接力留下的副本、`log.jsonl` 和 `pending.json`。接力和拆出需求已删除，Perch 不再读写这个目录，也不删除它。
- Claude 登录信息通过 macOS 钥匙串解开对应客户端的加密配置，仅在内存用于 `api.anthropic.com` 额度请求；不保存、打印、不刷新 token，不改变客户端登录，也不跟随请求重定向。
- 偏好域为 `com.omnis.perch`，保留从 `com.pox.desktop` 的一次性迁移，不覆盖已有新偏好。
- 桌宠能力默认关闭；开启后默认选择静态原生浮球。Pox 主题由角色选择决定，隐藏角色仍保留主题。原生角色和能力关闭时保持系统毛玻璃外观。

## 产品边界

只支持本机 Codex / Claude。多实例深链无法保证定向，因此会话点击优先调出正确账号，具体对话可能仍需手动选择。没有跨账号原会话复制、跨设备同步、外部角色包或通用插件系统。agent-desk 上游同步与退役继续暂缓；Perch 的发布不删除其数据或修改其仓库。

面板内容使用固定列宽，折叠区域整行可点击；长内容通过滚轮或触控板滚动，不因滚动条出现而重新换行。
