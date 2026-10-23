# Moot macOS 接入验证

2026-10-24；执行环境为本机 Apple Silicon。真实日志与图片放在忽略的 `scratch/moot-feasibility/`，不提交账号资料或私人会话。此表是通路验证，不代表扩展交付。

| 路径 | 结果 | 证据与适配决定 |
| --- | --- | --- |
| Codex CLI 订阅调用 | PASS | CLI 0.163.0，ChatGPT 登录；实际发现项目技能、启动独立探针、回读 42 并继续回答 HOST_CONTINUED: 42 |
| Claude Code 订阅调用 | PASS（重新登录后） | CLI 2.1.296 登录检查显示 claude.ai；真正调用却返回 OAuth session expired and could not be refreshed。用户重新登录后实际技能回读通过；不能按登录检查判为可用 |
| Gemini / Antigravity 订阅生图 | PASS（工具产物） | agy models 返回 Argon 系列；实际工具表含 generate_image。新任务通过 image-generator 内置子代理生成蓝色杯子 JPEG，独立图像解码与目视确认有效 |
| Antigravity 产物回收 | 部分验证 | 默认权限拒绝模型发起的转换命令；适配器应依据本任务 conversation ID 只读收集其生成目录中的图像，保留原格式。无需模型执行复制或转换，不重试已拒绝命令 |
| 脱离调用端的进程 | PASS（探针） | 启动命令返回后独立进程写结果，宿主下一次命令可读取；尚须产品 worker 与退出 Perch 的实测 |
| Codex / Claude 桌面宿主技能 | NOT_RUN | CLI 结果不代表桌面应用通过；Codex 当前桌面线程具备执行入口，可于安装后验证。Claude 待重新登录和实测 |
| API 生图 | NOT_RUN | API 默认关闭；未调用 API，也不以继承的环境凭据兜底 |

账号绑定使用明确的 CLI 配置根目录。Claude 桌面 profile 不映射为 Claude Code 登录；Antigravity 与 Gemini CLI 为不同接入。CLI 路径从 Perch ToolPaths 查找并允许用户覆盖，不写入个人默认路径。所有子进程过滤 API key、认证令牌、服务端地址与 Vertex/Bedrock/Foundry 路由环境；Codex 使用 ignore-user-config 确保订阅适配不继承自定义 API provider。

外部 Moot 无可核实的 LICENSE；本次只读行为与事件形状，产品实现独立编写于 Perch 仓库，未复制源文件。完整扩展仍需安装、运行、圆桌与 UI 验证。
