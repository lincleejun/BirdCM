# 鸟种搜索与物种页：本地先行，在线补充

设计稿，2026-11-18；目标：`impl` 的 iOS 探索与桌面 web 记录/探索。本文只提出后续实现，不代表接口、映射、许可审计或离线图包已经完成。

> Owner：「搜索 我想之后会做的复杂点。一个是可能用线上数据搜，另外数据库搜。还要配备图、信息。」

## 1. 推荐方案与现有边界

**一个以 AviList 为身份基准的搜索入口，一张以自己的观察为主体的物种页。** 本地名称、筛选、自己的照片和记录始终立即可用；在线层只补图片、简介、别名和来源链接。联网失败不能使本地结果消失、重新排序或无法更正鸟种。

推荐首发组合：Wikipedia 中/英文简介 + Wikimedia Commons 逐文件许可图片；Wikidata 负责跨站 ID/文章链接；GBIF 负责构建期分类核验、可授权的别名与分布补充。iNaturalist 是后续图片备选，不是首屏必需的第三个网络依赖。默认从一开始拒绝 NC 图片，避免未来收费时更换整个图库。

读过的现有契约：

- [design-lifelist.md §6.2](design-lifelist.md#62-search-and-local-likelihood)：11,172 种、本地三名搜索、精确 > 前缀 > 子串、150 ms debounce、50 条分页，以及独立于网络的地点/月度可能性排序。拼音是该设计的要求，不应把它误报为两个平台都已实现。
- [Records.swift](../ios/BirdCM/Records.swift)：物种页已有三名、科属、可关闭的 IUCN、自己的观察/照片/月度记录；已有个人照片不应被参考图替换。[Editors.swift](../ios/BirdCM/Editors.swift) 的更正搜索必须保持离线、显式保存，网上点中一个结果不能自动改记录。
- [names.py](../engine/birdcm/names.py)：现实现从模型名称包加载 catalogue，缺包返回空；搜索三名子串并分级排序。本功能必须额外随应用提供轻量名称名录，使「搜索永远可用」不依赖模型权重安装。
- [Library.tsx](../web/src/Library.tsx)：记录页默认已见、可切全部物种，150 ms 搜索、60 条分页；物种页用自己的照片，现有 Wikipedia/eBird 外链。web 可保留 60 条页面大小，语义与 iOS 50 条相同。
- [NOTICE.md](../NOTICE.md)：代码 MIT；AviList、IOC 中文名、Cornell 名称映射、GBIF/IUCN 与模型各自有独立许可。新增内容不因放入 MIT 应用而变为 MIT。IUCN 再分发与部分现有模型的商业限制仍未解决。

本文有意扩展旧物种页「仅自己的照片、在线只外链」的范围：探索和物种知识页可显示清楚标注的参考图；记录页自己的照片网格、日历、个人统计仍只使用自己的证据。不会加入鸟声、识图服务上传、近期公开目击、社交账号或云同步。

## 2. 来源核查与准入

以下来自 2026-11-18 的联网核查。数值是来源当日政策，不是 SLA；实现前再检查。没有找到公开 API/条款与明确禁止是两种结论，不能混写。各适配器要记录核查日期和政策 URL。

### 2.1 Wikipedia / Wikidata / Commons

| 来源 | API 与速率依据 | 内容许可、产品决定 |
|---|---|---|
| Wikipedia | [Page Content Service](https://www.mediawiki.org/wiki/Page_Content_Service) 文档列出 `https://{zh,en}.wikipedia.org/api/rest_v1/page/summary/{title}`；[英文实测](https://en.wikipedia.org/api/rest_v1/page/summary/Passer_domesticus) 返回摘要、QID、revision、文章/历史 URL。中文 endpoint 本次研究环境未成功实测，不宣称已验证可用。必要时用同源 [TextExtracts Action API](https://www.mediawiki.org/wiki/Extension:TextExtracts#API)，`action=query&prop=extracts&exintro=1&explaintext=1`。 | [Wikimedia 使用条款 §7](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use/en#7._Licensing_of_Content)：按页面适用许可复用，通常 CC BY-SA 4.0，保留额外署名。显示短原文摘录、文章/历史链接、贡献者、准确许可与改动说明；不自行生成或翻译百科事实。摘要返回的 thumbnail 不是图片许可证明。 |
| Wikidata | [Data access](https://www.wikidata.org/wiki/Wikidata:Data_access)、[Wikibase API](https://www.mediawiki.org/wiki/Wikibase/API/en)：构建时 `wbgetentities` 读取 claims、`sitelinks/urls`，`sitefilter=zhwiki|enwiki`。用 sitelink 确定文章，不把中文鸟名拼成文章标题。 | [结构化数据 CC0](https://www.wikidata.org/wiki/Wikidata:Licensing)，保留 QID、来源 revision 与检索日期作为溯源。允许离线映射；Wikidata 条目说明不是 Wikipedia 文章，不能混用许可。 |
| Wikimedia Commons | [Imageinfo](https://www.mediawiki.org/wiki/API:Imageinfo)：`action=query&prop=imageinfo&iiprop=url|extmetadata|sha1|timestamp&iiurlwidth=640&titles=File:…`，每次少量文件。[CommonsMetadata](https://www.mediawiki.org/wiki/Extension:CommonsMetadata#Returned_data) 的 `Artist/Credit/Attribution/LicenseShortName/LicenseUrl/UsageTerms/Restrictions/NonFree/DeletionReason` 等用于审核。 | [站外复用指南](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia)：许可逐文件判定，可按合规许可下载复用。首发只显示/缓存审核通过的 CC0、明确公有领域、CC BY、CC BY-SA；多许可选一条适用许可并记录。不接受「来自 Commons」作为通用版权声明。 |

三者运行时共用 Wikimedia 请求队列。[当前速率页](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits) 说明 2026 新限额按分钟、跨站计：仅 IP 未识别 10，合规 User-Agent 的匿名客户端 200，匿名浏览器 200；并发建议不超过 3。使用带真实项目联系 URL 的 UA，遵守 429/503 的 Retry-After；无该头时至少等 5 秒或指数退避。[API 使用政策](https://foundation.wikimedia.org/wiki/Policy:Wikimedia_Foundation_API_Usage_Guidelines/en) 同时适用。BirdCM 自限每安装 30 次/分钟、并发 2，不把 200 当可持续消费目标；共享出口仍可能先被限制。

[RESTBase 弃用](https://www.mediawiki.org/wiki/RESTBase/deprecation) 不等于已宣布 summary endpoint 删除；通过摘要适配器隔离变化，不能硬编码「永久稳定」。[旧 API Portal 弃用说明](https://wikitech.wikimedia.org/wiki/API_Portal/Deprecation) 下的历史每小时额度不是本设计依据。

构建期若用 SPARQL，[WDQS 限制](https://www.mediawiki.org/wiki/Wikidata_Query_Service/User_Manual#Query_limits) 为单查询 60 秒、每 UA+IP 每 60 秒最多 60 秒处理时间、每 IP 最多 5 并发、30 个错误查询/分钟；构建器实际串行、分页、断点续跑，大批量优先 dumps。设备运行时完全不调用 SPARQL。

### 2.2 iNaturalist / GBIF

| 来源 | API、速率、条款 | 采用范围 |
|---|---|---|
| iNaturalist | [v1 API](https://api.inaturalist.org/v1/docs/) 与[官方 OpenAPI 源码](https://github.com/inaturalist/iNaturalistAPI/blob/main/lib/views/swagger_v1.yml.ejs)：`GET /v1/taxa?q=…` 搜 taxon，`GET /v1/taxa/{id}` 返回详情，可批量 ID（最多 30）。使用 `default_photo` 的独立 `license_code`、`attribution`、作者与图片 URL。[开发者页](https://www.inaturalist.org/pages/developers) 上限 100 次/分钟，建议 ≤60；媒体 >5 GB/小时或 >24 GB/日可能永久封禁。[推荐实践](https://www.inaturalist.org/pages/api%2Brecommended%2Bpractices) 进一步要求约 1 次/秒、约 10k 请求/日，批量用导出而非抓取。 | [平台条款](https://www.inaturalist.org/pages/terms) 与[媒体复用说明](https://help.inaturalist.org/en/support/solutions/articles/151000169918-can-i-use-the-photos-and-sounds-that-are-posted-on-inaturalist-) 明确版权属上传者，默认媒体常为 CC BY-NC，也可能完全保留版权。后续备用图仅接纳允许的逐图许可；不采用户观察描述、坐标或整库照片。客户端自限 30 次/分钟、并发 1、300 次/日；构建请求另统一限流，不轮换 IP 绕限制。 |
| GBIF | [当前 API 总览](https://techdocs.gbif.org/en/openapi/) 已将旧 Species API 标为 deprecated，推荐 [v2 Taxon API](https://techdocs.gbif.org/en/openapi/v2/taxon)。[机器可读规范](https://techdocs.gbif.org/openapi/taxon.json)：`GET /v2/taxon/{datasetKey}/{taxonKey}/info` 含俗名、分布、媒体等；taxonKey 只在 datasetKey 内唯一。旧 `/v1/species/{usageKey}/vernacularNames`、`/distributions`、`/media` 及 `/v2/species/match` 见 [Species 规范](https://techdocs.gbif.org/openapi/checklistbank.json)。官方不保证固定 QPS；随负载 429，应降速/用下载，不抓官网页面。 | [Data user agreement](https://www.gbif.org/terms/data-user) 要保留提供者归属、遵守各数据集许可并引用源/DOI；[数据集许可](https://ipt.gbif.org/manual/en/ipt/latest/applying-license) 可为 CC0/BY/BY-NC，并非全库 CC0。[媒体字段规范](https://techdocs.gbif.org/en/data-publishing/multimedia-publishing) 含独立 creator/license。用于离线构建核验与可授权别名；有明确来源/日期的粗粒度分布可后续展示；媒体不作为首发图库。自限 1 请求/秒、并发 1，遇 429 退避。 |

实测反例很重要：[iNat Turdus 属](https://api.inaturalist.org/v1/taxa/12705) 的 `default_photo.license_code=null`、attribution 为 all rights reserved；不能因为它是 default photo 就显示。[Turdus merula](https://api.inaturalist.org/v1/taxa/12716) 当日返回 `cc-by` 的默认图。ID 12705 还是属，不能用于乌鸫物种页。未来记录响应时锁定取样日期；这些现场例子不是永久素材选择。

许可代码按[官方搜索参数说明](https://www.inaturalist.org/pages/search%2Burls) 和实际响应处理：`cc0`、`cc-by`、`cc-by-sa` 可进入白名单审核；`cc-by-nc`、`cc-by-nc-sa`、`cc-by-nd`、`cc-by-nc-nd` 有额外限制；null/空/未知拒绝。不得从图片所在 CDN 域名推断许可，观察本身的 licence 也不能替代照片 licence。代码若未带版本，需由照片许可链接/来源元数据确定版本后才缓存，不能擅补 4.0。

### 2.3 只外链与排除项

| 来源 | 核查结论与链接 | 本功能决定 |
|---|---|---|
| eBird | [API 文档](https://documenter.getpostman.com/view/664302/S1ENwy59)、[API 条款](https://www.birds.cornell.edu/home/ebird-api-terms-of-use/)、[数据访问说明](https://support.ebird.org/en/support/solutions/articles/48001078113)：API 支持非商业应用，需个人 key，不得共享 key；商业用途需事先书面许可，需署名且不得影响服务。本次未核实公开数值配额。 | **API 并非一概禁止**，但本功能选择仅外链：不需要它来完成本地搜索/知识页，也省去 key 与商业迁移问题。沿用现有 Cornell code 做已核验链接，不能把 API 许可扩张成图片许可。 |
| Macaulay Library | [媒体使用/申请](https://support.ebird.org/en/support/solutions/articles/48001064551)、[上传 FAQ](https://support.ebird.org/en/support/solutions/articles/48000960529)：创作者拥有文件，一般第三方复用需授权；官方 embed 是非商业网页的有限途径，收益用途需申请。未核实通用开放媒体 API/数值额度。 | 外链；排除抓图、直接复用 CDN、下载缓存/图包。官方网页 embed 虽有允许场景，本方案也不采用，避免 iOS/离线语义不一致。 |
| 懂鸟 | [官方使用条款 §4.1–4.2](https://aboutbirds.app/about/aboutbirds_term_of_use_cn.html)：未经书面许可不得复制、改编、分发等利用内容。本次未找到公开开发 API/速率政策。 | 只打开[官方入口](https://aboutbirds.app/)，配「复制学名」。未核验物种深链前不猜 URL、不调用私有接口；排除内容采集/缓存。 |
| 中国观鸟记录中心 | [服务协议 §4、§6](https://www.birdreport.cn/home/terms/page.html)：未经许可不得技术获取/使用平台内容，商业使用需书面同意；用户上传一般 CC BY-NC-SA 4.0 不等于授予内部 API 接入权。本次未找到公开开发 API/速率文档。 | [站点外链](https://www.birdreport.cn/)；排除抓取、绕签名/加密、热链照片或搬运记录。 |
| Avibase | [About](https://avibase.bsc-eoc.org/about.jsp?lang=EN) 说明分类概念/异名功能；[Downloads](https://avibase.bsc-eoc.org/downloads.jsp?lang=EN) 对特定下载文件给出署名、非商业及各自条款，并非对整个在线数据库授权。本次未找到公开通用 API/数值额度，未证实全库可复用。 | 适合外链核对分类；不搬运异名/分布库，也不把页面上 Flickr 图当 Avibase 授权图。属于许可未确立，不能声称已查到全站禁止。 |
| xeno-canto | [官方 API](https://xeno-canto.org/explore/api)、[条款](https://xeno-canto.org/about/terms)、[v3 endpoint](https://xeno-canto.org/api/3/recordings) 本次均受 BotStopper 阻挡，未能独立核验当前认证/速率；不引用旧 v2「无限额」说法。[XC1002645](https://xeno-canto.org/1002645) 为 CC BY-NC-SA 4.0，[XC161020](https://xeno-canto.org/161020) 为 CC BY-NC-SA 3.0，录音逐条许可。 | 鸟声不在范围内，最多外链，不播放、缓存或打包。以后做声音需重新核查 API/条款，保存录音者、XC ID 和逐条许可，声谱图同样不能当无版权图片。 |

IUCN 不增加新抓取管线。[官方 Red List API](https://api.iucnredlist.org/) 明确商业 API 使用禁止、缓存应先询问许可，并可能限制非保护研究相关应用；没有可承诺的固定数值速率。本设计不能绕经 Wikidata/GBIF 就宣称解决 IUCN 原始数据权利。显示现有包的类别必须保留来源/版本与现有禁用开关；公开发布前由 owner 确认现有再分发依据，否则该字段/筛选隐藏，外链查阅即可。

## 3. 搜索体验与合并规则

### 3.1 搜索入口

iOS 仍在探索 tab，web 仍在记录页的「全部物种（探索，含未见）」模式，复用同一物种页。web 默认已见时不得因为网上搜到未见种就悄悄切筛选；显示「全部物种中还有结果」入口。保留已见/未见、科属、IUCN（可用才有）、这里这个月/全部物种及原来的排序语义。地点和月份始终在屏幕上明确，不向在线知识服务发送这些上下文。

输入时立刻显示本地命中及数量；无联网 loading 遮罩。空查询不联网、不下载 11,172 张图。普通输入不发送到任何第三方。在线知识开启后，进入物种页才自动补充；列表只用缓存/自己的缩略图。用户可点「为当前可见结果加载参考图」，最多 8 个物种一批；保持原行顺序与滚动锚点。更正鸟种 sheet 仅用本地目录和已审核别名，首发不联网、不展示远端未映射物种。

本地排序：原始三名精确 > 审核别名精确 > 原始三名前缀 > 别名前缀 > 原始三名子串 > 别名子串 > 拼音便利匹配，组内按规范学名；非名称的「这里这个月」排序继续遵守 lifelist §6.2。NFKC、大小写/重音折叠、首尾/重复空白标准化一致；保留原文用于显示。简繁名作为有来源的独立别名，不假定无损互换；拼音/首字母不当作物种身份。过滤先于分页，返回总数不只计本页。

### 3.2 结果行

| 元素 | 行为 |
|---|---|
| 64–80 pt/px 缩略图 | 自己的合格证据 > 已审核且已缓存的参考图 > 中性占位。自己的照片标「我的照片」，网络图标「参考图」；记录照片/日历不回退网络图。参考图不得自动出现在用户照片导出物中。 |
| 名称 | 中文主标题，无中文则英文并写「暂无中文名」；英文次行；拉丁学名斜体单独可读。不把网络别名替换成官方标题。命中别名时加「亦称 ×× · 来源」一行。 |
| 本地事实 | 已见/未见、观察/照片数；可选科；IUCN 与本地稀有度分开，不能用一个「珍稀」徽标混淆。稀有度标上下文，例如「加州 · 11 月 · 本地少见」。无数据写未知/数据不足，不写零概率。 |
| 参考图署名 | 图下或同行完整文字「照片：作者 · CC BY-SA 4.0」，作者/来源与许可分别可点；必要时换行，不能只剩版权图标或仅藏在长按菜单。附加 credit 在详情可查。无署名空间的紧凑布局只能用自己的图或占位。 |

iOS 使用系统列表/导航、44 pt 触控区域与现有色板；大字体转全宽行，不截断许可。web 桌面为可键盘操作列表或现有卡片，图片补齐不改变外框尺寸，Enter 打开、返回恢复焦点/查询/筛选/滚动。读屏读三名、已见状态、稀有度上下文，图片不重复念同一物种名；署名链接仍可独立访问。

### 3.3 本地没有的别名与描述词

决定：**做离线别名扩展；不做默认后台的互联网全文联搜。** 中文俗名变体、旧学名、地区名称大部分可以随审核映射一并打包。真正的描述词（如「红色胸部」）不能由名字匹配解决，Wikipedia 文章提到某词也不是可靠的识别结论。首发不承诺按外观/叫声自动找鸟。

第二阶段可独立上线显式按钮「在线查名称/百科」。发送前按钮旁写「将把这段搜索词发送给 Wikipedia / iNaturalist」；全局在线关闭则不可发送。每次提交而非每个按键：Wikipedia [Action API Search](https://www.mediawiki.org/wiki/API:Search) `list=search&srsearch=…&srnamespace=0&srlimit=10`，当前语言一次、用户再点才查另一语言；iNat taxa 只用于名称，不宣称搜描述。最多 10 项，不自动抓下一页、不跨站自动继续搜索。

本地命中区永远在前且位置稳定；在线结果放下面独立区，显示「在线候选」「匹配的是文章内容/别名」及来源。用 bundled reverse index 将 QID/iNat ID 回连到 AviList key，命中本地已有行仅补来源、不重复。来源属/亚种/整组、无映射或分类不一致的候选只可外链，写「尚未对应本地名录」，不能收藏为已见、更正或新增名录物种。网络候选不会改变本地 11,172 分母。空结果提示改用学名、清筛选/切全部物种；「联网也没有结果」不等于物种不存在。

如果以后发现描述词查找值得做，先对有明确许可的短文建立独立的可解释检索索引并评估准确性；目前不加入向量数据库、LLM 改写答案或远端识别。首发只提供文章外链足以覆盖探索需要。

## 4. 物种页

同一 AviList key，无论从已见、探索、更正预览还是统计进入都用同一身份。页面先呈现以下本地部分，再在固定位置补线上内容，不用一个成功/失败状态包住整页：

1. 三名、科属、已见/未见；未见不画个人统计占位数字。有自己照片时保留为首图，参考图在「物种参考」单独区域；无自己照片才可把参考图放首图，并明确标「网络参考图，不是你的观察」。未下载时保持空位/中性占位，不放别的鸟。
2. 「这里这个月」：当前明确选择地区和月份、现有离线 rarity/geo 数据版本、覆盖/不足说明。与当前页观察范围、首见/最近、观察量、自己的 12 月合计条/地点/图库分开。「我在几月拍过」不叫全物种迁徙季节。
3. IUCN：类别代码+中文、评估/包日期、来源和非本地稀有度说明；不可用/权利未解决则隐藏，无危不能用空值代替。不同来源类别冲突不自动覆盖本地；后续若允许展示，只在来源详情列出差异。
4. 「物种参考」：最多 1 张主参考图，点击看适配屏幕的 1024px 图；作者、来源文件页、准确 licence/版本、拍摄说明（若有可靠字段）紧邻显示。用 contain 或注明裁切；首发不把外部图套自己的拍摄参数/水印。候选可优先成人成鸟且外观清楚，但不从元数据空缺推断性别、季节或地点；无合规图片就写「暂无可用的授权参考图」。
5. 「简介」：优先 zh sitelink 的原文短摘要，缺失才 en，英文明确标「英文资料」。约 150–300 个中文字或 60–100 个英文词，尽量按完整句摘录，超出折叠，不为填满版面机器翻译。展示「维基百科贡献者 · 原文摘录 · CC BY-SA 4.0 · 原文 / 历史」，许可以实际页面为准。保留 revision；节选/繁简转换/翻译都记录改动。消歧义页、QID 不符或比本种更宽的条目不作本种简介。
6. 「分布与季节」（后续）：GBIF checklist 有合规明确分布字段时只显示「来源列出的国家/地区」+原始范围、来源/日期；不能把 GBIF occurrence 点图解释为完整分布，也不能由月份计数断言繁殖/迁徙季。没有可授权季节数据时只外链；不下载 IUCN/BirdLife/eBird 范围图充当免费素材，不承诺首发范围地图。
7. 「我的观察」保留当前范围切换、首见/最近/计数/地点/所有个人照片和记录操作。外部信息读取不写观察表，不能改变模型判断/人工更正/首见。
8. 来源链接：Wikipedia 中/英、Commons 文件、iNaturalist、GBIF、eBird、Avibase、懂鸟/中国观鸟记录中心入口。只放已验证链接和 ID；找不到深链就入口+复制学名。用户点击才开系统浏览器/新页，web `noopener noreferrer`，不嵌跟踪 iframe。

每张知识卡独立显示「缓存于 日期」「离线显示缓存」「资料未对应/暂不可用」。语言切换不清空个人数据；简介、图片可独立重试。物种页不会为了请求百科触发定位权限。

## 5. 物种身份与唯一共享映射

### 5.1 正确的 ID 命名空间

不能用属性号的印象编表：

| Wikidata 属性 | 已核验含义 |
|---|---|
| [P685](https://www.wikidata.org/wiki/Property:P685) | NCBI taxonomy ID，**不是 GBIF** |
| [P3444](https://www.wikidata.org/wiki/Property:P3444) | eBird taxon ID/code |
| [P3151](https://www.wikidata.org/wiki/Property:P3151) | iNaturalist taxon ID |
| [P4024](https://www.wikidata.org/wiki/Property:P4024) | Animal Diversity Web ID，**不是 iNat** |
| [P846](https://www.wikidata.org/wiki/Property:P846) | GBIF **2026 更新前**的 numeric species ID；当前属性页明确指向 P14607 |
| [P14607](https://www.wikidata.org/wiki/Property:P14607) | GBIF **2026 更新后**的 taxon ID；不能强制转整数 |

新 GBIF Taxon API 的 ID 必须同时有 datasetKey；不能把旧 numeric key、新字符串 ID 或 Wikidata 属性值无版本地放进一个 `gbifKey: Int`。保留原 rarity 包原有 key/版本，不借此设计重算现有稀有度数据。

### 5.2 构建期流程；运行时不猜

后续新增一个联网的维护脚本（建议 `tools/build-species-sources.py`，**本文未创建**），用锁定的 AviList v2026 11,172 个 scientific key 构建唯一只读 `species-sources.sqlite`；engine 与 iOS 原样打包同一份字节，web 通过本地 engine 读取，不另维护 Swift/TS 手填映射。

构建步骤：固定输入版本和 SHA → 读取 Wikidata claims/中英 sitelinks、iNat 公开 taxonomy 导出、GBIF checklist/名称服务 → 标准化学名生成候选 → 校验鸟纲/科/属、rank、accepted/status 与来源名称 → 人工审核异名/分类概念例外 → 输出与上版 diff、覆盖报告、包摘要。iNat [开发者数据集](https://www.inaturalist.org/pages/developers) 提供每月 taxonomy/common names 导出；批量使用该入口而非逐种扫 API，导出文件本身的许可仍须检查，不因可下载而全部收入。

同学名只是候选，不足以证明相同分类范围。接受策略：

- `exact-reviewed`：来源 species rank、学名和分类吻合且通过构建规则；允许补内容。
- `synonym-reviewed`：原名/现名、同物异名证据与审阅理由均记录；属转移可在确认同一概念后接受。
- `broader` / `narrower` / `split-lump`：源概念较宽/较窄或一对多。不把一个旧物种页/照片复制给所有新拆分种。仅展示「来源分类与 AviList 不同」及链接/源名，不补本种头像或无提示摘要。
- `ambiguous` / `unmapped` / `retired`：ID 为空或隔离，保持本地页正常；未知不取 top-1/fuzzy 结果。

GBIF fuzzy match 只产候选；高 confidence 数字不能跳过科属、species rank 与概念核验。名称误拼、英语名一致也不能自动合并。旧 lifelist 中已说明的 *Porphyrio porphyrio*、*Taeniopygia guttata* 等宽概念和 *Butorides striata/virescens* 名称问题应加入人工复核清单，不能继承中文名映射就认定跨站也一致。

### 5.3 数据内容与体积预算

一张逻辑映射表（1 行/本地科学名）及同包的从属表，不是三个互相漂移的映射系统：

- `species_map`：scientific primary key、AviList version、QID、iNat taxon ID、GBIF datasetKey + string taxonKey + legacy numeric key、eBird code；每来源独立的 match state/source scientific/rank/concept note，源 revision/版本/核验时间/证据 URL。
- `article`：scientific、language、page ID、canonical title/URL、QID、核验 revision。可缺 zh、有 en；运行时重定向只接受仍吻合同 QID 的已知页。
- `alias`：scientific、原文/正规化、语言/地区、别名类型、来源 item/dataset/许可/credit；一名可对多种，不做唯一 name→species 字典。反向 QID/iNat/GBIF 索引也要保留一对多并阻止不安全回连。
- `manifest/provenance`：schema/resource versions、输入摘要、生成日期、批准的许可集合及完整可展示署名。维护脚本输出未映射率和人工例外报告，不要求为追求覆盖率强行填 ID。

估算而非实测：11,172 行 × 约 250–500 B 的紧凑映射 ≈2.8–5.6 MB；加 20k–40k 条别名、文章链接/证据、SQLite 索引后约 8–15 MB，发行压缩约 2–5 MB；轻量三名目录另约 1–3 MB。作为验收上限，映射包 ≤15 MB、整个新离线名称/映射增量 ≤20 MB，超过先精简重复 provenance 字符串，不裁掉未映射物种。图片/全文不进入基础包。更新表时不迁移观察身份，不删除旧科学名记录；名录变更另有显式版本设计。

## 6. 在线适配器、缓存与离线包

### 6.1 两个平台如何分工

iOS 用原生 URLSession + 本地 SQLite 索引/文件缓存；desktop web 由本地 Python engine 请求来源、校验许可并把已净化内容/图片通过 loopback 提供给浏览器。这样复用 names/catalogue/映射与 HTTP 限流，不依赖第三方 CORS、不在页面直接加载 CDN/外部 HTML。无新增公网服务器或账户。

未来接口语义建议：本地 search 与 detail 原路立即返回；独立 enrich GET 只读已缓存内容，显式 refresh POST/动作触发网络并返回逐卡状态。用户输入不能让 engine 变成任意 URL 代理：只接受 catalogue key 或明确的在线搜索文本，来源/HTTPS host/重定向白名单固定，图片仅从已审核元数据地址获取，阻止私网/loopback 重定向。Swift/Python 使用同一 JSON fixture 和状态协议，不要求为了共享代码引入跨平台运行时。

归一化 `ContentItem`：species key + source ID + source concept/match state、kind、语言、原始/净化内容或文件 SHA、source URL/canonical file URL、作者/credit/完整 attribution、准确 licence code/version/URL、版权/限制/改动说明、revision、retrieved/expires、ETag/Last-Modified、policy version。缺许可或必需 credit 时不写媒体缓存、不显示。Commons HTML credit 只保留净化文本和安全链接，不执行 markup/script；不可远端 iframe、CSS 或任意作者头像。

请求顺序：本地事实/自图 → 缓存内容 → 如已授权联网且进入物种页，独立拉 Wikipedia 文本和 Commons 元数据 → 许可通过才拉图。Commons 文件从构建时审核的 P18/文章文件关联选择，不做运行时宽泛图搜。Commons 无图时首发停止；后续启用 iNat 才取已映射 species 的 default_photo，拒绝或无图就占位，不遍历观察抓一张「看起来像」的图。

### 6.2 默认缓存预算

| 项目 | 默认预算 / 有效期 | 到期行为 |
|---|---|---|
| 在线内容总盘占用（含图、索引、临时文件） | iOS 200 MiB；desktop engine 500 MiB；可清空/调整；不同于不可清的用户原图 | LRU 淘汰非 pin 内容，图片优先；下载前预留空间，原子写入时也不能破上限 |
| 名称映射/基础目录 | 版本化内置，只读，不算可淘汰缓存 | 应用/资源更新替换；不可被「清理网络缓存」删除 |
| 摘要/外部粗分布/照片许可元数据 | 30 日；分布也标来源数据日期 | stale-while-revalidate；离线可看旧缓存并显著标日期；文本最多保留 180 日，超后只留来源链接 |
| 图片 | 30 日尝试复核，非 pin 最多 180 日；列表 256–320px、详情 640px，主动放大才 1024px | 每次关联许可记录，不能有孤儿文件；网络失败可用旧图+日期。文件删除/侵权/非自由标志出现时立即停止显示并淘汰；未知新许可不能用于新下载 |
| 404/无合规图/无文章 | 24 小时负缓存 | 显式重试可绕一次，不能滚动时重复请求 |
| 临时失败、429 | 不持久缓存成「不存在」 | 保存冷却时间；到期用户重试；部分成功保留 |

优先用 HTTP conditional GET、缓存头并遵守来源更严格要求；不以本地 TTL 绕过 no-store。网络离线时不等待超时再展示。联网开关关闭会取消队列/停止预取与刷新，仍可读既存缓存；另给「删除网络资料及图包」。缓存从系统备份/便携 `.birdcm` 观察档案排除；原始用户照片/观察不会跟着被清理。缓存图片在 UI 与分享/保存时都必须带可访问许可/署名；首发分享自己的证据时不自动拼入外部参考图。

许可证通常并不会因为 TTL 到期失效；这里的重核验/删除策略是产品的权利风险与存储策略。以前合法取得的 CC 授权与后来网页改变不是简单的自动撤销，但发现侵权投诉/误授权时本产品停用该素材，并保存最少溯源记录用于排查。

### 6.3 可下载地区包（后续，不能空口承诺）

只在逐图许可允许复制/再分发、完整元数据可随包保存时提供「下载地区参考资料」。第一版地区仅使用现有离线 rarity/可能性目录选择物种，地区选择留本地；下载提供方不接收用户 GPS 或家庭地址，但可由物种批次推断兴趣地区，披露此点。没有足够许可素材的地区允许缺图，不偷用 Macaulay/懂鸟补齐。

包是维护者预审的 manifest + 小尺寸 CC0/PD/BY/BY-SA 图片 + 文本及 attribution/许可文件；不得用 API 临时全库爬图。Commons 下载遵守 API/robot 要求，iNat 大量媒体需使用许可明确的数据集或先协商，不能把法律上可缓存等同于允许高频抓取。首期图包只选 Commons 白名单素材，NC/ND 不打包。用户同意后按需下载，默认 Wi-Fi、可暂停/恢复/删除、逐文件 hash 校验、失败不替换已完整包；安装前显示缺图数、来源/许可、大小、版本。

体积估算：500 种 × 80–150 KiB/图 ≈39–73 MiB，摘要/署名约 2–5 MiB；每包上限 80 MiB，每种只一张图。pin 包受总缓存预算约束，空间不够需用户删包或提高额度，不悄悄删 pin 包；下载临时空间也计入。无网络与过期时整包可读、注明包日期；只有显式更新才能保证继续保留。页面同时保留逐图署名；包根目录有可阅读 credits 和 licence 文件，不能加禁止二次分发的条款/DRM。

## 7. 许可执行表与商业化

代码许可与内容许可分开。以下是本产品的保守白名单，不是断言被拒类别在法律上完全不能用。[CC0](https://creativecommons.org/publicdomain/zero/1.0/)、[CC BY](https://creativecommons.org/licenses/by/4.0/)、[CC BY-SA](https://creativecommons.org/licenses/by-sa/4.0/) 均允许商业复用；[CC BY-NC](https://creativecommons.org/licenses/by-nc/4.0/) 有非商业条件；[CC 对 ND/NC/SA 的解释](https://creativecommons.org/share-your-work/licensing-considerations/version4/) 区分禁止分享改编、商业用途和相同方式共享。

| 实际内容许可 | 显示 | 按需缓存/离线包 | 要求与未来付费 |
|---|---|---|---|
| 自己的照片 | 是，始终优先 | 属用户原图库，不是网络缓存 | 不替用户许可给第三方；默认不上传 |
| CC0 / 经核验的公有领域 | 是 | 是 / 是 | 仍显示作者/来源与权利依据；公有领域的法域/限制不明确则拒绝自动接入 |
| CC BY（明确版本） | 是 | 是 / 是 | 保留作者、作品/来源、许可链接、要求的 credit、改动说明；付费可继续 |
| CC BY-SA（明确版本） | 是 | 是 / 是 | 同上；改编的图/文本按该许可或许可允许的兼容条款共享。首发只取原文节选、尺寸适配，裁切/翻译等记录改动并按 SA 处理；不将素材标 MIT |
| CC BY-NC / BY-NC-SA | **默认否** | 默认否 / 否 | 非商业版只有 owner 明确接受 NC 范围和逐项合规后才能另开内容策略；免费或 MIT 不自动证明用途非商业。若启用必须单独分区标 NC，付费/广告/商业分发前关闭、清理对应缓存/图包或另取授权，不能只修改应用说明 |
| CC BY-ND / BY-NC-ND | 首发否 | 否 / 否 | ND 并非禁止所有原样展示，但缩略裁切/后续处理增加复杂性，本产品不自动接纳 |
| 全部保留、null、未知、自定义/GFDL-only、缺作者/多许可无法确定 | 否 | 否 / 否 | 不热链绕过拒绝；可提供原网站链接。将来取得书面授权后另有显式授权记录 |

许可校验必须在 UI 显示和文件落盘前执行，不只在下载器筛选一次；应用升级改变策略后重验缓存。每一内容项单独记录许可，不能用「CC BY-SA」盖住整页自己的照片、文字和所有第三方素材。应用源码继续 MIT，内容保留原许可；下载/保存素材时提供 credit sidecar 或带来源的导出说明，不给内容加封闭再利用限制。

Wikipedia 的文章链接是向贡献者署名的允许方式之一，还要带实际许可链接、revision/历史与导入附加 credit；页面存在额外署名时保留它。首发不做自写拼贴简介；以后翻译/改编的文字也需兼容 SA。完整署名离线可读，许可正文/必要说明随图包保存，不能只靠断网就打不开的链接。

未来商业化前必须复审的不仅是本功能：eBird API 需书面商业许可、Macaulay 需按用途授权、NC 内容必须移除或另授权、IUCN 要解决分发/商业路径；NOTICE 已列的非商业模型和美学权重同样是独立门槛。推荐白名单让新搜索图片无需等到收费时才清理，但不能由此宣称整个 BirdCM 已具备商业发行权。

## 8. 隐私与控制

默认「在线物种资料」关闭；第一次物种页显示可选「开启在线资料」。同意后只对已打开的物种取资料，普通输入仍不外发。开关在两平台设置同名，设置是本机的，不假装自动同步。即使关闭，用户仍可主动点网站链接（离开应用前可见目的域名）。

建议披露原文：

> 在线资料会把你打开的鸟种学名或来源编号发送给 Wikipedia / Wikimedia，以及你启用的图片来源。只有点击「在线查名称/百科」才发送输入的搜索词。不会发送你的照片、拍摄信息、观察记录或位置。网站也会接收到网络连接所需的 IP 地址等信息。关闭后仍可离线搜索、查看自己的记录和已经缓存的资料；可另行删除网络缓存。下载地区包会请求该包的素材，可能透露你关注的鸟种或地区。

第三方收到语言选择、species/文章/图片 ID、应用 UA 和网络 IP 属必要通信，不把「仅学名」说成无法识别兴趣。无账号、追踪 ID、第三方 SDK、查询分析日志或位置 header；原始查询不进入持久日志，诊断仅源、状态码、耗时，不记自由文本/照片 URL 中的私有 token。desktop 的请求从本地 engine 所在机器发出；浏览器只访问本地 API，服务器访问日志不能长久保存搜索文本。外链的目标网站有自己的 cookies/隐私规则，`noreferrer` 不会隐藏 IP。

任何未来用照片/坐标做远端识别或公开目击检索都需要独立用途说明、显式 opt-in 和单独设计；本功能没有这种上传选项，也不能复用原识别/定位授权暗中开启。地区包下载/在线按钮是用户动作，不允许关掉在线后后台继续。

## 9. 性能、失败状态与验收

以下为实现预算，需在支持的最慢 iPhone 与普通桌面实测，不把公网延迟当保证：

| 路径 | 预算 |
|---|---|
| 11,172 名称/别名索引冷打开 | 后台 ≤300 ms，主线程连续工作 <16 ms；不读模型权重/历史 probability JSON |
| 输入后的本地结果 | 150 ms debounce 后查询 p95 ≤50 ms；从末次按键到首批可见 p95 ≤250 ms；取消旧查询，50/60 条分页 |
| 本地物种事实/自己的首图 | 暖路径 p95 ≤100/200 ms；线上请求开始与否不影响其显示 |
| 缓存参考图/摘要 | p95 ≤150 ms；图片异步解码，列表不因补图滚动跳动 |
| 在线请求 | 连接预算 3 s、单项总计 8 s；到点卡片显示重试，继续保留本地内容；联网时参考内容目标 ≤2.5 s，但无服务保证 |
| 每次开详情的网络成本 | 暖缓存 0 请求；冷页通常摘要 1 + Commons metadata 1 + 缩略图 1，缺中文才多 1 次英文；fallback 最多一次，不无限级联；正文/元数据每响应上限 1 MiB、图片上限 2 MiB |
| 资源 | 列表同时解码图 ≤8，图片增量内存 ≤32 MiB；切页取消未开始任务、共用同物种 in-flight 请求；后台不预取全目录 |

退避仅对暂时故障：遵守 Retry-After，无该值则 5s/15s/60s + jitter，当前页面最多自动重试一次，之后手动。429 的等待提示是「来源请求较多，稍后可重试」，不更换域名/IP规避。短暂 TLS/DNS/超时显示缓存日期或「在线资料暂不可用」；无文章/无合规图独立提示；403/认证失败不让用户填 cookie，不请求不需要的 iNat 登录。不能因为上游无图就删除自己的图。

其它必须有的失败：QID/来源概念不符→隔离该知识卡；许可缺失→占位且保留原链接；来源删图/侵权标志→停用图；磁盘满→不缓存、保留本地搜索与用户原图；缓存损坏→丢该条派生项可重取；映射版本不兼容→在线层停用并解释，本地三名目录仍可搜索；来源返回 HTML/畸形 JSON→拒绝解析且不执行 HTML；快速输入 A→B、快速导航→旧请求不能写入新行或新页。

### 测试计划（实现时添加，不在本次改代码）

- **固定响应金样**：从真实官方 API 录制小样，附请求 URL、日期、响应状态/headers、源 revision、提供者/许可、SHA；去掉 token/IP/个人记录。只保留具有再分发依据的最小响应；未知权利字段用自造 fixture 补边界，不能把保留版权照片提交进仓库。两平台跑同一归一化期望 JSON；CI 禁止 live network，HTTP stub 对任何漏网请求直接失败。
- **名称与身份**：简繁/拼音/重音/NFKC、空格、同名多种、exact/prefix/substring、过滤分页、Royal/Elegant Tern；GBIF P846 旧数字与 P14607 字符串、dataset scope、iNat 属/亚种、停用 ID、synonym、拆分/合并一对多、中文/英文 sitelink 缺失/消歧义。映射每个本地 key 恰一行；空 ID 合法，重复外部 ID 必须显式标概念冲突。
- **权利金样**：CC0/BY/BY-SA 各版本、NC/ND/null/default photo all-rights-reserved、多许可、作者不等于 uploader、额外 Attribution/Restrictions、恶意 HTML、许可改变/删除、缺 credit。拒绝素材在 UI、磁盘、分享和图包四条路径均不能漏出；自己的照片不受网络许可策略影响。
- **顺序与错误**：本地先到/线上晚到、同种合并、不在本地候选仅外链、改 query 后旧结果丢弃、线上无图/404/429/503/超时/断网，离线缓存和关闭开关后零请求；中文失败英文有结果明确标语言。
- **缓存/包**：LRU/硬 cap（含临时写）、元数据和文件原子性、过期重验证/304、negative cache、损坏 hash、磁盘满、pin 不被暗删、下载中断/恢复/撤销、删网络缓存不碰观察/原图、备份不带缓存。
- **隐私与 UI**：拦截全部出站请求断言没有 EXIF/GPS/照片/历史/自由文本日志；普通键入零联网、在线按钮才发 query；关闭时取消队列。iOS Dynamic Type/VoiceOver，web 键盘/焦点/读屏、慢网/无图、200% 缩放、署名不截断、参考图不伪装个人证据、范围与月份上下文清楚。
- **发布前手动网络冒烟**：在开发者设备单独检查 zh/en summary/回退、Commons 许可字段、GBIF 新 API 与 mapping namespace、iNat 默认图和拒绝例子；记录核验时间，不放入 CI。审核构建 diff 和未映射报告，取若干新拆分种人工比对。性能以离线/慢网/10k 个人证据实测，而非仅空库。

## 10. 独立可发布的构建顺序与 owner 决策

1. **本地基础与物种页整理**：打包独立轻量目录，统一三名/审核别名检索与现有筛选，保留个人照片、观察/IUCN 开关/本地稀有度上下文；两个平台全离线验收。此步已能发布，不依赖任何新在线资料。
2. **唯一离线映射包**：做维护脚本、来源/许可 manifest、分类例外审核和 shared fixtures；先只用于准确外链与别名，映射覆盖不足不阻塞本地使用。测量包体积，禁止客户端 fallback 猜 ID。
3. **Wikipedia 简介**：在线 opt-in、隐私文案、独立卡片状态、语言/署名、缓存/清理/限流；两端共享响应契约。关网仍完整可用即可独立发布。
4. **Commons 参考图**：逐图许可 gate、作者/许可行、自图优先、磁盘预算与视图稳定性；先做物种页，再允许显式加载可见列表图。只有图片拒绝路径和离线 credit 都通过才上线。
5. **按需增益**：有实际缺图率数据后决定 iNat 备用图库；显式在线名称/百科搜索独立发布，初期可继续仅外链；经授权的 GBIF 粗分布另发，不把它们绑成一轮大改。
6. **地区资料包**：先完成逐项许可清单、来源负载策略、可恢复下载、硬 cap 与离线署名，再小范围做一个 ≤80 MiB 包；不承诺全世界图文百科或声音。

owner 需要确认的产品/发行选择（不阻塞本设计写入）：

- 接受推荐的 **默认不联网、开启后只补已打开物种、键入不发送** 吗？若改默认，要重新明确首次披露与用户控制。
- 是否采用从今天起 **不接纳 NC 图片** 的长期策略？推荐是；如想要更高覆盖率，必须明确非商业用途与未来下线/重授权成本，不能仅以「免费」代替判断。
- 先交付短原文简介/参考图，还是愿意维护译文与 SA 义务？推荐只做原文 zh→en 回退；明确接受中文缺项。
- IUCN 现有包的再分发依据谁负责确认？未解决时本功能默认隐藏其类别/筛选；不能把联网补充当绕开现有 NOTICE 风险的办法。
- 是否真的需要应用内「描述词」搜索与地区图包？推荐先看本地别名、物种页和外链的使用情况，再分别决定；首发不因此延期。

除这些选择，默认实现按上述推荐推进；eBird/Macaulay、懂鸟、观鸟记录中心、Avibase 都无需为了本功能去申请账号、抓取许可不明内容或引入后端服务。
