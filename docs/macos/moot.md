# Moot 模型协作扩展（macOS）

从 Perch 设置的「扩展 → Moot → 管理」打开原生窗口，点击安装。首个本地版本使用 Perch 随附的可选扩展包，也可选择本地 `.mootpkg` 目录更新；尚未配置公开下载源或发布 Release。执行程序自带 Node，不依赖开发机 PATH。

## 配置与使用

1. 模型接入中选择 Perch 账号，或显式添加独立 CLI 绑定。仅所选接入可用。Claude 桌面账号与 Claude Code 不是同一凭据目录；默认 Claude Code 绑定保留它原有的 Keychain 身份。
2. 能力配置中设置「交给谁」「怎么完成」。详细配置包含模型覆盖与备用；具体路径集中在接入。通用委派使用能力 ID `general`。
3. API 默认关闭。图像生成默认 Gemini 订阅的内置工具；Nano Banana 在这里是工具能力，不是独立订阅账号。API 凭据只存系统钥匙串，需要总开关、接入与能力备用均配置才会调用。失败文字或绘图提示不算图片。
4. 在模型接入页选择客户端的 skills 目录安装统一家族。已有同名文件不会覆盖；「预览旧技能迁移」会先备份选定目录内的旧入口，再安装新技能。新对话通常才能发现更新后的技能。
5. 当前对话 agent 使用 `moot-delegate`、`moot-review` 或 `moot-roundtable`。普通任务自动按能力选择；明确指定模型时不可静默替换。执行前检测到登录不可用时可选配置中的备用；已执行过的普通写任务不自动重跑。

圆桌单独设置自动发起开关，默认关闭。显式要求开会仍可执行。第一轮独立，后续收到上一轮完整材料；当前对话 agent 每轮回读、提交总结并推进。达到轮数上限后保留未解决问题。退出 Perch 不影响任务；主持对话中止后可停在等待主持人，不会自动生成总结。

### 可以直接试的对话

安装技能后，在 Codex 或 Claude Code 新建对话，直接输入下面的自然语言。模型与账号按自己的已保存配置选择，不必手写 CLI 命令。

自动选择执行者：

```text
请使用 moot-delegate，按已保存的能力配置自动选择执行者，为一个本地待办应用写一页上手指南。功能有添加任务、设置截止日期、完成和归档。你负责检查结果并给我最终版本，不需要我指定模型。
```

订阅生图：

```text
请使用 moot-delegate 的图像生成能力，让 Gemini 通过订阅账号的内置生图工具，生成一张橙色小鸟坐在电脑旁的方形插画，简洁、温暖、无文字。返回并展示实际图片文件，不使用 API。
```

明确指定审核模型：

```text
请用 moot-review，让 Codex 的 Astra 审核当前工作区尚未提交的改动。只读，不修改文件；列出有证据的问题和未验证项，你再判断哪些需要处理。
```

圆桌（接入和模型须已配置）：

```text
请用 moot-roundtable 讨论“本地待办应用是否应该默认开启每日提醒”。你担任主持人，Codex Astra 负责技术评估，Claude Sonnet 负责用户体验，Gemini Argon 负责反方审视，共三轮。第一轮独立发言，后续回应其他人的观点和分歧；你每轮归纳。三轮结束后给出共同建议、你的判断和仍未解决的问题，不自动增加轮数。
```

自动选择指在允许的能力范围内选择执行者，不代表每个普通问答都要调用其他模型。查看调用与产物：Perch → 设置 → 扩展 → Moot → 管理 → 运行记录。打开管理时 Perch 浮动面板会收起；重复打开会唤回同一窗口。

## 记录与生命周期

运行记录显示真实消息、工具事件、错误和产物。圆桌区分共同建议、主持人判断及开放分歧；分歧链接回原文。可以复制结果、导出 Markdown、打开图片或在 Finder 定位。不会采集任意私人聊天。已有 `runs` 目录可只读查看，旧 Moot 格式中缺少的轮次或状态不会被补造。

配置与运行目录位于用户 Application Support 下 `Perch/Extensions/Moot`。技能引用受管理的稳定入口，不覆盖已有个人 `~/.local/bin/moot`。更新准备独立版本后切换，新旧任务各用自己的版本。卸载停止接收新任务，默认等待活动任务（含等待主持人的会议）结束；也可明确取消后卸载。保留配置、历史与产物，只移除清单内的程序及未被手工改写的技能。

迁移备份位于扩展根目录 `backups/skills-*`，`migration.json` 保存原目录与备份对应关系。可从「恢复旧技能」选择该记录恢复。只替换未改动的托管技能，并备份被替换的新入口；检测到个人修改时停止恢复，不覆盖。更新扩展会刷新未改动的托管技能。

宿主自身的沙箱仍然生效。受限 Codex CLI 可能无法让子进程读取 Claude 钥匙串；这时记录失败并使用宿主正常的权限流程，不能靠 detached 进程绕过限制。当前 Codex 桌面对话与 Claude Code 的实际委派已验证，Claude 桌面应用直接作为发起端未验证。

## 开发和本机验证

- `node --test extensions/moot/test/*.test.js`
- `swift test --package-path macos`
- `macos/script/build_and_run.sh --build` / `--install`
- `bash macos/script/package-moot.sh --local`：生成 arm64 与 x86_64 包，不上传。
- `open -n ~/Applications/Perch.app --args --moot -petCharacter native --moot-appearance light`：仅在本次进程预览浅色；不写系统外观设置。
- `open -n ~/Applications/Perch.app --args --moot`：直接打开扩展窗口；正常入口仍为 Perch 设置。

Node 运行时锁定 v24.22.1，下载自 [Node 官方分发](https://nodejs.org/dist/v24.22.1/)，核对官方 SHA256，包中保留许可证。Google API 适配采用 [官方图像生成接口](https://ai.google.dev/gemini-api/docs/image-generation)；当前用户未启用 API，真实计费调用未执行。

实际范围见 [本机验收记录](moot-acceptance.md)。macOS 14 为最低版本；Apple Silicon 为本机验证平台，Intel 和 Windows 不以交叉构建或源码代替实机验收。
