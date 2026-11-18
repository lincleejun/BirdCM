# Round 4 验证记录 · 2026-11-18

branch `ios`，本 worktree，改动未提交；清单 `ROUND4_FILES.txt`。Round 3 reviewer 的 32 张截图与 `build-uitest3-18pro.log` 已检查，真实鹰/雪鹭截图作为既有基线保留。只使用有 CC0 清单的测试照片、夹具衍生图与新生成的合成大图；未读取所有者照片。

## 本轮实际运行

| 检查 | 结果与证据 |
|---|---|
| Simulator build-for-testing | **成功**；`build-round4-simulator.log`，Debug，generic iOS Simulator，包含全部 unit/UI 测试编译 |
| Release device build | **成功**；`build-round4-device.log`，generic iOS，`CODE_SIGNING_ALLOWED=NO` |
| 共享生产逻辑 macOS XCTest | **27/27 通过**；`tools/check_native.sh`、`build-round4-native.log`，原有 19 项 + 8 项 DisplayCropTests；不是 iOS runtime 测试 |
| 显示几何 | 对称 18% 留白、三种比例的最小新增面积、边缘平移、微小鸟扩至 600、源图不足时不放大、重复检测去除、首选及余下排序 |
| 像素/方向 | 八种 EXIF 方向的源区域 → JPEG 输出与 RGB 参考逐像素比较；8000 像素图坐标正反变换、眼/嘴坐标；模型正方形既有测试保留 |
| 历史 | 鸟 1 缩略图的区域和像素尺寸；displayCrops JSON 往返；永久文件仍只有原始文件和 JSON，无额外图 |
| 文件导出 | JPEG 拍摄日期/时区/GPS/IPTC caption；PNG 拍摄日期/GPS、真实 alpha 像素值约 128/255，输出尺寸不放大 |
| 大图 | 实际生成 8000×6000 JPEG，裁出 600 像素窗口、核对显示及保存尺寸，并采样 footprint；测试照片生成在采样前完成，不与应用裁图混算 |
| 对比度 | 桌面同源松绿、暖纸、琥珀与浅深背景的文字、按钮、badge 配对均通过 ≥4.5:1 |
| Bundle | Release 内 22 项资源逐文件 SHA256 验证；模型仍在包内；新增 add-only 描述与 build=4；未含 CC0 UI 夹具照片 |
| diff | `git diff --check` 通过 |

合成 JPEG 测试的采样峰值与 JSON 示例会打印在 native 日志末尾。20 ms 采样可能漏掉瞬时峰值，不能用它证明所有 HEIC 解码器也具有同样内存曲线；测试同时从结构上限制返回裁图尺寸，不创建全分辨率 UIImage/RGB，也不同时缓存六张源尺寸裁图。真实 Vision 的空白图回退测试仅在 iOS target 编译运行；macOS 不将一个空实现算作测试通过。

## 四个失败流程：改了 app 还是测试

| Round 3 失败 | 原因证据与本轮修复 |
|---|---|
| About / licences，Flows.swift:114 | **测试 + app 导航可访问性**。日志 10.87s `back()` 实际命中底层 `home.more`，hit point {-1,-1}，根本没返回许可证上一层。ResourceText 加明确 `resource.back`，测试点它；通用查找优先当前可点击元素，返回也只找可见导航按钮。 |
| GPS / home，home.diagnostics 不存在 | **测试**。日志 19.82s 也点中不可见 `home.more`，菜单没展开便查 diagnostics。helper 限定可点击项，并先等菜单项出现。Debug 诊断功能仍在，Release 仍不显示它。 |
| Alaska 行不可达 | **app + 测试**。行标识曾拼接中文显示文字；现使用 `place.region.US-AK` / `US-CA`，最近地点也使用稳定代码。输入后处理键盘教练弹窗，先滚到行再点；正常 reveal 最多六次手势。 |
| 多鸟候选详情，213 秒 | **app + 测试**。日志先成功打开 normal 详情；切鸟后再次点候选，32.51s 开始等 `candidate.details` 至 212.69s（整整 180s）。旧 sheet Binding 每次 get 都造新 UUID，改为稳定的 `@State CandidateSheet?`，只在点候选时创建 ID；测试普通结果等待限 10s，六状态拆独立流程，避免同一用例挂数分钟。未能在此环境重现 UI，修复效果仍需指定模拟器验收。 |

键盘 swipe typing 教练弹窗在截图前及键入后由 helper 点 Continue/继续（含 SpringBoard），不污染正式产品逻辑。测试不会通过关闭键盘功能来掩盖地图确认可见性问题；产品本身用 FocusState 在搜索按钮/submit 时收键盘。

## 新 UI 覆盖（已编译，未运行）

- 单鸟：鸟 1 / 原图；多鸟：photo-1 的两只鹈鹕区域，第二只选择状态、原图点框回页；无鸟画框后出现鸟 1。
- 去背景：接受有效蒙版或明确 noMask 回退，后者断言开关消失；保存：重置 Photos 权限、驱动系统授权、等“已保存”；分享：等系统分享动作并截图。
- `testRealInferenceEagle` 与 `testRealInferenceEgret`：分别用 CC0 photo-0 / photo-3，**没有 fixtureState、没有 -modelDir**，默认加载安装包内模型，断言“白头海雕 / 雪鹭”并生成 real-inference 截图。加载与真实识别各限 45 秒；普通菜单/详情用 5–10 秒。
- 历史测试用 Debug 参数一次播种八条，验证过滤、排序、删除、清空，避免反复八次识别/导航延长用例。

## 此环境无法完成

实际尝试了 `BirdCM 18 Pro` 和 `BirdCM 15` 的 unit + UI test-without-building，两者均未执行：CoreSimulatorService connection invalid / simdiskimaged 不可达，目的地只有 generic placeholder。日志 `build-round4-test-18pro.log` 与 `build-round4-test-15.log`，指定 destination-timeout=5；没有生成 round 4 新截图，也没有把 round 3 的 21/21 或 6/10 算成本轮成绩。

另外尝试 macOS 的 CoreCheck 真实模型回归（含本轮为 macOS 新编译的三个模型）；此宿主在 Engine 加载时报 IOSurfaceSharedEvent 创建失败并以 133 退出，尚未进入识别，见 `build-round4-core.log` / `build-round4-core-compile.log`。不能声称本轮 5/5 真实推理已通过。图像分类裁剪和分类模型文件未改，检测排序/去重的预期行为有独立几何测试，仍需 reviewer 跑 bundle 的 PipelineTests 与两个真实 UI 流程。

未签名、未安装、未访问所有者 iPhone。仍需在 iPhone 15 测去背景的细腿/羽缘、48 MP HEIC 峰值、最大字体的实际布局、系统相册权限与分享面板；Apple Vision 蒙版并非精细羽毛抠图保证。

## 尺寸与永久存储

最终构建尺寸记录在 `build/round4-sizes.json`。`dist/BirdCM-round4-unsigned.ipa` 仅是 Payload 结构正确的无签名测量 ZIP，不是可安装/分发的签名包。模型数量和数据文件没有增加。

| 最终产物 | Bytes | MiB |
|---|---:|---:|
| Release BirdCM.app（无签名） | 731,951,228 | 698.04 |
| 其中 Models | 724,933,415 | 691.35 |
| BirdCM-round4-unsigned.ipa | 642,781,778 | 613.00 |

一条永久历史 = 原始字节 + JSON。测试中含 11,172 类完整缓存的一鸟示例 JSON 为 **492,086 bytes**，配 photo-0 的 11,843 bytes 原图共 **503,929 bytes（约 0.48 MiB）**；这不是所有照片的固定大小。一个显示矩形示例为 23 bytes，实际长小数通常几十字节；新增只存矩形，不存裁图。多鸟的已识别概率缓存会让 JSON 增长，这沿用 round 3；大 JPEG/HEIC 的主要空间仍是原始照片。分享临时文件独立放 tmp，保存完成即清理其临时文件。

## Reviewer 命令

从仓库根目录运行，完整可复制的编译、两台设备 unit+UI（带每台截图目录）及免费团队设备安装命令见 [README.md](README.md)。测试结果包不可覆盖，重跑请换名字或先移走旧 `.xcresult`。本轮没有改 fetch/签名/安装脚本，沿用已验证的流程与 team 3U353L39GB；只有 reviewer 授权并连接的本机执行才会真正签名安装。
