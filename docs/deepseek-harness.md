# DeepSeek Harness：双端接入

源码开发版在 macOS 和 Windows 上提供同一套 dsh Web 能力：发现安装、添加或关联账号、启动与恢复连接、根会话状态、官方钱包和独立 API 余额。macOS 仍保留原有 DSH Desktop／终端入口，和 Gemini、Antigravity 使用同一个账号列表；无需创建另一个 DeepSeek 分组。

两端共享协议样本、状态判定、文案和角色资源，窗口、进程管理和授权存储分别使用各平台实现。此页描述源码能力，不代表已发布 Release 或真实模型任务已验收。

## 添加和关联

在新建账号页选择 DeepSeek Harness 的 Web 入口，可以选择：

- **npm 安装版**：扫描本机 npm 安装和 npx 缓存，或手动选包目录／命令入口。Perch 读取包清单找到 CLI，不自动安装或升级 dsh。
- **源码构建版**：选择已执行 `pnpm install` 和 `pnpm run build` 的 deepseek-harness 仓库。CLI 和 Web 资源都须存在。
- **连接已有实例**：粘贴 dsh 启动时输出的完整本机授权 URL。无需 Node 或安装目录；重连时可以替换授权。不能用 DSH Desktop 的 Electron 页面地址代替 Web 授权。

受管模式的账号数据目录是 `DSH_HOME`，与安装目录分开。留空创建新的独立目录，选择已有目录则原地引用。macOS 支持 `~/.dsh`、`$HOME/.dsh`；Windows 支持 `%USERPROFILE%\.dsh`、`~\.dsh`，检查与创建使用相同的路径解析。Node 必须满足所选 dsh 版本的要求，profile 默认是 `web`，不能使用 Electron 的 `desktop`。

Mac 已有的 DeepSeek 账号按规范化后的数据目录关联 Web 配置，保留账号 ID、顺序、名称和原客户端启动配置。网页入口使用实时 RPC；保留的原客户端入口仍能打开 DSH Desktop 或终端。没有添加 Web 配置的旧账号继续读取原本的本地会话与余额。Gemini 和 Antigravity 的扫描、额度来源及启动流程不变。

已有 Web 实例的 API 余额需要另选它实际使用的 `DSH_HOME` 作为“余额凭据目录”。留空仍可查询 Web 任务和官方钱包，不会扫描其他目录寻找 Key。

## 服务与授权

受管 Web 服务绑定 `127.0.0.1`，使用动态端口。独立后台宿主持有每个 home 的进程锁；重新打开 Perch 时恢复已有服务，不再占用固定的 3080 端口。退出面板不停止任务，账号菜单的“停止服务”才会停止受管实例。外部连接只能断开，移除账号不删除 home、不关闭服务。更换 Perch 程序文件前，先显式停止受管宿主。

授权 URL 和 Cookie 不写进普通账号 JSON：Mac 保存到当前用户钥匙串，Windows 使用当前用户 DPAPI。启动输出只提取本机授权地址，不记录原始 stdout/stderr。更换连接会清空旧实例的会话和钱包缓存。API Key 仍属于 dsh 的原凭据文件，Perch 不保存副本。

## 任务和余额

根会话来自 `session/list`，标题使用 Web 的 title projection。空白占位和子 agent 不进入列表；空闲、未运行或断连不等于成功完成。只有最近回合明确的 `turn/end`／`completed` 证据才显示完成；新一轮开始、待处理输入和实时运行状态优先于旧结果。断连保留元数据和记录时间，但状态变为未知，不触发完成通知。点击会话打开所属 Web 实例，具体对话在 dsh 内选择。

为判断结束状态，最近一个消息事件窗口可能包含正文并进入内存；Perch 不展示、不记录、不落盘，缓存只保留游标和判定。Mac 的 Web 任务复用现有会话排序、通知和桌宠反馈。

官方登录钱包和 DeepSeek API 余额分别显示，各自保留时间、错误和同一身份的有效缓存。金额保留币种与充值／赠送分项，不混加成百分比。API 余额先通过 dsh 的默认模型、提供方、Key 引用和凭据来源确认路由，只读取指定 home 的标准 `.credentials.yaml` 文件，只向 `https://api.deepseek.com/user/balance` 发送 Key，并拒绝重定向。环境变量／dotenv、第三方提供方和自定义凭据文件不回退成默认文件 Key。

## 验证

两端测试共同消费 [`shared/fixtures/dsh`](../shared/fixtures/dsh/README.md)，覆盖根会话过滤、跨平台路径元数据、结束证据及钱包精度。这些合成样本和隔离 RPC 服务不能替代真实 dsh 模型任务验收。

```bash
swift test --package-path macos
macos/script/build_and_run.sh --build
macos/dist.noindex/Perch.app/Contents/MacOS/Perch --verify-bundle-resources
```

```powershell
windows/script/build.ps1 -Action Test
windows/script/build.ps1 -Action Package
```

Mac 发布包携带共享文案、两套图集、`NOTICE` 和 `LICENSE`；CI 还会将 `.app` 复制到脱离仓库的目录后检查资源。真实服务授权、重启恢复、明确停止、双 home、钱包和模型完成通知仍应在对应平台验收。记录分别见 [Mac 验收](macos/acceptance.md) 和 [Windows 验收](windows/acceptance.md)。
