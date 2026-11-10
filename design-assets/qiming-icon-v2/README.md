# Qiming v2 · 栖羽含光

依据 2026-11-03 更新的 `Qiming-UI设计稿.md` 第 3、11 节，以及用户提供的 `qiming-icon-v2-reference.png`、`qiming-menubar-states.svg` 重绘。

## 设计与源文件

正式图标使用珍珠银外翼、香槟金内翼和夜墨底板；没有横条圆点、具象电脑、羽毛纹理或附加装饰。两翼母形复用菜单栏 SVG 中的贝塞尔走势，应用图标在 1024 画布下约占 63% 宽、59% 高，光学中心略高。

- `source/OuterWing.svg`、`source/InnerWing.svg`：可编辑曲面。用少量连续曲线定义轮廓，并通过同一曲面的矢量明暗分带形成柔润体积；无位图、噪点、字体或第三方资源。
- `source/geometry.json`：两翼母形与应用图标变换参数。
- 工程正式资源：`Qiming/Resources/AppIcon.icon`，内部包含同一组 SVG 与默认 / 深色底板设置。
- 用户提供的参考 PNG 与菜单栏 SVG 保持原样，不放入应用包。

## 交付文件

- `exports/Qiming-native-Default-1024.png`：默认外观的正式 1024 PNG。
- `exports/Qiming-native-Dark-1024.png`：深色外观。
- `exports/Qiming-native-TintedLight-1024.png`、`TintedDark`：系统着色示例，色相 0.58、强度 0.35；实际外观由用户系统设置决定。
- `exports/Qiming-icon-review.png`：应用图标与 16–1024 尺寸核查总览。
- `exports/Qiming-menubar-native-states.png`：直接使用正式 AppKit 绘制函数生成的浅深色三态评审图。
- `exports/menubar-*.png`：22 pt 的 1× / 2× 模板预览，以及独立暂停 / 告警标记预览。
- `exports/Qiming.icns`：标准多尺寸传统图标交付文件。

应用图标的 PNG 由 Apple Icon Composer 渲染器从 `.icon` 导出。菜单栏评审图由 `UI.brandImage`、`WingGeometry` 的正式路径绘制；未通过开启真实保活会话模拟活动状态。

## 菜单栏实现

三态为：双翼轮廓、外翼填充、双翼填充。22 pt 小图对内翼做统一的轻微光学校正，扩大翼间留隙；三态始终共享同一组路径。根据用户连续微调，22 pt 描边最终使用 0.68 pt。等待 / 故障回到空心态，暂停与感叹号使用额外宽度，不覆盖曲面；热预警期间保留已确认的活动填充。

图标仅在确认的模式或告警状态变化时替换。切换时保留旧图标，完成后执行约 140 ms 淡入淡出；减少动态效果时直接替换，没有常驻动画或新的刷新计时器。工具提示和 VoiceOver 标签包含模式、运行状态及定时剩余时间。

## 构建与体积

`Scripts/generate_icon_source.py` 重建原生分层源，`Scripts/export_icon_previews.sh` 导出系统外观。`Scripts/draw_app_icon.swift` 与正式 AppKit 文件共同编译后绘制菜单栏评审图；`Scripts/draw_icon_review.swift` 排列原生导出稿。

Xcode 编译生成 `Assets.car` 与兼容的 `AppIcon.icns`，不打包设计参考图、评审图或源码脚本。最终体积和构建检查见 `validation.json`。旧“一横一点”方案保留在 `Design/AppIcon/v1-栖光`。

不同壁纸的 Dock / Finder / 系统切换器完整实景矩阵仍待逐项验收；Qiming 默认为菜单栏应用，不常驻 Dock。参考：[Apple Icon Composer](https://developer.apple.com/icon-composer/)。
