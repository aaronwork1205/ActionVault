# ActionVault 应用图标

`AppIcon.png` 是透明背景的正式应用图标源图，使用内置 image_gen 从 `docs/brand/03-memory-lens.png` 派生。

运行 `scripts/build-icon.sh` 生成 16–1024 像素的标准 macOS 图标集合及 `.build/AppIcon.icns`。打包脚本将其复制到应用 Resources，并通过 `CFBundleIconFile` 注册。

## 生成提示词

Edit the referenced ActionVault brand art into a production macOS app icon asset. Preserve the mint/teal optical-glass rounded square icon, silver rim, stacked translucent photo frames and central camera lens. Remove ALL text, wordmark, dark rectangular backdrop and floor; outside the rounded-square icon must be genuinely transparent. Single centered front-facing icon, square canvas, icon fills about 88% of width and height with equal transparent margins on all sides. Clean silhouette, no perspective tilt, restrained tiny shadow only. Simplify fine highlights for small-size legibility while maintaining the recognizable design. Output one square high-resolution icon, no typography, no mockup.
