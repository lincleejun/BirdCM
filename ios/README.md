# 观羽 · BirdCM iOS（Round 4）

SwiftUI / iOS 17+，`cc.outman.birdcm`，无第三方 iOS 运行库。地点现在是首页常驻输入：定位、地图搜索/图钉、离线国家/地区与最近地点。初次识别采用 **照片 GPS > 首页地点 > 无地点**；缺少两者时先提示，也可直接识别。结果显示地点来源和拍摄日期；显式“改地点”可以纠正照片 GPS，并用每只鸟保存的完整视觉分布重排，不重复跑图像模型。旧记录没有缓存时会明确要求重新选片，不偷偷重跑。

所有模型随安装包提供。首次打开只校验/加载，**没有下载、蜂窝开关或模型重下载修复**。完整性损坏提示重新安装。原图、地点、缓存与历史保存在本机；Apple 地图搜索和瓦片需要网络。只用仓库已有的 CC0 验收照片，不使用所有者照片。

设计与颜色实测见 [DESIGN.md](DESIGN.md)，实际执行记录与限制见 [VALIDATION.md](VALIDATION.md)。改动清单见 [ROUND4_FILES.txt](ROUND4_FILES.txt)。

## 获取完整资源

在仓库根目录执行；以下本地路径是本机现有发布构建，不修改它们。其他机器修改环境变量。只有未发布的全球稀有度表必须由本地路径提供，缺失或 SHA 不符直接失败；公开资源按 `tools/model-assets.json` 中的发布 URL 与固定 SHA 获取。`MODEL_SOURCE` 和 `GEO_SOURCE` 可复用已有、同 SHA 的文件，缺少的公开文件才联网下载。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export MODEL_SOURCE=/Users/outman/workspace/personal/bioclip-bird/mobile/build
export GEO_SOURCE='/Users/outman/Library/Caches/BirdCM/models/BirdNET+_Geomodel_V3.0.4_Global_14K_FP32.onnx'
export RARITY_SOURCE=/Users/outman/workspace/personal/bioclip-bird/release/rarity-global.sqlite
ios/tools/fetch_models.sh
```

`Models/`、下载暂存及编译结果全部被忽略，不加入 Git。脚本用 `xcrun coremlcompiler compile` 编译 BioCLIP/Detector/Heads 为 `.mlmodelc`；工程把整个 `Models` 文件夹作为资源拷入 App。应用启动不会编译或复制模型出 bundle。Xcode 工程已保留；若重新运行 `xcodegen`，`project.yml` 同样包含 Models 和许可证构建步骤。

个人构建默认 `BIRDCM_BUNDLE_IUCN=1`。设为 0 会在 fetch 和 Xcode 的 bundle 构建阶段移除 SQLite 中每个 IUCN 值，并重算校验清单；源表不改动，表结构保留供兼容读取。比如 `BIRDCM_BUNDLE_IUCN=0 xcodebuild ... build`。IUCN 再分发与 BirdNET 两份许可声明的冲突仍待所有者决定；全部文件归属在 About/NOTICE.md。

开发覆盖仍支持 `-modelDir /absolute/compiled-folder`、`-geoPath /absolute/model.onnx`、`-rarityPath /absolute/rarity-global.sqlite`、`-resourceDir /absolute/json-folder`。modelDir 现在需要 `.mlmodelc`，旧 `.mlpackage` 目录请先经过 fetch/compile；`prepare_models.sh MOBILE_BUILD GEO_ONNX GLOBAL_RARITY_SQLITE` 是兼容包装。覆盖只读取外部目录。

## 编译与测试

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project ios/BirdCM.xcodeproj -scheme BirdCM -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build-for-testing
xcodebuild -project ios/BirdCM.xcodeproj -scheme BirdCM -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath ios/DerivedData-device \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
```

`-disable-sandbox` 是本次受限宿主运行 Swift 宏所需参数，不加入 Swift 常设编译选项；正常 reviewer 机器可省略。工程中的脚本沙盒设置用于构建期拷贝/裁剪 SQLite，与该编译器参数不同。

### 测试：只测增量（`changed`），`quick` 与 `full`

日常只跑改动涉及的测试，不要每次全量。能在 Mac 上验证的（引擎、网页、纯逻辑的单元测试）就不要走模拟器；UI 流程只在它是验证这次改动的唯一办法时才跑，看几张相关截图即可，不做整套 UI 流程回归（所有者，2026-11-19：模拟器测试 ROI 低）：

```sh
ios/tools/test.sh           # = changed：只跑覆盖改动文件的测试类，一台模拟器（默认 'BirdCM 18 Pro'）
ios/tools/test.sh quick     # 单元测试 + 外观快照 + 冒烟 UI 流程
ios/tools/test.sh full      # 全部测试，'BirdCM 18 Pro' 与 'BirdCM 15' 同时跑（发版或大改前）
```

`changed` 对 App 源文件只选单元测试和快照，映射里的 UI 流程（`U/`）要加 `UI=1` 才跑；改了 UI 测试文件本身仍跑它的类。`changed` 默认比较未提交的改动（工作区干净时比较上一个提交），`BASE=impl` 等可指定基准；`DRY_RUN=1` 只打印选中的测试。
映射写在 `tools/test.sh` 的 `covers()` 里：改了某个测试文件就跑该文件里的测试类；改了 App 源文件就跑覆盖它的类，例如
`Stats.swift` / `Ledger.swift` / `EBird.swift` → `LargestTypeFlows`、`LargestTypeMoreFlows`、`LayoutFlows`、`Step4Snapshots`、
`AppearanceSnapshots`、`LibraryTests`、`CrossPlatformTests`；`ResultView.swift` 等结果页文件 → `ResultFlows`、`ResultExtraFlows`、
`RecordFlows`、`LayoutFlows`、`AppearanceSnapshots`、`LogicTests`。`App.swift`、`FlowCase.swift`、资源、模型、工程文件和表里没有的
App 文件退回 quick 冒烟集（App.swift 另加启动测试）；只改文档或脚本时不跑测试。新增 App 文件或测试类时顺手补一行映射。注意 xcodebuild 遇到 `-only-testing:BirdCMTests` 与 `-only-testing:BirdCMTests/X` 同时出现时只跑 X，脚本已避免这种组合。

两者都先 `build-for-testing` 一次（增量构建几秒），再对每台模拟器 `test-without-building`，用
`-parallel-testing-enabled YES -parallel-testing-worker-count N` 让 Xcode 自动克隆模拟器、按测试类分发。
环境变量：`DEVICES='名称;名称'` 换模拟器，`WORKERS` 每台模拟器的克隆数（默认见下表），`SKIP_BUILD=1` 跳过构建，
`DERIVED_DATA` 换构建目录，`SLOWEST=n` 另列最慢的 n 个测试和每个测试类的秒数（`tools/xcresult_summary.py` 读结果包）。截图在 `ios/screenshots/<quick|full>-<模拟器>/`（每次运行前清空），
结果包与日志在 `ios/build/<模式>-<模拟器>-<时间>.{xcresult,log}`。等价的手动命令：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project ios/BirdCM.xcodeproj -scheme BirdCM -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
TEST_RUNNER_SCREENSHOT_DIR="$PWD/ios/screenshots/full-BirdCM-15" \
xcodebuild test-without-building -xctestrun ios/DerivedData/Build/Products/*.xctestrun \
  -destination 'platform=iOS Simulator,name=BirdCM 15' \
  -parallel-testing-enabled YES -parallel-testing-worker-count 3 \
  -resultBundlePath ios/build/full-BirdCM-15.xcresult   # 加 -only-testing:BirdCMUITests/ResultFlows 等只跑一部分
```

本机（M4 Max，16 核）实测见下表；不要再让两台模拟器各自串行跑，也不要超过表中的克隆数，CPU 争用会让每个流程都变慢。

| 运行（墙钟时间，同一台机器） | 之前 | 现在 |
|---|---|---|
| 全部测试，一台模拟器（BirdCM 18 Pro B）串行 | 2049 s（34 分钟；UI 2017 s，单元 21 s） | — |
| `quick`：构建 + 单元 + 外观快照 + 6 个冒烟流程，3 / 4 个克隆 | 没有对应命令 | 143 s / 151 s（截图前等待加载之前测得，现在约多 5–10 s） |
| `changed`：只跑改动涉及的类 | — | 视改动而定；例：改 `App.swift` → quick 冒烟集 + 启动测试，58 个测试 317 s（多数花在 `testPerfTenThousandBrowse`） |
| `full`：两台模拟器同时，每台 2 / 3 / 4 个克隆 | 审阅者实测两台同时各约 26–30 分钟 | 809 s / **617–709 s（三次，约 11 分钟）** / 693 s |

`full` 每台 3 个克隆最快（默认）；4 个克隆时 8 台模拟器争 CPU，整体更慢，还出现过一次测试运行器启动被系统拒绝。
`quick` 3 个与 4 个克隆几乎相同，默认 3 个。

**分类**（UI 流程原来都在一个 `Flows` 类里，现按区域拆分；并行按测试类分发，所以长测试各占一类）：
`ResultFlows`（结果页各夹具状态）、`ResultExtraFlows`（GBIF / 范围提示、去背景、保存分享、手动画框）、`PlaceFlows`（地点）、
`RecordFlows`（记录、更正、备份、关于）、`LargestTypeFlows` + `LargestTypeMoreFlows`（最大字号下把原外观矩阵的每个页面真实走一遍：
第 4 步统计 / 日历 / 地图 / 观察记录，eBird / 这里这个月 / 文件夹备份，以及各标签页、物种页、更正与地点弹窗、设置）、
`LayoutFlows`（底栏不遮挡内容）、`EngineFlows`（真实推理、相机注入、一万张、主屏图标）、`LaunchFlows`。
外观矩阵的浅色 / 深色 / 深色 + 最大字号由单元测试 `AppearanceSnapshots`、`Step4Snapshots` 在测试宿主里直接渲染同一批预览夹具
（不重启 App，约 80 秒）；只有私有状态才能打开的弹窗和二级页单独渲染（背后没有标签栏）。

**截图文件名不变**：仍是 `-[Flows <测试方法>]-<名称>.png`，例如 `-[Flows testDarkLargestAndLoading]-result-light.png`
（快照）与 `-[Flows testDarkLargestAndLoading]-result--largestTypeYES.png`（真实 App，最大字号）。

去掉的重复：`testResultNormalCandidatesCollapsed`（断言并入 `testResultNormal`）、`testResultUncertain` 的第二次启动；
外观矩阵在浅色 / 深色下的真实 App 遍历（同样的导航与操作在最大字号下仍完整跑一遍）；文件夹备份“出错 / 关闭”两次启动
改由快照测试用同一个 `backupFolderFixture` 跑真实备份逻辑并截图。

UI 测试模式（`-uiTesting YES`，仅 Debug）关闭 UIKit / SwiftUI 动画；等待一律 0.1 秒轮询（`appears(timeout:)`、`until`），
不用每秒才检查一次的 `waitForExistence` / 谓词 expectation，也不靠等超时来证明某物不存在。并行时 PERF 行受其他克隆影响，
要可比的数字请单独跑 `-only-testing:BirdCMUITests/LaunchFlows -parallel-testing-enabled NO`。

再次执行需换 resultBundlePath（Xcode 不覆盖现有 xcresult；脚本按时间命名）。测试会生成来源明确的 UI 夹具截图，以及 `testRealInferenceEagle` / `testRealInferenceEgret` 的真实推理截图；这两项没有 `-modelDir`，会加载 App 内模型。每个普通等待最多 10 秒，真实模型加载/识别各最多 45 秒，失败立即结束当前测试。多状态与真实推理拆成独立测试，便于直接定位失败。

如果只需要逻辑测试可用 `-only-testing:BirdCMTests`，只截图用 `-only-testing:BirdCMUITests`。真实模型测试默认使用 App 内资源；可选 `TEST_RUNNER_MODELDIR` / `TEST_RUNNER_GEOMODEL` 覆盖。UI fixtures 是 Debug-only，入口在“设置”标签 → 诊断，不是首页；多鸟夹具使用 photo-1 的两只鹈鹕，历史过滤测试用 `-historyFixtureCount 8` 一次播种八条。`locationFixture=allowed|denied` 用于确定性测试；另有真正系统权限弹窗流程。普通 pick helper 只等待最终结果，不等待短暂的识别中状态；加载截图 `loading-preview` 由快照测试按固定 loading 状态渲染。

Mac 共享逻辑与脚本检查（不能替代 iOS 测试）：

```sh
ios/tools/check_native.sh
python3 ios/tools/test_install_script.py
python3 ios/tools/test_model_bundle.py
```

`Screens_Previews` 及 `tools/screenshots.sh` 提供各状态预览；Debug 启动参数 `-previewState normal|home|multiple|uncertain|genus|rare|unknown-prior|no-location|no-bird|loading -previewImage /absolute/CC0.jpg` 可直接进入固定状态。`-darkMode YES` / `-largestType YES` 控制 UI 验收组合。

## 安装到所有者 iPhone 15

先在 Xcode > Settings > Accounts 登录该 Personal Team 的 Apple ID，连接、解锁并信任设备，启用 Developer Mode；用 `xcrun devicectl list devices` 找 UDID。沿用上面的 MODEL_SOURCE/GEO_SOURCE/RARITY_SOURCE 环境变量：

```sh
TEAM_ID=3U353L39GB ios/tools/install_on_device.sh '<device-udid>'
```

脚本依次 fetch/校验/编译 → Release 自动签名 build（允许 provisioning updates/device registration）→ `xcrun devicectl device install app`。也可第二个参数指定 team。免费团队安装后需在 **Settings > General > VPN & Device Management** 信任一次开发者，签名有效期受 Apple 免费团队规则约束。脚本不尝试 App Store 导出或要求账号凭据。

## 与桌面的同步

以只读 `../BirdCM` 的 `geometry.py`、`pipeline.py`、`tower.py`、`confirm.py` 为参考：方形裁剪保留全部鸟框，越界用区域平均色填充；2048 帧上最长边小于 128 px 的框从原始高分辨率 decode 取样。清晰度门控不再抹去物种候选。名字阈值、地点 posterior、当地罕见/此季缺席/地区模型无此鸟的判断与桌面一致。

Python 参考已重新生成：`tools/regenerate_crop_references.py ../BirdCM` 读取桌面 geometry，不修改桌面；它只使用 `Tests/Fixtures/photos.json` 记录的 CC0 图片。全球 `region_at` 对照与覆盖不足夹具由 `tools/make_global_rarity_fixture.py` 生成；正式点→地区只有 `Rarity.regionAt`，不再维护另一套中文边界猜测。选择明确地区时保留 ISO code。


## Round 4：鸟图、保存与分享

结果顶部为“鸟 1 / 鸟 2 / … / 原图”的横向分页，带页点及小缩略图；点原图上的框可返回那只鸟。没有鸟时在原图上画框，手动结果成为鸟 1；最多六张鸟图，其余数量标在原图。名称后立即展示本地稀有度、IUCN 与需核对的提示。首页地点有真实按钮，设好后折叠；搜索和排序现在在“记录 → 照片”里始终可见。

展示裁图使用原始文件、EXIF 八方向转正、35% 对称留白和最少新增面积的 1:1 / 4:5 / 3:2；小鸟最多再放宽到 1.5 倍并提示“鸟很小”。模型仍使用独立的桌面补色正方形分类裁剪。完整规则与桌面同源颜色 token 见 [DESIGN.md](DESIGN.md)。

每只鸟可按需打开 Apple Vision 去背景；失败隐藏开关，矩形图一直可用。去背景可能剪掉细腿和羽缘，请核对。点保存才请求添加照片权限；JPEG / 透明 PNG 都用源裁图尺寸，保留原照片拍摄日期、GPS，写物种 caption。分享使用 ShareLink 异步生成源尺寸文件；原图页没有保存/分享动作。

历史只存原始文件与 JSON 中的裁图矩形，缩略图按鸟 1 重新生成，不增加永久大图。区域先由 ImageIO 延迟 provider 裁下，再按方向渲染；原图缩略图用 ImageIO thumbnail API。测试包括 48 MP 合成 JPEG、八方向像素、坐标往返、重复框、历史与保存元数据，测试结果及未运行项目见 [VALIDATION.md](VALIDATION.md)。本轮改动保持未提交，清单见 [ROUND4_FILES.txt](ROUND4_FILES.txt)。

## 记录库与四个标签页（`docs/design-lifelist.md` 第 1–3 步）

历史改存 `Application Support/History/library.sqlite`（系统 SQLite3，无新依赖），原图仍是文件：旧 `<UUID>.photo` 原地不动，新原图写 `assets/<sha256>.photo`。首次启动新版本时在后台把旧 `*.json` 逐条迁入并核对（记录数 + 待修复数 = 文件数、`integrity_check`），完成前显示“正在整理旧记录”、不能改记录；旧 JSON 一律保留，读不了的原样存进 `ll_legacy_issue` 并在“设置 → 备份与恢复”列出。同一字节的照片只算一张（旧的重复记录作为别名保留）。

识别 / 探索 / 记录 / 统计 / 设置 五个标签页各有自己的导航（2026-11-18 所有者：设置做第五个标签，不再有齿轮）。结果页可“更正鸟种”（离线搜索全部 11,172 种）、改数量、排除主体、改日期和地点；名称、GBIF 稀有度、IUCN 都在显示时按当前资源查。统计口径：同一鸟种 × 同一天 × 同一地点格 = 一次观察，估计数量取单张最大值。备份是一个 `.birdcm` SQLite 文件（含原图），通过“文件”导出 / 导入，合并或替换。

Debug 启动参数：`-legacyFixture N`（启动前写一个旧格式历史，测迁移）、`-maskFixture success|none|unsupported`、`-cameraFixture YES`、`-historyFixtureCount N`（不同字节、日期、鸟种）。与规格的出入见 `docs/deviations.md` 第 43 条起。

应用图标与首页小标识是本项目原创的翠鸟图形（第四轮方案 B，按 Apple 图标网格放大主体）（`BirdCM/Assets.xcassets`，源文件 `design/icon/*.svg`），随项目以 MIT 许可发布。
