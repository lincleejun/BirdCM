# GBIF API：哪些值得接入 iOS

调研日期 2026-11-19。**这是决策菜单，不是实现范围**（同 [ideas-ios.md](ideas-ios.md)：其中没有任何一项授权上线联网服务）。
结论来自 GBIF 官方文档和对 `api.gbif.org` 的实测请求（搜索、地图、图片缓存都无需密钥、无需账号；只有 Download API 要登录免费的 GBIF 账号，匿名请求实测返回 403。数字是当天的返回值，会变）。

来源：[API 总览](https://techdocs.gbif.org/en/openapi/)、各分区 OpenAPI 规范 `https://techdocs.gbif.org/openapi/{literature,taxon}.json`
（文档页本身是 JS 渲染的，规范文件才是正文）。

## 结论

| 排名 | 接口 | 能做什么 | 方式 | 对应 ideas-ios | 判断 |
|---:|---|---|---|---|---|
| 1 | Maps `v2/map/occurrence/density` | 物种页上的全球观测分布图（PNG 瓦片） | 运行时联网 | 新 | **值得做**，成本最低 |
| 2 | Occurrence `search` + `gadmGid` 二级行政区 | 县级的月份频次表 | 构建期，随包 | 修复 bird-value 的 "Cupertino needs county data" | **值得做**，是引擎工作，不是 iOS 联网 |
| 3 | Occurrence `search` + `mediaType=StillImage` | 物种参考照片（他人拍摄） | 运行时联网 | #2 相似种对比、#14 参考包 | 可做，须按**每张图**的许可过滤并署名 |
| 4 | Occurrence `search` + `geoDistance` + `eventDate` | 附近近期记录 | 运行时联网 | #13 | 只能当"近一个月 iNaturalist 记录"，不是实时鸟讯 |
| 5 | Occurrence `search` + `mediaType=Sound` | 鸣声试听 | 运行时联网 | #18/#19 | 84% 是 NC 许可，先不做 |
| — | Literature | 引用 GBIF 数据的论文 | — | — | **不值得** |
| — | Species/Taxon 的 vernacularNames、descriptions、distributions、media、iucnRedListCategory | 名称、描述、图 | — | — | **不值得**，已有或太薄 |

## 逐项证据

**Literature（用户给的起点）。** 只有三个端点：`/literature/search`、`/literature/{uuid}`、`/literature/export`。它索引的是
"引用了 GBIF 数据的论文"，不是物种文献库。`gbifTaxonKey=5232207`（棕榈鬼鸮）返回 1 篇，红嘴蓝鹊 1 篇，`q=Urocissa erythroryncha`
返回 0 篇；整个鸟纲（`gbifHigherTaxonKey=212`）共 1271 篇，主题以 CONSERVATION / ECOLOGY / 气候变化建模为主。对拍鸟的人没有可读内容。

**Maps。** `GET /v2/map/occurrence/density/{z}/{x}/{y}@2x.png?taxonKey=…&bin=hex&style=classic.poly&srs=EPSG:3857` 返回 200、
112 KB、1.6 s；`capabilities.json` 给出该物种的经纬度范围和年份范围，可用来定初始视野。iOS 上是一个 `MKTileOverlay`，底图用 MapKit
自带的，不需要 `tile.gbif.org`。带 `month=` 过滤的 `adhoc` 瓦片要 5.2 s，不要承诺"按月分布图"。瓦片请求只带 taxonKey 和瓦片坐标，
不带用户位置。

**县级数据。** `/v1/geocode/reverse?lat=37.32&lng=-122.03` 返回 `GADM2 = USA.5.43_1`（Santa Clara）。
`occurrence/search?taxonKey=212&gadmGid=USA.5.43_1&facet=month` 有 4,932,094 条鸟类记录，每月 28–53 万条，11 月有 338 个物种
（`facetLimit=1000` 以内）。样本量足够做县级分级。批量构建应走 Download API（文档明确要求：搜索接口跑超过 15 分钟就改用下载，
否则会被 429 限流），和现在的省/州表同一条管线；账号只在构建机上用，不进 App。中国等地区的二级区划覆盖没有测。

**参考照片。** 棕榈鬼鸮有图记录 4787 条：CC BY-NC 4054、CC BY 373、CC0 360；红嘴蓝鹊 5379 条：NC 4842、BY 350、CC0 187。
**`license=` 参数过滤的是记录的许可，不是图片的许可**：鸟纲下 `license=CC0_1_0&license=CC_BY_4_0` 的前 600 条记录共 1132 张图里，媒体许可是
"Copyright by the creator"（NABU naturgucker）997 张、CC BY 70、CC0 45、BY-SA 16、BY-NC 2、BY-NC-SA 2。所以客户端必须读
`media[].license` 自己过滤，并显示 `creator` / `rightsHolder`、许可和原始链接。缩略图走
`/v1/image/cache/400x/occurrence/{key}/media/{md5(identifier)}`（实测 200，64 KB）。只在线显示，不打包进 App。

**附近近期记录。** Cupertino 20 km 内鸟类记录：近 7 天 0 条，近 14 天 429 条，近 30 天 1898 条；北京 30 km：0 / 56 / 471。
30 天内的记录全部来自 `iNaturalist Research-grade Observations`（CC BY-NC，最近一次发布 2026-11-09）。eBird 数据集（EOD，CC BY 4.0）
按年发布：同一范围 2025 年 518,940 条，2026 年 0 条。所以这里拿到的是"一到两周前的 iNaturalist 记录"，不能替代 eBird 近期鸟讯，
而且查询要把位置发给 GBIF（应由用户选粗略区域）。

**鸣声。** 棕榈鬼鸮有声音记录 906 条，来自 iNaturalist（551）和 Xeno-canto（335）；许可 NC 759、BY 100、CC0 47。可在线试听，
但 NC 占多数，和将来的发行方式有关，先不碰。

**Species/Taxon 子资源。** `iucnRedListCategory` 和中文 vernacularNames 我们已随包（IUCN 表、zh-names）；`descriptions` 只有一句
IOC 分布描述；`media` 返回 0 条。另外 Species API 已被官方标为 deprecated，由 Taxon API（`/v2/taxon/…`，按 checklist datasetKey 查）
取代。Occurrence 和 Maps 的 `taxonKey` 仍接受我们打包的 Backbone key（实测）；这个 key 覆盖 10,436 / 11,172 种（93.4%，见
[species-map-report.md](species-map-report.md)），其余物种这些功能不可用，运行时不要靠学名模糊匹配去补。

## 共同约束

- GBIF 建议集成方把 User-Agent 设成网址或邮箱以便联系；搜索接口按服务器负载限流（429），没有保证的速率。
- 展示 GBIF 数据需要署名（About 里已有 GBIF 引用；照片和声音还要逐条署名作者和许可）。
- 1、3、4、5 都是运行时联网请求；按 ideas-ios 的隐私门槛，应当是用户主动点开才发起。
