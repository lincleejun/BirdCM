# docs/requires.md 二次核对

2026-11-19。逐条核对 `docs/requires.md`（主目录未提交稿）里的事实陈述。观羽一侧读 HEAD 289b1ea 的干净 checkout；慧眼选鸟（SuperPicky，`master` 9fd4874）一侧只读 README.md、README_zh.md、ChangeLog.md、RELEASE_NOTES.md、`docs/` 下的文档，加上 `ls`，没有打开任何源码或语言包。行号都是当前行号。

## 总结

共核对 93 条：成立 78 条，部分成立 10 条，不成立 1 条，无法确认 4 条。需要改的地方：

- **不成立**：「慧眼选鸟是 AGPL」。它的 README 写的是 GPL-3.0（`README_zh.md:15,143`），AGPL 的是它用的 YOLO11。「不读不抄」这条规则照样成立，只是理由要改。
- **R4 要改的三处**：
  - 「其余三个没写原因」不对，README.md:65 给了笼统原因（数据许可还在确认）。
  - 「发布版少四样」只对 macOS 成立，iOS ipa 已经带了 clear 线性参数和 `rarity-global.sqlite`（`NOTICE.md:41-43,66-67`）。
  - 缺 `rarity-global` 的后果不是「同上」，而是「美、加、中以外显示数据不足」（`models.py:74`）。另外 `value.py` 在 HEAD 上除测试外没有调用方。
- **R8**：星级理由不只在 `stars.py:618-699`，还有 quota 策略和淘汰理由（`stars.py:403-465`、`pipeline.py:450`）。API 报错、模型缺失提示、稀有度标签也是引擎生成的中文，R8 没有列出来。
- **行号漂移**（内容没错）：`app.py:449-471` 应为 449-468；`release.md:61` 应为 62。
- **B1** 陈述全部成立。补一个影响：Q 按总权重归一（`stars.py:612`），所以美学的实际占比约 28%（0.35/1.25），文档值是约 14%（0.15/1.05）。
- **慧眼选鸟一侧**：
  - 曝光检测有，但它自己的文档说降星被写死关闭（`docs/MODEL_REPLICATION_REPORT.md:316`）。
  - 签名公证仅凭文档无法确认。
  - 更新检查只有手动按钮。
  - 「重命名原片」没有依据。
  - 「视频、多目录默认关闭」只说对一半：它们在实验室里，但明说默认隐藏的只有报告和 eBird。

**文档漏掉的明显差距**（只在文档层面顺带看到，不展开）：

- 精选旗标和颜色标签（飞版、精焦、失焦），`README_zh.md:47`。
- Lightroom 插件：`ls` 有 `SuperBirdIDPlugin.lrplugin`，另见 `docs/LIGHTROOM_PLUGIN_FEATURES.md`。
- 结果浏览器里批量删除，右键在 Lightroom、Photoshop、Finder 打开（`README_zh.md:45`，`RELEASE_NOTES.md:33`）。
- 分享报告和 PDF（`README_zh.md:48`）。观羽 PRD 里网页报告也还是待定（`prd-desktop.md:84`）。
- 4、5 星（`ChangeLog.md:1203`）。
- Windows 和 Intel 包（R7 已明确不做）。

另有两处顺带看到的文档过时：PRD 仍把 eBird 列为待定（`prd-desktop.md:82`），实际已经做了；`eval.md:148` 的评测没有地区先验，现在的流水线已经有了（`pipeline.py:366`）。R4 重跑评测时要一并说明。

## 前言与「动手前必读」

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 对照的是慧眼选鸟 `master` 4.6.5 RC6 | 成立 | SP `ChangeLog.md:1`；SP 当前分支 master（9fd4874） | |
| 慧眼选鸟是 AGPL | 不成立 | SP `README_zh.md:15,143`：GPL-3.0；`README_zh.md:146` 列了 YOLO11 | README 没写 YOLO11 的许可。requires.md:9 和 `design.md:15` 的说法要改成「GPL-3.0（所用 YOLO 为 AGPL）」 |
| 不读不抄的规则在 `docs/design.md:15` | 成立 | `docs/design.md:15` | |
| 原片文件夹只读：`prd-desktop.md:113`、`design.md:8` | 成立 | 同左 | |
| 测试范围受 hook 限制：`ios/README.md:43` | 成立 | `ios/README.md:43`；`.claude/hooks/test-scope.sh` 存在 | |
| PRD 的用户是主人自己：`prd-desktop.md:12` | 成立 | 同左 | |

## R1 星级和鸟名写给 Lightroom

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 只能导出 CSV、JSON 和 eBird 文件 | 成立 | `web/src/Results.tsx:658-659`；`engine/birdcm/app.py:551,560` | |
| 导出框文案「写给 Lightroom 的 XMP 和网页报告以后再做」 | 成立 | `web/src/Results.tsx:660` | |
| PRD 把 XMP 列为待定：`prd-desktop.md:81-84` | 成立 | 同左，XMP 在 :83 | 同一列表里的 eBird（:82）已经做了，PRD 过时 |
| 评星基准是主人在 Lightroom 里的留片 | 成立 | `docs/stars.md:42,74` | |
| `-Enhanced-NR` 等衍生 DNG 并到原 RAW：`decode.py:65-92` | 成立 | `engine/birdcm/decode.py:63-92`（注释从 63 起） | |
| 首页文案「不上传，也不改动原片」：`main.tsx:87` | 成立 | `web/src/main.tsx:87`；`README.md:18` 也有 | |
| SP 写 XMP/EXIF 星级给 Lightroom | 成立 | SP `README_zh.md:47,87`；`ChangeLog.md:47-51` | 写的还有标题（鸟种）、描述、精选旗标、颜色标签 |

## R2 手动改星级

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 整批改留片比例 `PUT /api/scans/{id}/ratio`：`app.py:449-471` | 部分成立 | `engine/birdcm/app.py:449-468` | 行号漂移，469 往后是 `photo_file` |
| 单张星级改不了 | 成立 | `app.py` 的 PUT/POST 接口里没有设星级的；`stars.py:356-373` 的 `manual` 只管鸟种 | |
| 鸟种更正按路径、大小、修改时间持久化：`store.py:32-34` | 成立 | `engine/birdcm/store.py:32-34`（主键 path, size, mtime_ns） | |
| 方向键和回车：`Results.tsx:627-635` | 成立 | `web/src/Results.tsx:627-635` | |
| 改留片比例不重扫 | 成立 | `engine/birdcm/queue.py:196-202` | |
| SP 能手动改星 | 成立 | SP `RELEASE_NOTES.md:34`（结果浏览器内评星）；`ChangeLog.md:3-8`（RC6），`:105`（批量改星） | |

## R3 看片：缩放、对比、多选

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 大图只能左右换张：`Results.tsx:648-654` | 成立 | `web/src/Results.tsx:648-653` | 上下键也能换张 |
| 不能缩放，没有并排对比 | 成立 | `web/src/` 里大图没有 zoom/wheel 一类的处理 | |
| 选中状态只有一个 id：`Results.tsx:315` | 成立 | `web/src/Results.tsx:315`（`useState<number \| null>`） | |
| 眼、喙、鸟框坐标结果里已有 | 成立 | `engine/birdcm/pipeline.py:423-429` | |
| 解码帧长边 2048：`decode.py:24` | 成立 | `engine/birdcm/decode.py:24`（`FRAME = 2048`） | |
| 验收：6000 万像素 ARW 的 100% 等待时间 | 无法确认 | `docs/perf.md:25`：主人用的是 α7 IV 33 MP | 不算事实陈述，但主人没有 60 MP 样片，要另找或改成 33 MP |
| SP 有 100% 缩放、两张对比、多选 | 成立 | SP `ChangeLog.md:141-142`（100%）；`RELEASE_NOTES.md:32`、`README_zh.md:45`（对比）；`ChangeLog.md:9-16`（框选、Shift 多选） | |

## R4 放出四个未发布文件

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 四个文件 `released = false`，行 57 / 67 / 85 / 95 | 成立 | `models.toml:57,67,85,95` | |
| 网址返回 404 | 成立 | `curl -I` 四个网址（`models.toml:59,69,87,98`）都是 404 | |
| 缺 clear：每个检测框都当鸟，淘汰只剩「没有框」一种 | 成立 | `engine/birdcm/models.py:70`；`pipeline.py:431,450` | |
| 缺美学：按中性 0.5 计，3★ 的美学条件视为满足 | 成立 | `engine/birdcm/stars.py:613`（缺失信号取 0.5），`:679`（缺失时百分位按 1.0，过 aes3） | |
| 缺 `rarity-us-ca-cn`：显示「数据不足」，稀有加分不触发 | 成立 | `models.py:73`；`stars.py:615-616`（tier 为 None 时加分 0） | 前提是 rarity-global 也没装；`rarity.py:241-243` 先用 global |
| 缺 `rarity-global`：「同上」，鸟价值分也依赖它 | 部分成立 | `models.py:74`：后果是美、加、中以外数据不足；`value.py:70-98` 读已装的稀有度表 | 后果不是「同上」。`value.py` 在 HEAD 上只有 `engine/tests/test_value.py` 调用 |
| 别人下载到的发布版比主人本机少四样 | 部分成立 | macOS dmg 成立；`NOTICE.md:41-43,47-48,66-67`：iOS ipa 已内置 clear 线性参数和 `rarity-global.sqlite` | iOS 已经在分发其中两样，主人定许可时可以参考 |
| 美学头的训练图片许可没查清 | 成立 | `NOTICE.md:12` | |
| 其余三个只写「尚未发布」、没写原因；美学头是唯一写明原因的 | 部分成立 | `README.md:65`：清晰度门槛、美学头、稀有度表都是「数据许可还在确认」；`NOTICE.md:11`（clear：CC BY / CC0，没有非商用限制）、`:16`（us-ca-cn 没提发布状态）、`:18`（global 写了 not released yet） | 「尚未发布」字样在 `models.toml` 的注释里。按 NOTICE，clear 的许可看起来是清楚的 |
| `eval.md:146-147` 是带「清楚的鸟」判断测的 | 成立 | `docs/eval.md:146-147` | `:148` 写的是也没有地区先验，所以和现在的流水线也不是同一口径 |
| `macos/README.md:36` 写「三个文件未发布」 | 成立 | `macos/README.md:36` | 实际是四个 |
| `birdcm models status` 存在 | 成立 | `engine/birdcm/cli.py:14` | |

## R5 曝光检测

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| `exposure_malus` 字段在，但从不生效：`stars.py:17,84` | 成立 | `engine/birdcm/stars.py:17,84,135`：只有定义和 validate 列表，计算里没有引用 | 字段在 quota 段（:84）；默认的 select 策略里没有曝光项，要新加 |
| `docs/deviations.md:57` | 成立 | 同左 | |
| `engine/bench/burst_study`、`engine/bench/stars_bench` | 成立 | `engine/bench/burst_study.py`、`stars_bench.py` | 两个是 `.py` 文件，不是目录 |
| SP 有曝光检测 | 部分成立 | SP `RELEASE_NOTES.md:31`（按曝光筛选）；`docs/MODEL_REPLICATION_REPORT.md:26`（有曝光分析）；`:316`（曝光降星被写死关闭） | 那份文档没有写日期，可能过时 |

## R6 更多 RAW 格式和对焦点品牌

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 扫描只认 `.arw/.dng/.jpg/.jpeg`：`decode.py:22-23` | 成立 | `engine/birdcm/decode.py:22-23` | |
| 对焦点只读 Sony `FocusLocation`：`geometry.py:15` | 成立 | `engine/birdcm/geometry.py:14-15`；`decode.py:190` 只请求 `-FocusLocation#` | |
| 竖拍没在真实照片上验证：`deviations.md:34` | 成立 | `docs/deviations.md:34` | |
| `docs/fixtures` 存在 | 成立 | `docs/fixtures/lifelist` | |
| SP 支持多品牌 RAW | 成立 | SP `ChangeLog.md:639-640`（NEF、CR2、CR3、ARW、RAF、ORF、RW2、PEF、3FR、IIQ）；`RELEASE_NOTES.md:36-37`（HEIF，仅 macOS） | |
| SP 读多品牌对焦点 | 成立 | SP `docs/MODEL_REPLICATION_REPORT.md:222-224`（Nikon、Sony、Canon、Olympus、Fujifilm、Panasonic）；`README_zh.md:41` | |

## R7 公证和更新检查

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| dmg 只有 ad-hoc 签名，没有 Developer ID 和公证：`release.md:119` | 成立 | `docs/release.md:119` | |
| 用户要手动「仍要打开」或执行 `xattr` | 成立 | `.github/release-notes.sh:21` | |
| 没有任何更新检查 | 成立 | `engine/`、`macos/Sources`、`web/src`、`ios/BirdCM` 里没有相关代码 | |
| 只支持 Apple Silicon 和 macOS 15+ | 成立 | `macos/Info.plist:14`；`docs/release.md:122` | |
| 文件夹选择用 osascript：`app.py:349-355` | 成立 | `engine/birdcm/app.py:349-355`（:353） | |
| README 有「联网」一节，每一项都可以关 | 成立 | `README.md:48-57` | |
| SP 有签名公证 | 无法确认 | SP 文档里没有公证、notarize、Developer ID 字样；`ls` 只看到 `entitlements.plist` | |
| SP 有更新检查 | 部分成立 | SP `ChangeLog.md:1219-1221` | 只在「关于」页有个手动按钮，后台不检查 |
| SP 有 Windows 和 Intel 包 | 成立 | SP `README_zh.md:58-64` | |

## R8 英文界面

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 网页只有简体中文：`web/index.html:2` | 成立 | `web/index.html:2`（`lang="zh-CN"`） | |
| iOS `Localizable.xcstrings` 只有 zh-Hans | 成立 | `ios/BirdCM/Resources/Localizable.xcstrings`：源语言和全部本地化都只有 zh-Hans | |
| macOS 菜单栏只有中文 | 成立 | `macos/Sources/main.swift` 里中文是硬编码，没有本地化调用 | |
| 鸟名中、英、学名三种都显示 | 成立 | `README.md:25`；`web/src/names.tsx:5,13` | |
| 星级理由的中文句子在 `stars.py:618-699` | 部分成立 | select 策略的理由在 `stars.py:654-699`（中文在 660-698）；quota 策略和淘汰理由在 `:403-465`；`pipeline.py:450` | 引擎生成的中文还有：API 报错（如 `app.py:346,352,467`）、`models.py:67-74`、`rarity.py` 的「数据不足 / 无记录 / 未知」。要让 R8 的验收成立，这些也得列进去 |
| 繁体中文名数据已有：`zh-names.csv` | 成立 | `engine/birdcm/data/zh-names.csv` 有 `zh_hant` 列 | |
| SP 有多语言界面 | 成立 | SP `ls locales`：`en_US.json`、`zh_CN.json`、`zh_TW.json`；`ChangeLog.md:236` | |

## R9 网页端测试和推送时的 CI

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| `web/` 没有测试 | 成立 | `web/` 下没有 `*.test.*`、`*.spec.*` | |
| `package.json` 只有类型检查和对比度脚本 | 部分成立 | `web/package.json`：dev、build、typecheck、contrast | 另有 dev 和 build，没有 test |
| CI 只有 `release.yml`，只在 `release/v*` 标签或手动时跑 | 成立 | `.github/workflows/` 里只有 `release.yml`；`release.yml:6-9` | |
| 引擎有 25 个测试文件 | 成立 | `engine/tests` 下 25 个 `test_*.py` | |
| iOS 有单元测试和 UI 测试 | 成立 | `ios/Tests`（11 个）、`ios/UITests`（8 个） | |

## B1 美学权重定义了两次

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| `w_aes` 在第 49 行是 0.15，第 74 行是 0.35 | 成立 | `engine/birdcm/stars.py:49,74` | |
| 后面的生效，默认值是 0.35 | 成立 | 实测 `Config().w_aes == 0.35` | |
| 和 `docs/stars.md` 不一致 | 成立 | `docs/stars.md:15`（0.15） | |
| 49 行属于 select，74 行属于 quota | 成立 | `stars.py:42`（`# ---- select ----`）、`:70`（`# ---- quota ----`） | |
| 基准数字都是在 0.35 下测的 | 成立 | `engine/bench/stars_bench.py` 没有覆盖 `w_aes`；`from_ratio`（`stars.py:91-106`）只按扫描设置覆盖 | Q 按总权重归一（`stars.py:612`），实际占比约 0.35/1.25 ≈ 28%，文档值是 0.15/1.05 ≈ 14% |

## B2 文档之间互相矛盾

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| `release.md:61,125` 写「iOS 版不分发」，README 和实际 release 都提供未签名 ipa | 部分成立 | 矛盾属实：`docs/release.md:62,125`；`README.md:32`；release v0.0.2 有 `GuanYu-0.0.2-iOS-unsigned.ipa` | 行号 61 应为 62（61 是句首）。`release.md:36-44` 自己就写了上传 ipa，同一文件前后矛盾 |
| 公开包是否含 IUCN：`release.md:47` 说带，`release-notes.sh:24` 说不含 | 成立 | `docs/release.md:47`；`.github/release-notes.sh:24`（英文版在 :32） | 两处说的都是 iOS 包 |
| 未发布文件数（见 R4） | 成立 | `macos/README.md:36` | |
| `bird-value.md:24` 写「没有」国家重点保护名录 | 成立 | `docs/bird-value.md:24` | |
| 工作区里未提交的 `value.py` 和 `cn_protected_birds.tsv` 已经在用 | 无法确认 | 只看了会话开始时主目录的 git status（`M engine/birdcm/value.py`，`?? engine/birdcm/data/cn_protected_birds.tsv`）；干净 checkout 里没有这两样 | 按约定没有读主目录文件。文件存在属实，是否「已经在用」没有核对 |

## 明确不做

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| SP 移动原片、按星级分目录 | 成立 | SP `README_zh.md:46,88`（「鸟种 → 星级」文件夹，可重置） | |
| SP 重命名原片 | 无法确认 | SP 文档里没有；`ChangeLog.md:629` 在另一个场景里写了 nothing is renamed on disk | 建议删掉「重命名」 |
| SP 有使用统计 | 成立 | SP `ChangeLog.md:1212-1215`（4.6.0，匿名、可关）；`docs/plans/2026-08-21-usage-analytics.md`；`ls` 有 `app_user_stat` | |
| 观羽没有遥测 | 成立 | `engine/`、`web/src`、`macos/Sources` 里没有相关代码；`README.md:48-57` | |
| SP 的视频处理和多文件夹只放在默认关闭的实验功能里 | 部分成立 | SP `ChangeLog.md:101-104`、`README_zh.md:48`：两者都在实验室 | 明说默认隐藏的只有报告和 eBird；视频是「原来开着的保持开启」，默认值没写 |
| 组内挑最佳两边都接近随机：`prd-desktop.md:104`、`stars.md:222` | 成立 | `docs/prd-desktop.md:104`；`docs/stars.md:222` | 慧眼选鸟「接近随机」是观羽自己测的，SP 文档里看不到。SP 确实有连拍封面和最佳帧（SP `ChangeLog.md:54,151`） |

## 观羽已经领先、别改坏的地方

| 陈述 | 结论 | 证据 | 备注 |
|---|---|---|---|
| 按拍摄地点和季节修正鸟种（离线） | 成立 | `engine/birdcm/pipeline.py:366`（GPS 或区域，加拍摄周）；本地 BirdNET 模型 `models.toml:74-77` | SP 也按所选国家和区域限定鸟种（SP `README_zh.md:42`），领先的是季节和逐张 GPS |
| 认不准时只报到属 | 成立 | `engine/birdcm/result.py:38-42`；`tower.py:26`；`confirm.py:48-50` | |
| 跨扫描的生涯清单、日历、地图 | 成立 | `engine/birdcm/library.py:1,880,900` | |
| eBird 导出默认可用，两端输出一致 | 成立 | `app.py:551,560,1048`；`ios/BirdCM/EBird.swift:3-4`（同一 fixture 上逐字节一致）；`engine/tests/test_ebird.py` | SP 的 eBird 导出要在实验室里打开（SP `ChangeLog.md:101-102`） |
| 批处理 | 成立 | `engine/birdcm/queue.py` | |
| 结果指纹 | 成立 | `engine/birdcm/pipeline.py:52` | |
| 改留片比例不重扫 | 成立 | `engine/birdcm/queue.py:196-202` | |
| 无遥测 | 成立 | 同上 | |
