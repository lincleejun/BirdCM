> **Owner decision 2026-11-18 (overrides the card rule below):** the CARD size of the name block also shows the second line in full — "other common name · *Latin*" — and may wrap to two lines instead of dropping the common name. Hero and row sizes unchanged.

# 观羽 · 翠鸟视觉润色规范

## v2 changes

2026-11-18 · 本轮只更新 OUT 内的设计稿与规范；仓库没有修改。11 张旧主稿均另存为 `*-v1.jpg`，旧规范与渲染器也保留 `-v1` 副本。

- **名称从三行收为两行**：一个 SpeciesName 组件覆盖结果、物种资料、记录卡、探索行、更正面板、统计列表、web 详情及卡片。首行用当前语言名称；次行灰色的另一通用名与斜体学名，行间仅 2 pt。修复 v1 中学名未斜体的问题。
- **中性色承担层级**：取消大面积奶油／青绿底，改为浅深两套 0–9 中性灰阶；用字重、灰度、间距建立主次，少用框。翠鸟青只用于主动作、选中和焦点；橙胸色只保留于品牌与“新种”数字。普通状态默认以灰色文字呈现。
- **修正内容边界**：个人记录仅来自个人导入／拍摄照片，移除“参考鸟图”卡片，不用图库填空。示意数据同步为 3 种、22 次、29 张；web 改为三张有内容的记录卡。参考图只在探索／百科资料域使用。
- **去背景可直接到达**：手机与 web 均放在裁图下方 action row，作为有文字的次动作；工具入口仍承载其余工具。
- **交付可核查**：重渲染 8 iOS + 3 web，补更正面板、浅深色名称特写和 200% 字号样张；全部逐张目视。对比计算与允许配对详见 `contrast.md`，不再沿用 v1 表格。

## 方向与官方研究

这是面向个人观鸟者的内容界面修订：安静、紧凑、可读，照片与物种身份优先。取 Material 3 的语义角色与类型尺度原则、Geist 的中性层级与克制边界原则，形成观羽自己的 token；没有混装两套组件库，也不复刻其外观。原生 iOS 导航、Form、sheet、权限、相册及地图行为继续保留。

资料于 2026-11-18 阅读。M3 的部分入口仅返回 JavaScript 壳，颜色采用其可索引正文，字体和形状另核对 Google 官方 Material Web 文档；未声称已浏览不可访问的交互演示。下表右列为本次设计判断。

|官方文档|阅读到的原则 → 本次应用|
|---|---|
|[M3 Typography](https://m3.material.io/styles/typography/overview)、[官方 Typography 实现文档](https://material-web.dev/theming/typography/)|类型尺度将 family、size、line-height、weight 按用途组合 → 名称只定义 hero / row / card 三个变体，中文保留系统字体，学名使用同族斜体。|
|[M3 Color roles / tonal surfaces](https://m3.material.io/styles/color/the-color-system/)、[官方 Color 文档](https://material-web.dev/theming/color/)|背景、容器、前景配成角色；中性表面有不同强调层次 → canvas 与 surface-1..3 分工稳定，跨尺寸保持含义；正文采用更严格的 4.5:1 门槛。|
|[M3 Shape](https://m3.material.io/styles/shape/shape-scale-tokens)、[官方 Shape 文档](https://material-web.dev/theming/shape/)|圆角有尺度与用途 → 控件 10、照片 12、hero 16；系统 sheet 继续系统形状，不用圆角堆叠表现层级。|
|[Geist Colors](https://vercel.com/geist/colors)|灰阶按背景、边界、文字分配，实色灰为默认 → 自定义 0–9 灰阶，0–3 表面、4 装饰边、6 必要边、7–9 文字；这不是复制 Geist 原始色值。|
|[Geist Typography](https://vercel.com/geist/typography)|字体样式同时约束大小、行高、字重；数字可用 tabular → 统计数字和日期用等宽数字，不把整段中文变等宽。|
|[Geist Materials](https://vercel.com/geist/materials)|按层级选最低必要浮起程度，不能只靠阴影辨识 → 正文卡无阴影；静止详情面板只用一条安静边界；临时浮层保持原生材料。|
|[Geist Button](https://vercel.com/geist/button)|主动作与 supporting action 分工、文字说明动作、图标需要可访问名称 → 保存为主动作，去背景／分享为次动作；不把去背景藏进菜单。|

## 一个 SpeciesName 组件

输入：`chineseName? / englishName / scientificName / locale / size`。输出是同一语义组，完整读屏值包含所有已知名称；原生用 accessibilityLabel，web 用可访问文本。静态 SVG 仅作为布局交接；产品实现不直接使用 SVG 里的文字组件。

**名称规则（两句话）**：第一行显示用户界面语言的通用名，中文界面优先中文，英文界面或缺中文名时显示英文。第二行显示“另一通用名 · 斜体拉丁学名”，缺另一通用名时省去分隔点，普通字号固定一行，辅助字号最多展开为两行。

|变体|首行 size / line-height / weight|次行 size / line-height / weight|行间 gap|常见位置|
|---|---|---|---:|---|
|hero|28 / 34 / 600|15 / 20 / 400|2|结果、物种、web 详情|
|row|18 / 24 / 600|13 / 18 / 400|2|探索、更正、统计列表|
|card|17 / 22 / 600|13 / 18 / 400|2|个人记录、识别网格、统计照片卡|

全部单位为 iOS pt / web CSS px；不额外加中文 tracking。Latin 为同族 italic，通用名和间隔点 upright；斜体后预留 2 px 横向余量并保留 18–20 行高，不裁斜体尾部。首行 text-primary、次行 text-secondary，绝不把 Latin 单独放第三行。metadata 不属于名称组件，放在组件后 8–12 pt。

### 空间不足的顺序

1. 首行尾部省略，点击卡片可进入有完整名称的详情；不缩字号。
2. 次行先为 Latin 预留宽度，再对另一通用名尾部省略。若另一通用名连两个有效字符都放不下，整段与分隔点一起隐藏，避免“仅省略号＋点”的噪声。
3. Latin 单独仍超过列宽时才尾部省略；不擅自缩写属名、不改变科学名称。详情与读屏始终提供完整值。Latin 优先因为它可跨语言唯一地区分物种；重复的通用名可从首行／详情补足。
4. 辅助字号不缩字：网格转单列、行高自适应、缩略图移到名称上方，第二个逻辑行允许最多两个物理行（因此整体可到三行），学名仍斜体。先完整展示两段；若两行仍不足，按上述优先级省略。辅助字号是“两行”普通模式的明确例外。

`name-block.jpg` 展示浅深色三尺寸、英文 UI、无中文名和窄卡片；`name-block-accessibility.jpg` 展示 200% 字号次行展开；`name-layout-checks.json` 记录渲染实例与宽度。字体度量检查使用 Helvetica Neue，平台最终仍须用真实系统字体、Dynamic Type 和语言包验证。

## 灰阶与语义角色

`tokens.json.grayScale` 为 0–9 编号。浅深模式编号按用途对应，颜色不是简单取反；canvas 在浅色用 1、深色用 0，surface-1 在浅色用 0、深色用 1。`roles` 给出实际 HEX，`roleGraySteps` 给出每模式绑定。

|step|浅色|深色|用途|
|---:|---|---|---|
|0|#FFFFFF|#0A0A0A|最底／最亮基底|
|1|#FAFAFA|#141414|页面或容器|
|2|#F5F5F5|#1F1F1F|输入、hover、低强调容器|
|3|#EBEBEB|#292929|pressed、较明显的中性容器|
|4|#D4D4D4|#3D3D3D|border：装饰边线|
|5|#B5B5B5|#555555|中间灰，仅非文字用途|
|6|#858585|#858585|border-control：必须辨识的控件轮廓|
|7|#666666|#A3A3A3|text-tertiary：计数、日期|
|8|#606060|#B5B5B5|text-secondary：第二名称行、说明|
|9|#171717|#EDEDED|text-primary：标题、首行名称|

浅色次行 #606060 在 canvas / surface-1 / surface-2 / surface-3 分别 **6.025 / 6.289 / 5.768 / 5.275:1**；深色 #B5B5B5 分别 **9.655 / 8.985 / 8.039 / 7.095:1**，全部超过 WCAG AA 正文 4.5:1。即使辅助文字是 13 pt，也不使用大字 3:1 豁免。更弱的灰不可替代这些文字角色。

`accent` 浅 #17646B、深 #76CFD1，`accent-contrast` 浅 #FFFFFF、深 #0A0A0A；按下为更深／更浅同族青。`new-species-highlight` 浅 #854015、深 #FFBC87 是图标橙色的可读派生，只强调新种数字。图标原始青 #3BA5AC、橙 #DE8547、奶油 #F4F1E8、深青 #123D46 保留在品牌图形，不能直接拿来做小字号正文。

border 只用于不依赖边界才能理解的内容分隔，不要求达到 3:1；输入若仅凭轮廓识别，必须用 border-control，focus 用 accent 2 px＋3 px offset。默认／hover／pressed 使用 surface-1／surface-2／surface-3 与同一文字角色；disabled 显式使用 disabledInk / disabledBg，不依赖 opacity。照片上的文字必须先铺不透明 mat，日历日期铺不透明 surface-1，不计算未知照片底色的对比度。

### 稀有度与 IUCN

保留 `rarity.common / uncommon / scarce / rare / noRecord / unavailable`，IUCN `LC / NT / VU / EN / CR / EW / EX / DD / NE`，以及 success / warning / error 的浅深色 fg/bg 配对，全部列入角色表与对比表。一般页面以“本地：常见”“IUCN：无危 LC”中性文字为默认，需显著解释状态时才使用语义色对；不把整张卡片染色。稀有度不是保护级别，必须分列，始终写文字和代码，不靠颜色表达。

## 页面修订与行为交接

结果：鸟图 → 鸟／原图切换 → action row（去背景／显示标记／工具）→ 两行名称 → 本地与 IUCN → 模型匹配／候选 → 日期／更正 → 保存／分享。去背景是最小 44 pt 次动作，保存保持唯一高强调动作；原图模式沿用现有保存能力限制。多鸟与无鸟、属级／不确定结果继续保留原有解释，不用一个高百分比暗示科学确认。

记录：数据源必须是自己的拍摄／导入记录，`source=reference` 永不进入个人网格、日历或相遇列表；代表图只能来自该物种自己的主体，没有照片就留有说明的空态，不向 Explore 借图。本轮删除参考卡而非更名冒充新观察。3 张示意卡片的观察数 8+5+9=22、照片 12+7+10=29。**未提供业主实拍文件，本稿仍沿用上一轮 CC0 fixtures 表示个人导入照片，不能宣称它们是业主实际拍摄。** 真实实现必须绑定个人资料源。

物种：我的观察与参考资料区清楚分开，代表图说明来源；名称与统计先于长篇百科。探索：参考图仅在该资料域，来源与授权在详情可查；名称组件与个人记录完全复用，但图片来源不混用。更正：模型建议、我的判断分组，勾选＋保存更正；恢复模型判断与标为不确定仍可见。

统计：开放式数字＋等宽数字，橙仅用于新种；日历照片来自我的记录，所有日期有不透明衬底，2026-11-01 为周日。下方物种列表和 web 相遇卡同样两行。月历辅助字号改日期列表，保持等价导航与计数说明。未有记录的月份必须写“无记录”，不伪造热力。

web：1440×900；识别主区 3 列、右侧详情 378 px，详情和手机同序。个人记录本稿只有 3 种，因此三列照片，不重复卡片填空。<1180 主区降两列，<980 详情成为抽屉，<640 卡片按最小宽度重排，200% 缩放走同一重排。行与卡片自适应高度，主内容不依赖横向滚动。普通标题 32/38、正文 16/24、说明 14/20；名称一律用共享尺寸表。

其余：系统栏、Form、地图、权限、备份与导出保持原生行为；备份新增／重复／冲突信息不能省略。所有主触区 ≥44 pt，静态图无法证明触区和键盘行为。Reduce Motion 去位移、保留短淡入；不把不定模型准备进度描述成百分比。页面间距继续 4 pt 网格，名称内部 2 pt 是专用紧凑节奏；正文卡无投影。

## 交付与验证

- `ios-01-home`、`ios-02-result`、`ios-03-records`、`ios-04-species`、`ios-05-statistics`、`ios-06-explore`、`ios-07-statistics-dark`、`ios-08-preparing`：8 PNG，各 1206×2622，并有同名 SVG。
- `web-01-results`、`web-02-records`、`web-03-statistics`：3 PNG，各 1440×900，并有同名 SVG。
- `name-block.jpg/svg`：浅深色 hero / row / card，2400×1620；`name-block-accessibility.jpg/svg`：200% 字号，1000×430；`correction-sheet.jpg/svg`：补充更正稿，1206×2622。
- `mockup-overview.jpg`：更新概览；`tokens.json`、`contrast.md`、`qa.md`、`validation.json`、`name-layout-checks.json`：规范与复核证据；`render.py`：可复现渲染器。
- `*-v1.jpg`、`mockup-overview-v1.jpg`、`render-v1.py`、`polish-v1.md`、`tokens-v1.json`、`contrast-v1.md`、`qa-v1.md`：上版存档。

照片沿用原有 CC0 fixtures，拷贝至 OUT/assets 使本稿可独立重渲染；授权依据原 photos.json。照片内已有署名字样保留，不修图或伪造所有权。仅照片构图和信息密度示意，物种数据接入实施时仍需验证；研究截图只留 research。未修改仓库、未运行产品、未声称做过真实 Dynamic Type／VoiceOver／键盘测试。规范中的触区、读屏与重排是实施验收条件。

---

以下为 v1 审视记录，保留问题来源；涉及具体视觉值时以上述 v2 为准。旧版完整研究与对比表保留于 polish-v1.md。

## 02 审视范围与诊断

逐张通看 `ios/screenshots/final/`、`final-18pro/`，以及指定 `shots/` 全部根目录截图；清单见 `audit-index.txt`，缩览见 `audit-01…12.jpg`。相同场景的浅/深色、最大字号也纳入。以下文件名按原始文件写，前缀目录见上文；18 Pro 的新增画面单独列出。截图中的照片仅用于判断已有界面，成稿只使用 fixtures/photos.json 标注的 CC0 图。

|屏幕 / 截图文件|现状诊断|优先修正|
|首页 `-[Flows testDarkLargestAndLoading]-identify-light.jpg`、`identify--darkModeYES.jpg`；`-[Flows testPlaceMapSearchPinAndRecents]-home-empty.jpg` / `home-alaska.jpg`|品牌标记很小，标题、地点卡、最近记录都很轻，视线没有一个明确停点；底部双入口像列表附件。大字号文案挤占整屏。|照片选择是主动作；有最近记录时用一张真实最近鸟图，无记录时用几何小鸟；主按钮随内容排布，位置摘要次级。|
|结果 `-[Flows testDarkLargestAndLoading]-result-light.jpg` / `result--largestTypeYES.jpg`、`-[Flows testRealInferenceEagle]-real-inference-eagle.jpg` / `testRealInferenceEgret` 对应图|鸟图在大片空画布中显小；控制胶囊与缩略图尺寸接近，层级不清；鸟名与重要事实靠下。最大字号时去背景/保存/分享与底栏竞争。|扩大展示图窗，工具移出图像主体；先鸟图、鸟名、当地频次/IUCN，再候选与说明。|
|多鸟 `-[Flows testResultSeveralBirds]-multiple.jpg` / `multiple-original.jpg` / `multiple-candidate.jpg`|分页点与缩略图都弱，原图和当前鸟不够分明；框叠在照片时争夺注意力。|明确“鸟 1 / n”；选中缩略图外框＋文字；原图独立标签，保留完整原图与点框跳页。|
|异常结果 `-[Flows testResultUncertain]-uncertain.jpg`、`-[Flows testResultGenus]-genus.jpg`、`-[Flows testResultUnknownPrior]-unknown-prior.jpg`、`-[Flows testResultRare]-rare.jpg`、`-[Flows testNoBirdManualBox]-no-bird.jpg`|警告、频次、物种不确定的色彩语义容易混为一类；一排胶囊像同一套可信标签。|匹配状态单独一行；属级显示“仅确定到属”；资料缺失不等同罕见；无鸟给手动画框动作。|
|记录鸟种 `-[Flows testDarkLargestAndLoading]-records-species-light.jpg` / `records-species--largestTypeYES.jpg`、`-[Flows testMigrationFromOldStore]-migrated-species.jpg`|普通字号时卡片信息细小，稀少数据时像角落小部件；最大字号列宽与排序控件冲突。|双列开放式摄影卡，统一照片比例；中文名最强，英文次之，次数最弱；辅助字号单列。|
|照片/待确认 `-[Flows testDarkLargestAndLoading]-records-photos-light.jpg` / `records-pending-light.jpg`、`-[Flows testPendingListOpensSubject]-pending.jpg`|搜索、排序的说明占据比记录更多的空间；“全部确认”大白卡像一个阻断状态。|搜索固定可见，排序说明进帮助；待确认显示主体而不是只显示整张照片；完成态用小标记、短句和继续识别入口。|
|物种 `-[Flows testDarkLargestAndLoading]-species-page-light.jpg` / `species-page--darkModeYES-largestTypeYES.jpg`|照片、英文、学名和字段在一条竖轴上同等轻；大字号学名非常醒目，身份信息反而散。|中文名＋英文＋学名成组；观察次数/照片数开放排布；“最近相遇”独立段落。|
|统计 `-[Flows testDarkLargestAndLoading]-stats-light.jpg`、18pro `-[Flows testStep4Screens]-stats-light.jpg` / `calendar-month-light.jpg` / `calendar-year-light.jpg` / `calendar-day-light.jpg`|数值被相同色块平均化，日期范围长；日历小且缩略图变化不够显著，解释文字过密。年图空月像未加载卡片。|大数字不套盒；月日历照片化；年视图空月保留月份和“无记录”；明确定义计数。|
|地图 `-[Flows testStep4Screens]-map-light.jpg` / `map--darkModeYES.jpg`、`-[Flows testPlaceMapSearchPinAndRecents]-map-pin-radius.jpg`|地图和下方解释缺少层级，长说明像调试文本；地图系统标记和品牌样式无须强行统一。|保持原生地图，统计摘要放地图下方；被选地点有文字标签，圆圈仍表示范围。|
|探索 `-[Flows testDarkLargestAndLoading]-explore-light.jpg` / `explore-search--largestTypeYES.jpg`、18pro `-[Flows testStep4Screens]-explore-local-light.jpg`|过滤器/说明占首屏过多；无图条目像数据库目录；将来再加参考图会挤占名称与频次。|首屏搜索＋范围切换＋紧凑地点/月摘要；100 pt 图片槽，名称/摘要/状态分层。|
|更正 `-[Flows testDarkLargestAndLoading]-correction-light.jpg` / `correction--largestTypeYES.jpg`、`-[Flows testCorrectSpeciesCountAndReset]-correction-sheet.jpg`|模型判断、用户更正、搜索结果视觉权重近似；绿色条不容易看出是状态还是操作。|“模型建议”与“我的判断”明确分组；选择项用勾选，提交为唯一主动作；恢复自动为次动作。|
|设置/备份 `-[Flows testDarkLargestAndLoading]-settings-light.jpg` / `backup-light.jpg`、`-[Flows testBackupExportPreviewMerge]-backup-preview.jpg`、18pro `-[Flows testStep4Screens]-backup-folder-ok-light.jpg`|原生分组很好，但纸色和系统灰的切换缺少规则；说明与数字拥挤；危险操作色彩不明确。|保留 Form；内容底面 surface、外底 canvas；统计值右对齐等宽数字；预览突出新增/重复/冲突。|
|加载/空态 `-[Flows testDarkLargestAndLoading]-loading-preview.jpg`、`-[Flows testHistorySearchSortDeleteClear]-photos-empty.jpg` / `history-cleared.jpg`、`-[Flows testCameraUnavailableAndInjectedCapture]-camera-unavailable.jpg`|缺少清楚的阶段名称；空态小线鸟与新图标语汇不同；可操作错误和真正空记录相似。|几何品牌小鸟；每种空态一个解释＋一个相关动作；后台准备用安静状态行。|
|关于/许可/诊断、系统定位授权、eBird 导出、观察编辑|密集说明本就有必要，不能为统一视觉删除事实。|保留系统组件与分节，长文本提高行高；导出选项的条件说明紧贴控件。|

桌面：`L-library.jpg`、`L2-library.jpg`、`L3-library-browser.jpg` 里的照片占位彩色块产生随机彩虹感；这属于测试占位，不代表真实照片应统一调色。`L-library_sci_Ardea_20alba.jpg` / `L2-library_sci_Ardea_20alba.jpg` 的物种层级与网格缺乏共同节奏。`L-stats.jpg` / `L2-stats.jpg`、`cal-L-2026-10.jpg` / `cal-L-year.jpg` 把统计、计数解释、导出/备份全压在一条阅读轴上。`S-*` / `S2-*` 与 `cal-S-*` 验证窄屏后，长条堆叠和横向空间紧张更明显：需要明确重排，不应缩小字号。

