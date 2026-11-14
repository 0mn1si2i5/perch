# 内置视觉资源

`AppIcon.svg` 是 Perch 应用及菜单栏使用的栖鸟标记，构建时生成多尺寸 icns。

`pox-atlas.png` 是内置 Pox 角色透明图集，1774 × 887，4 列 2 行，第一行止于 y=449；姿态裁剪由 `PetView` 管理。素材由主人选定，源于 2026-09-28 的角色制作。图集只用于可选 Pox 桌宠，不代表默认应用外观。

原生桌宠复用 Perch 标记，为静态磨砂浮球。Windows 原生桌宠为静态纯色浮球。macOS 主题映射集中在 `macos/Sources/Perch/UI/CompanionTheme.swift`。

## DeepSeek 鲸鱼娘

`deepseek-whale-atlas.png` 是 2026-11-13 使用内置 ImageGen 制作并修订背景透明度的 Q 版二次元图集，1774 × 887，RGBA，4 列 2 行。列边界按宽度四等分向下取整，行边界按高度二等分四舍五入（y=444）；奇数尺寸导致相邻格最多相差 1 像素。Pox 仍使用自己的 y=449 边界。

按从左至右、从上至下顺序：休息、招呼、思考、听音乐、看视频、庆祝、困惑、提起。各姿势保留完整头发、鳍耳和鲸尾；供 135–265 像素大小的桌宠使用。角色选择值为 `deepseek-whale`。Windows 启用该角色使用 DeepSeek 暗色面板主题，隐藏桌宠时仍保留；macOS 该角色跟随系统明暗，其新增桌宠与资源加载代码仍待 Mac 测试、构建及实机验收。原 Pox 主题保持独立。

参考：[TreapGoGo/deepseek-whale-girl](https://github.com/TreapGoGo/deepseek-whale-girl) 首页 Q 版指导。参考文字与提示词由该社区按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 提供。本图集为 Perch 项目 AI 辅助制作的变体，重新绘制姿势与构图、移除背景，按同一许可分享；未直接复制社区投稿图片。此角色为非官方社区二创，不代表 DeepSeek 官方。实际生成和修订提示词见 [制作记录](deepseek-whale-prompts.md)。
