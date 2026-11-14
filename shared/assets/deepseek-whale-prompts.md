# 鲸鱼娘图集制作记录

2026-11-13，内置 ImageGen，开启 `transparent_background`。首次生成后发现背景仍有半透明白灰色，使用修订提示词移除。最终输出复制到同目录 `deepseek-whale-atlas.png`，未经代码绘图或背景替换。提示词参考来源和许可见 `art-direction.md`。

## 首次生成

```text
Create a production-ready transparent RGBA PNG sprite atlas for a desktop pet. One single consistent original chibi anime DeepSeek whale girl character inspired by the community whale-girl design: approximately three heads tall, rounded cute proportions, large blue eyes, deep ocean blue long wavy hair with cyan tips and one ahoge, whale-fin ears, a clearly visible thick blue whale tail with two flukes, white frilled maid headband with blue bows, modest navy blue and white maid dress, white apron with a tiny blue whale motif, white socks and navy Mary Jane shoes. Clean polished 2D anime cel shading, strong readable silhouette at 135px, expressive but simple face, consistent identity and costume in every cell. EXACTLY FOUR COLUMNS AND TWO ROWS of EIGHT distinct full-body poses, in perfectly equal square cells; wide 2:1 canvas ideally 2048x1024. All poses centered within their own cell with generous transparent margins (at least 6%), same character scale and foot baseline except lifted pose. Row 1 left to right: 1 relaxed standing idle, hands at sides and friendly smile; 2 cheerful salute with right hand near forehead; 3 thinking with hand on chin; 4 listening to music with over-ear headphones and relaxed smile. Row 2 left to right: 5 seated watching a movie attentively with hands on knees; 6 celebrating with a raised fist and delighted smile; 7 puzzled scratching head; 8 lifted dangling in the air with bent knees and arms up, surprised cute expression. All eight characters must fit fully inside their exact cell, including hair, headband, ears, shoes and tail; no crossings between cells, no clipped edges. Truly transparent background, no scenery, no grid lines, no labels, no letters, no watermark, no shadows outside character, no extra figures. Do not include cats or Pox. Make a finished raster game sprite sheet, not a diagram.
```

## 透明背景修订

以首次生成图集为编辑目标：

```text
Edit this exact sprite sheet for production. Preserve the same eight adorable blue whale girl poses, identity, costume, expressions and 4-column 2-row ordering. CRITICAL: REMOVE THE ENTIRE WHITE/GRAY BACKDROP AND ALL CAST SHADOWS/HALOS. Background must be completely clear alpha=0 everywhere outside the character, headphones, popcorn prop and small expression marks. The previous sheet had semiopaque white/gray filling the background, which is not acceptable for a floating desktop pet. Do not paint a checkerboard. Preserve opaque white costume areas. Also shrink each individual pose slightly inside its own exact grid cell so every pose has 6 percent genuinely transparent empty padding on all four sides, including above ahoge and below feet; same scale across all eight poses. Exact equal four columns and two rows, 2:1 canvas. No extra figure, labels, borders, text, or watermarks. Keep blue whale tail, fin ears, navy-and-white maid costume and rich clean anime shading. Deliver truly transparent RGBA game sprite atlas.
```
