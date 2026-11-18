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

指定的 iOS 27.0 模拟器上完整跑 unit + UI，并输出每台设备独立截图：

```sh
for device in 'BirdCM 18 Pro' 'BirdCM 15'; do
  slug=$(printf '%s' "$device" | tr ' ' '-')
  shots="$PWD/ios/screenshots/round4-$slug"
  mkdir -p "$shots"
  TEST_RUNNER_SCREENSHOT_DIR="$shots" \
  xcodebuild -project ios/BirdCM.xcodeproj -scheme BirdCM -configuration Debug \
    -destination "platform=iOS Simulator,name=$device,OS=27.0" \
    -derivedDataPath ios/DerivedData -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
    -resultBundlePath "ios/build/round4-$slug.xcresult" \
    OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
    -only-testing:BirdCMTests -only-testing:BirdCMUITests test
 done
```

再次执行需换 resultBundlePath（Xcode 不覆盖现有 xcresult）。测试会生成来源明确的 UI 夹具截图，以及 `testRealInferenceEagle` / `testRealInferenceEgret` 的真实推理截图；这两项没有 `-modelDir`，会加载 App 内模型。每个普通等待最多 10 秒，真实模型加载/识别各最多 45 秒，失败立即结束当前测试。多状态与真实推理拆成独立测试，便于直接定位失败。

如果只需要逻辑测试可用 `-only-testing:BirdCMTests`，只截图用 `-only-testing:BirdCMUITests`。真实模型测试默认使用 App 内资源；可选 `TEST_RUNNER_MODELDIR` / `TEST_RUNNER_GEOMODEL` 覆盖。UI fixtures 是 Debug-only，入口在“更多 → 诊断”，不是首页；多鸟夹具使用 photo-1 的两只鹈鹕，历史过滤测试用 `-historyFixtureCount 8` 一次播种八条。`locationFixture=allowed|denied` 用于确定性测试；另有真正系统权限弹窗流程。普通 pick helper 只等待最终结果，不等待短暂的识别中状态；加载截图使用固定 loading 状态。

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

结果顶部为“鸟 1 / 鸟 2 / … / 原图”的横向分页，带页点及小缩略图；点原图上的框可返回那只鸟。没有鸟时在原图上画框，手动结果成为鸟 1；最多六张鸟图，其余数量标在原图。名称后立即展示本地稀有度、IUCN 与需核对的提示。首页地点有真实按钮，设好后折叠；历史八条起提供搜索排序。

展示裁图使用原始文件、EXIF 八方向转正、35% 对称留白和最少新增面积的 1:1 / 4:5 / 3:2；小鸟最多再放宽到 1.5 倍并提示“鸟很小”。模型仍使用独立的桌面补色正方形分类裁剪。完整规则与桌面同源颜色 token 见 [DESIGN.md](DESIGN.md)。

每只鸟可按需打开 Apple Vision 去背景；失败隐藏开关，矩形图一直可用。去背景可能剪掉细腿和羽缘，请核对。点保存才请求添加照片权限；JPEG / 透明 PNG 都用源裁图尺寸，保留原照片拍摄日期、GPS，写物种 caption。分享使用 ShareLink 异步生成源尺寸文件；原图页没有保存/分享动作。

历史只存原始文件与 JSON 中的裁图矩形，缩略图按鸟 1 重新生成，不增加永久大图。区域先由 ImageIO 延迟 provider 裁下，再按方向渲染；原图缩略图用 ImageIO thumbnail API。测试包括 48 MP 合成 JPEG、八方向像素、坐标往返、重复框、历史与保存元数据，测试结果及未运行项目见 [VALIDATION.md](VALIDATION.md)。本轮改动保持未提交，清单见 [ROUND4_FILES.txt](ROUND4_FILES.txt)。
