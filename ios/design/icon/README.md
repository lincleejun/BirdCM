# 观羽 App Icon · 第四轮

**排序：B > C > D > A。推荐 B「近身定睛」。**

B 保留 K1 的翠鸟、深海青底、翠青羽色、橙胸和米白喉带，用更宽的头胸、短一些的喙和更大的眼睛解决桌面上显小的问题。C 更强调眼睛，适合偏品牌头像的方向；D 是 B 的轻渐变备选；A 保留完整鸟形，视觉体量仍弱于头像方案。

全部制作文件位于本 icon4 目录；未修改仓库，也未安装到 App。此处的默认图标仍使用 K1 的深海青品牌背景；“默认”不等于必须白底。

## Apple 当前规范与网格

核对日期：2026-11-18。阅读的是 Apple 在线正文，而非沿用上一轮说明。

- [HIG / App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)：iOS 使用 1024×1024 正方形原稿，由系统裁圆角；主体居中，采用简单、厚实、少量形状，避免非必要文字。外观之间保持同一设计。当前接受 PNG，也推荐 Icon Composer 分层格式。系统负责动态高光、折射、阴影等效果；不要把固定玻璃高光烘焙进源层。深色以默认设计为基础，使用协调、较克制的颜色。
- [Apple Design Resources](https://developer.apple.com/design/resources/) 当前列出 **iOS 27 / iPadOS 27** 模板。本次下载其 [Photoshop / Illustrator 官方模板](https://devimages-cdn.apple.com/design/resources/download/iOS-27-Icon-Templates-Photoshop-Illustrator.dmg)，直接读取 AI 的矢量坐标：画布 1024；中心 (512,512)；128 px 分格；同心圆直径 **820、512、204 px**，外接框分别为 (102,102)–(922,922)、(256,256)–(768,768)、(410,410)–(614,614)。模板没有把某个百分比宣布为 iOS 的硬性安全区。
- 本轮以 128/896 分格线构成的中央 **768×768 构图框**安排头胸，允许喙略作光学延伸，并对照 820 圆与真实系统圆角轮廓检查。该构图框是本轮设计选择，并非声称 Apple 强制“75% 安全区”。主视觉围绕 (512,512)，右向喙以左侧胸背重量平衡。`grid-proof.png` 显示四款叠加官方原始网格；`research/template-geometry.txt` 留有读数。原图没有圆角、网格或文字；预览圆角使用官方模板轮廓。
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)：前景 SVG/PNG 分层、保持相同画布；背景可在 Composer 中设置；尽量用矢量，最多四个前景分组。提供 default / dark / mono 标注，工具预览与系统生成各尺寸及外观。`.icon` 加入 Xcode 后替代旧图标资产，并为旧系统生成兼容图片。
- [WWDC26 / Icon Composer for Beginners Group Lab](https://developer.apple.com/videos/play/wwdc2026/8012/) 的 35–36 分钟说明：**单一 mono 灰阶标注**支撑 clear light/dark 与 tinted 外观。因此本轮 tinted 交付的是高对比灰阶明度图，由系统着色，绝不是绿色成品。分层路线还应在 Composer 中查看 clear 与 tint 的亮/暗模式。

### 透明度与颜色交付

默认 PNG 为 **RGB、sRGB、满版不透明**。深色 PNG 采用 `#0D2026` 不透明暗背景；与默认完全同形，仅作克制配色调整。本轮选择自带暗背景，不把透明当作深色图标的硬性要求。另提供透明前景供 Composer 使用，背景由工具设置；导入自定义背景时应满版且不透明。

Tinted PNG 是 **L 模式灰阶**，写入约 Gamma 2.2 的 gAMA 信息（0.45455），背景灰阶 32、羽色 189、胸部 133、白色 250、眼睛与翼 36。它是为对比重新安排的明度稿，不是机械去色；没有任何绿色像素。这里选用不透明灰阶底；透明的是独立前景层。`appearances.png` 的第三列展示交付灰阶，真实用户选色与 Liquid Glass 以系统渲染为准。

## 设计与尺寸比较

测量口径：将**不含背景**的主体渲染为 1024，alpha≥128 的像素计为主体；bbox 为半开像素边界。面积是实际实色占比，不是 bbox 的矩形面积。K1 来自提供的原始 SVG，同口径计算。

| 方案 | 主体 bbox (x0,y0,x1,y1) | 宽 / 画布 | 高 / 画布 | 实色面积 / 画布 | 判断 |
|---|---|---:|---:|---:|---|
| 原 K1 | 231,272,871,788 | 62.50% | 50.39% | 13.86% | 长喙尾撑开边界，头胸偏小 |
| A 完整翠鸟 | 171,167,893,869 | 70.51% | 68.55% | 26.01% | 延续性最强，尾部仍使视觉偏瘦 |
| **B 近身定睛** | 155,144,899,891 | **72.66%** | **72.95%** | **35.12%** | 首选，形体完整、眼与胸部平衡 |
| C 锐眼肖像 | 132,136,909,890 | 75.88% | 73.63% | 37.71% | 眼最大，辨识直接，稍偏卡通头像 |
| D 柔光翠影 | 155,144,899,891 | 72.66% | 72.95% | 35.12% | B 的轻渐变，给分层材质留余地 |

B 的实色面积约 **2.53×** K1，高度增加 22.56 个百分点；bbox 面积从 31.49% 提升至约 53.00%。眼睛暗瞳直径由 K1 的 94 px 改为 A 116 / B、D 140 / C 168 px；配 9 px 米白眶环和清楚的实色高光。B 在 29 px 时暗瞳直径仍约 3.96 px。喙由 K1 约224 px 的突出长度缩至 B 约180 px，略向右下指，主体不再被长针状喙拉散。

- **A**：重画更宽的头胸和翼，尾尖改为小圆钝收口，橙胸以连续曲线替代原先突兀的折角。完整鸟形仍占用较多负空间。
- **B**：去掉细长尾巴，以三分之四近景收在圆弧胸底；更宽的翠冠、橙胸与深翼形成三块稳定面积。保留 K1 的物种配色和姿态，比较适合延续现有识别。
- **C**：再放大头部、移除翼与尾；第二次检查后收窄白喉斑的下沿，避免抢过眼睛。比 B 更像品牌肖像，对完整翠鸟的表达稍弱。
- **D**：采用 B 的轮廓，仅在翠羽和橙胸做很轻的颜色渐变，没有伪玻璃反光、斜面或投影。分层源恢复平色，渐变预览不是系统 Liquid Glass 的复刻。

`measurements.json` 保存最终精确值。

## 看图与检查记录

- `contact-sheet.png`：K1 + A/B/C/D，默认外观各 **256 px**，下方是原生 **60、29 px**。
- `appearances.png`：四款 default / dark / tinted；附小尺寸。
- `homescreen.png`：浅、深壁纸两台 393×852 pt 模拟，按 3× 输出；每个图标 180 px，即 60 pt。`homescreen-1x.png` 是按点尺度查看的版本。周围使用中性方块；这是设计模拟，非设备截图。
- `size-audit.png`：全部 12 个外观的 120/87/80/60/58/40/29 原生像素检查；`audit-180.png` 为 180；`audit-1024.png` 为四款 1024 默认图。深色和灰阶大图另可直接打开独立 1024 文件。
- `proof-before.png` 是首轮默认对比。检查后改钝 A 尾尖、减小 C 喉斑，再重新渲染并复查全部外观。最终小尺寸仍能读到眼睛、白喉带和短喙；29 px 的眼高光接近单像素，不能指望它表现摄影细节。C 最醒目，B 的种类感和形体平衡更好。
- 所有方案、所有外观均输出 **1024、180、120、87、80、60、58、40、29** 九种尺寸，共 **108 张**独立 PNG。`validation.txt` 记录尺寸、模式与不透明检查。拼版中的圆角仅用于查看；交付图仍为方形。

## 可以直接使用的文件

每款均有 `{A|B|C|D}.svg`、`-dark.svg`、`-tinted.svg` 和对应九种尺寸 PNG。

推荐 B：`delivery/B/AppIcon.appiconset/` 已包含完整四个文件：

1. `icon.png` ← `B-1024.png`
2. `icon-dark.png` ← `B-dark-1024.png`
3. `icon-tinted.png` ← `B-tinted-1024.png`
4. `Contents.json`：universal / ios / 1024×1024，暗色与着色使用 luminosity appearance 条目。

要应用到现有工程：用上述四个文件替换 `ios/BirdCM/Assets.xcassets/AppIcon.appiconset/` 内对应文件。此次没有执行替换。A/C/D 在 `delivery/` 中有相同的完整资产目录。小尺寸 PNG 是检查用，当前单尺寸 universal 目录无需逐张放入。

## Icon Composer 分层组装

本轮交付的是**可导入源层**，没有声称生成或实测了 `.icon` 包。

每款的 `layers/{编号}/{default|dark|tinted}/` 包含：

- `00-background.svg`：满版背景参考；通常直接在 Composer 设置背景颜色，无须导入为前景。
- `foreground.svg` 与 `foreground.png`：同画布的透明整鸟前景，用于最稳妥的一组导入。
- `01-shape.svg` 起的独立色块；最后一层包含眼眶、瞳孔、高光。与整鸟前景二选一，不能重复叠加。

操作：Xcode → Open Developer Tool → Icon Composer，新建 1024 iOS 图标。设置默认背景 `#123D46`、Dark 背景 `#0D2026`；导入 B 的 default 前景，保持原始 1024 坐标、中心与尺寸，不使用自动裁紧后的缩放。整鸟先放一组，让所有色块保持同一表面。需要更细材质控制时改用独立形状，身体一组、胸翼喉喙一组、眼睛一组（共三组）；不要让每个颜色片都产生厚重的独立立体边缘。

Dark 使用 dark 源的颜色；Mono 使用 tinted 源的灰阶值。背景用工具的 mono 设置。保持眼睛高对比和不透明，胸羽从不透明开始，再少量尝试 translucency；specular / refraction 在 Composer 内调节，不烘焙到 SVG。iOS 27 提供的效果与 iOS 26 不完全相同，分别预览 26/27、default/dark/mono，以及 clear/tinted 的 light/dark，尤其检查 29/40/60 尺寸和浅深壁纸。D 可在背景或工具支持的颜色设置中轻微调色，所附平色源没有强制透明度。

最后通过 Composer 保存 `AppIcon.icon`，加入 Xcode 工程并关联 app target 的图标名称。该包是工程资源，不是把一堆 SVG 塞进 `.appiconset`；采用它后旧系统图片由 Xcode 从包生成。仍需在实际设备确认系统着色、动态高光与商店图标。本目录 PNG 是确定性的平面交付，不冒充已验证的系统材质输出。

## 复现

`python3 build.py` 生成矢量、PNG、拼版、模拟和测量；`python3 verify.py` 生成审阅图、验证与 delivery。依赖 Pillow、rsvg-convert。官方网格/轮廓由 `research/extract_grid.py` 从下载的官方 AI 提取，依赖本目录 `.venv` 中的 PyMuPDF。原始模板与许可证保留于 `research/template/`，仅作为设计依据。
