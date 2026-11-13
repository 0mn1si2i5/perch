# DeepSeek 鲸鱼娘互动文案对照

2026-11-13。仅角色 `deepseek-whale` 使用；Pox 与原生浮球沿用原文案及显示规则。角色切换清除上一角色的临时反馈。安静模式仍隐藏文案。

## 参考与写作方向

- [社区资源库](https://github.com/TreapGoGo/deepseek-whale-girl)：鲸鱼娘属于持续变化的非官方社区二创，不存在唯一标准人设。
- [字母 AI／36氪《DeepSeek 里长出了个“鲸鱼娘”》](https://ad.36kr.com/p/3947452108789632)（2026-08-20）：交叉核对爱吃白饭、摸鱼、称呼用户“鱼片”、呆毛与鲸尾等流行元素。报道中的角色起源与“官方收编”等判断不作为本项目事实声明。

以下为本项目新写台词，借用社区常见梗，不逐句复制来源。语气软萌、略馋、亲近；使用 ♡、♪、✧ 与波浪号点缀。任务运行中保留实际数量，完成反馈保留原有任务标题，不暗示执行了额外工作或实际消耗了 Token。

## 初次修改对照（2026-11-13）

此表保留当次修改记录；日后的实际台词以 `zh-CN.json` 为准，修改文案时无需同步改写历史对照表。

| 场景 | 修改前（鲸鱼娘与 Pox 共用） | 鲸鱼娘修改后 |
|---|---|---|
| 待机／悬停 | 待着也挺好 | 摸会儿鱼，等口白饭～ |
| 招呼／等待输入 | 收到 | 鱼片，等你发话呢 ♡ |
| 思考姿势 | 正在琢磨 | 呆毛转转，认真想想… |
| 听音乐 | 听歌中 | 尾巴跟着节拍晃 ♪ |
| 看视频 | 陪你看片 | 挨着鱼片看一会儿～ |
| 庆祝 | 搞定了 | 干完啦！白饭加一碗 ✧ |
| 困惑 | 挠头 | 咦？呆毛打结了…？ |
| 提起／拖动 | 好家伙，被提起来了 | 呜哇～尾巴悬空啦！ |
| 实际任务运行 | Windows：`N 个任务`；macOS：`Codex · N 个任务` | `N 个任务，努力游！` |
| 未知类型媒体播放 | Windows：媒体播放中；macOS：陪你看片 | 有声音耶，陪你听～ |
| 拖动落下 | 好家伙，搬家了。 | 搬好窝啦，饭碗也带上～ |
| 双击 | Windows：向你敬礼；macOS：收到（姿势标签，无气泡） | 收到，鱼片！这就来～（Windows 标签／macOS 气泡） |
| 任务完成气泡 | 搞定一个。＋换行＋任务标题 | 做完啦！开饭～ ♡＋换行＋任务标题 |
| 动作预览 | Windows 标签：动作预览；macOS 标签：动作预览，气泡：动作预览 · 原姿势名 | Windows 标签：对应鲸鱼娘姿势台词；macOS 标签：对应台词，气泡：动作预览 · 对应台词 |

设置中的动作名称保留简明的功能命名，实际预览与桌宠反馈使用上述台词。待机标签仍仅悬停时显示；真实任务数量覆盖思考姿势台词；拖动落下的临时反馈覆盖困惑姿势台词。

## 以后如何修改

**唯一文案源：[zh-CN.json](zh-CN.json)。** 两端均从这份 JSON 读取桌宠台词，不再在 Swift／C# 中维护台词副本。

| 键 | 用途 |
|---|---|
| `pet.whale.pose.0`～`7` | 鲸鱼娘八种姿势，依次为待机、招呼、思考、听歌、看视频、庆祝、困惑、提起 |
| `pet.whale.running`、`pet.whale.media`、`pet.whale.moved`、`pet.whale.doubleClick`、`pet.whale.completion` | 鲸鱼娘任务、未知媒体、搬家、双击、完成反馈 |
| `pet.pose.*`、`pet.running`、`pet.media`、`pet.moved`、`pet.doubleClick`、`pet.completion` | 原有通用／Pox 文案，不被鲸鱼娘使用 |
| `pet.running.codex` | macOS 原有 Codex 任务计数文案 |
| `pet.preview`、`pet.preview.detail` | 通用预览提示及包裹角色台词的预览气泡模板 |

只改对应键的值，保留键名、UTF-8 编码和合法 JSON。`{0}` 是两端共用的唯一占位符：`running` 中代表任务数量，`preview.detail` 中代表角色姿势台词；可以调整位置，需要显示该信息时保留它。换行使用 JSON 的 `\n`，双引号使用 `\"`。♡、♪、✧ 等字符可以直接输入。较长台词需要检查最小桌宠尺寸是否完整显示。

Windows 通过现有 `Strings` 加载嵌入程序集的 JSON；macOS 的 `build_and_run.sh` 将原文件复制到应用的 `Contents/Resources/zh-CN.json`，`PerchCore.Strings` 优先加载应用资源。`swift test`／`swift run` 没有 `.app` 包时直接读取仓库中的同一文件；已打包应用缺失资源时不会偷偷回退到开发机源码。

修改后重新构建两端并重启对应应用即可，不支持运行时热更新。Windows：`windows/script/build.ps1 -Action Test`，随后 `-Action Publish` 或 `-Action Package`；macOS：`swift test --package-path macos`、`macos/script/build_and_run.sh --build`。测试读取资源中的预期文案，无需随每次措辞调整改写 Swift／C# 测试。

角色分流仍只允许 `deepseek-whale` 访问 `pet.whale.*`；Pox 访问通用键；浮球沿用不显示台词的行为。macOS 的 Pox 双击仍不新增气泡，未知媒体仍显示原有看视频姿势标签。
