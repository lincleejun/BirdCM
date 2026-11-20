"""The engine's user-facing text in Simplified Chinese and English, side by side (R8).

t(key, **params): the text in the current language. The language: per API request from Accept-Language (app.Lang; no
header -> zh, as before), else BIRDCM_LANG / LC_ALL / LC_MESSAGES / LANG (the CLI, admin, startup messages): one that
does not start with zh, C or POSIX -> English, unset -> Chinese.

Text that is stored (star reasons, written by the queue thread that has no request) is stored as a code, R(key, ...)
= [key, params], and rendered when it leaves the API (text()). A parameter that is itself a code renders in the same
language; a {zh, en, sci} label renders as the bird's name in that language. Older rows hold Chinese sentences:
text() maps the ones that are a fixed message (no parameters) by exact match; app.py re-rates a scan whose reasons
are older sentences once when English is asked for.

Adding a message: one line in MSG, then t("key") or R("key"). tests/test_i18n.py checks that every key used exists,
every key is used, and both languages take the same parameters.
"""
from __future__ import annotations

import os
from contextvars import ContextVar

MSG: dict[str, tuple[str, str]] = {
    # ---- stars.py: star reasons (stored as codes) ----
    "stars.no_bird": ("没有找到鸟", "No bird found"),
    "stars.no_clear_bird": ("没有清楚的鸟", "No clear bird"),
    "stars.manual": ("主人手动设定", "Set by you"),
    "stars.low_det": ("检测把握太低（{det:.2f}），不参与排名", "Detection confidence too low ({det:.2f}); not ranked"),
    "stars.low_aes": ("美学分太低（{aes:.2f}），不参与排名", "Aesthetic score too low ({aes:.2f}); not ranked"),
    "stars.low_sharp": ("头部清晰度太低，不参与排名", "Head too soft; not ranked"),
    "stars.no_eye_beak": ("眼睛和嘴都看不见，角度不佳", "Neither eye nor beak visible; poor angle"),
    "stars.unconfirmed_among": ("未确认鸟种的照片中", "among photos without a confirmed species"),
    "stars.rank": ("{who}第 {rank} / {n} 名", "#{rank} of {n}, {who}"),
    "stars.rank_ascii": ("{who} 第 {rank} / {n} 名", "#{rank} of {n}, {who}"),
    "stars.cap_no_eye": ("看不见眼睛，最多两星", "Eye not visible: two stars at most"),
    "stars.cap_focus": ("对焦点不在鸟身上，最多两星", "Focus point not on the bird: two stars at most"),
    "stars.cap_sharp3": ("头部清晰度不够三星", "Head not sharp enough for three stars"),
    "stars.cap_burst": ("同一连拍组已有两张三星", "This burst already has two three-star photos"),
    "stars.flying": ("飞版，{r}", "In flight. {r}"),
    "stars.joined": ("{a}；{b}", "{a}; {b}"),
    "stars.ranked_low": ("排名靠后，{r}", "Ranked low: {r}"),
    "stars.floor_quota": ("保底：这个鸟种最好的一张", "Kept: the best photo of this species"),
    "stars.unnamed": ("未定种", "unidentified bird"),
    "stars.alike": ("和同组 {file} 差不多，任选其一", "Much the same as {file} in its burst; either will do"),
    "stars.close": ("和同组 {file} 评分接近，选了那张", "Scores close to {file} in its burst; that one was picked"),
    "stars.better": ("同组 {file} 更好", "{file} in its burst is better"),
    "stars.another": ("另一张", "another photo"),
    "stars.weak": ("整体质量不够，不为凑比例而给星", "Overall quality too low; not starred just to fill the ratio"),
    "stars.full": ("比例已满，排在后面", "The ratio is full; ranked below"),
    "stars.short_eye": ("眼睛不够清楚", "the eye is not clear enough"),
    "stars.short_burst": ("同组里不是最清楚的", "not the sharpest in its burst"),
    "stars.short_species": ("同种里清晰度偏低", "softer than other photos of this species"),
    "stars.short_focus": ("对焦点不在鸟身上", "the focus point is not on the bird"),
    "stars.short_small": ("鸟太小", "the bird is small in the frame"),
    "stars.short_aes": ("构图美感一般", "the composition is ordinary"),
    "stars.short_genus": ("鸟种没认准", "the species is not settled"),
    "stars.short_better": ("同组已有更好的一张", "its burst has a better one"),
    "stars.short_q": ("综合分不够高", "the overall score is not high enough"),
    "stars.short_alike": ("和其他{name}差不多", "much like the other {name} photos"),
    "stars.three": ("各方面都很好（综合 {q:.2f}）", "Good in every way (overall {q:.2f})"),
    "stars.two": ("值得留，但{short}", "Worth keeping, but {short}"),
    "stars.floor": ("这个鸟种在这批里最好的一张", "The best photo of this species in this batch"),
    "stars.rare": ("当地少见，留作记录", "Scarce here; kept as a record"),
    "stars.flying_flawed": ("飞版，有瑕疵", "In flight, with flaws"),
    "stars.record": ("留作记录", "Kept as a record"),
    "stars.clip_hi": ("高光溢出", "blown highlights"),
    "stars.clip_lo": ("暗部死黑", "crushed shadows"),
    "stars.expo": ("鸟身上{bad}", "{bad} on the bird"),
    "stars.expo_malus": ("鸟身上{bad}（扣分）；{r}", "{bad} on the bird (marked down); {r}"),
    "stars.expo_joined": ("鸟身上{bad}；{r}", "{bad} on the bird; {r}"),
    # ---- stars.py: settings ----
    "stars.v_object": ("星级设置要是一个对象", "The star settings must be an object"),
    "stars.v_strategy": ("strategy 只能是 select 或 quota", "strategy must be select or quota"),
    "stars.v_unknown": ("不认识的星级设置：{k}", "Unknown star setting: {k}"),
    "stars.v_preset": ("preset 要是文字", "preset must be text"),
    "stars.v_per_species": ("per_species 要是 true / false", "per_species must be true / false"),
    "stars.v_number": ("{k} 要是数字", "{k} must be a number"),
    "stars.v_unit": ("{k} 要在 0–1 之间", "{k} must be between 0 and 1"),
    "stars.v_positive": ("{k} 要大于 0、不超过 1", "{k} must be above 0 and at most 1"),
    "stars.v_negative": ("{k} 不能为负", "{k} must not be negative"),
    "stars.v_weight": ("至少要有一个权重大于 0", "At least one weight must be above 0"),
    "stars.v_burst": ("连拍上限要是整数，连拍间隔在 0–3600 秒", "The burst cap must be a whole number and the burst gap 0–3600 s"),
    "stars.v_keep": ("留片比例在 0–100%", "The keep ratio must be 0–100%"),
    "stars.v_quota": ("三星、两星比例各在 0–100%，合计不超过 100%", "The three-star and two-star shares must each be 0–100% and add up to at most 100%"),
    "stars.v_old": ("权重、连拍上限、连拍间隔不能为负，鸟种把握在 0–1", "Weights, burst cap and burst gap must not be negative; species confidence 0–1"),
    # ---- pipeline.py / decode.py / queue (stored as text: mapped by exact match) ----
    "pipeline.decode_timeout": ("解码超时（文件可能已损坏）", "Decoding timed out (the file may be damaged)"),
    "pipeline.decode_crash": ("解码进程崩溃（文件可能已损坏）", "The decoder crashed (the file may be damaged)"),
    "pipeline.decode_failed": ("解码失败：解码进程崩溃或超时（文件可能已损坏）", "Decoding failed: the decoder crashed or timed out (the file may be damaged)"),
    "queue.rating_failed": ("标星出错：{e}", "Rating failed: {e}"),
    "decode.not_dir": ("不是文件夹：{p}", "Not a folder: {p}"),
    "decode.newline": ("这些照片的文件名里有换行，请先改名再扫描：{names}", "These photos have a line break in their names; rename them before scanning: {names}"),
    "decode.gone": ("文件已不存在", "The file no longer exists"),
    "decode.changed": ("文件在列出之后被修改过", "The file changed after it was listed"),
    "decode.no_exiftool": ("找不到 exiftool。macOS 上运行 `brew install exiftool` 安装后再试。", "exiftool not found. On macOS run `brew install exiftool`, then try again."),
    "decode.exiftool_timeout": ("exiftool 超时", "exiftool timed out"),
    "decode.exiftool_exited": ("exiftool 退出了", "exiftool exited"),
    "decode.bad_arg": ("文件名含换行或不是绝对路径，拒绝交给 exiftool：{p}", "A file name with a line break or not an absolute path; not passed to exiftool: {p}"),
    "config.inside": ("数据或缓存目录 {d} 在照片文件夹 {f} 里面；请用 BIRDCM_DATA_DIR / BIRDCM_CACHE_DIR 换到别处",
                      "The data or cache folder {d} is inside the photo folder {f}; move it elsewhere with BIRDCM_DATA_DIR / BIRDCM_CACHE_DIR"),
    # ---- models.py ----
    "models.fetch_hint": ("Mac 应用：在菜单栏的观羽图标里下载模型；从源码运行：在 engine/ 里执行 `uv run birdcm models fetch`。",
                          "Mac app: download the models from the BirdCM icon in the menu bar; from source: run `uv run birdcm models fetch` in engine/."),
    "models.effect_clear": ("没有“清楚的鸟”判断：每个检测框都当作鸟来认", "No “clear bird” check: every detected box is named as a bird"),
    "models.effect_aesthetic": ("没有美学分：星级只用其余的信号", "No aesthetic score: stars use the other signals only"),
    "models.effect_rarity": ("没有本地稀有度：显示“数据不足”", "No local rarity: shown as “insufficient data”"),
    "models.effect_rarity_global": ("没有全球稀有度表：本地稀有度只覆盖美国、加拿大、中国，其他地方显示“数据不足”",
                                    "No global rarity table: local rarity covers only the US, Canada and China, elsewhere “insufficient data”"),
    "models.missing": ("缺模型文件：{names}。{hint}", "Model files missing: {names}. {hint}"),
    "models.skip_unreleased": ("还没有发布（{effect}）", "not released yet ({effect})"),
    # ---- cli.py ----
    "cli.unreleased": ("未发布 ", "unrel. "),
    "cli.optional_missing": ("可选缺 ", "opt.   "),
    "cli.unreleased_list": ("这 {n} 个文件还没有发布：{names}。没有它们也能用：", "These {n} files are not released yet: {names}. The app works without them:"),
    "cli.list_sep": ("、", ", "),
    "cli.uncertain": ("不确定", "uncertain"),
    "cli.flying": ("飞", "flying"),
    # ---- app.py: API errors and startup ----
    "app.open_photo": ("打不开这张照片：{e}", "Cannot open this photo: {e}"),
    "app.too_many_pixels": ("照片太大（{mp:.0f} MP），上限 {cap:.0f} MP", "The photo is too large ({mp:.0f} MP); the limit is {cap:.0f} MP"),
    "app.bad_location": ("位置要有合法的经纬度（纬度 −90–90，经度 −180–180），来源是 map / device / region",
                         "A location needs a valid latitude (−90–90) and longitude (−180–180), with source map / device / region"),
    "app.location_label": ("位置名称要是文字", "The location name must be text"),
    "app.region_code": ("地区代码要是 ISO 3166 代码（如 US、US-CA）", "The region code must be an ISO 3166 code (such as US or US-CA)"),
    "app.no_scan": ("没有这个扫描", "No such scan"),
    "app.place_search": ("在线地名搜索用不了：{e}", "Online place search is unavailable: {e}"),
    "app.bad_point": ("经纬度不对", "Invalid latitude / longitude"),
    "app.pick_macos": ("只在 macOS 上能弹出选择窗口，请直接输入路径", "The folder picker works on macOS only; type the path instead"),
    "app.pick_prompt": ("选择照片文件夹", "Choose a photo folder"),
    "app.not_dir": ("不是文件夹：{p}", "Not a folder: {p}"),
    "app.bad_rating": ("这个设置算不出星级：{e}", "These settings cannot be rated: {e}"),
    "app.no_photo": ("没有这张照片", "No such photo"),
    "app.no_preview": ("无法生成预览：{e}", "Cannot make a preview: {e}"),
    "app.not_in_scan": ("这次扫描里没有这张照片", "This photo is not in this scan"),
    "app.no_original": ("无法读取原图：{e}", "Cannot read the original: {e}"),
    "app.scope": ("范围只能是 one / burst / same", "scope must be one / burst / same"),
    "app.unknown_sci": ("名录里没有这个学名：{sci}", "No such scientific name in the checklist: {sci}"),
    "app.none_picked": ("没有选照片", "No photos selected"),
    "app.star_value": ("星级只能是 -1（淘汰）、0、1、2、3", "Stars must be -1 (rejected), 0, 1, 2 or 3"),
    "app.no_record": ("没有这条记录", "No such record"),
    "app.count": ("数量只能是正整数或 X", "A count must be a positive whole number or X"),
    "app.content_length": ("需要 Content-Length", "Content-Length is required"),
    "app.upload_too_big": ("照片超过 {mb} MB", "The photo is over {mb} MB"),
    "app.no_upload": ("没有收到照片", "No photo received"),
    "app.upload_type": ("只支持 ARW、DNG、JPG、PNG", "Only ARW, DNG, JPG and PNG are supported"),
    "app.bad_region": ("位置格式不对", "Invalid location format"),
    "app.upload_name": ("照片", "photo"),
    "app.no_bird": ("没有这只鸟", "No such bird"),
    "app.bad_box": ("框的坐标不对", "Invalid box coordinates"),
    "app.day": ("{name} 要是 YYYY-MM-DD", "{name} must be YYYY-MM-DD"),
    "app.newer_db": ("数据库是更新版本的观羽写的：这个版本不改动它的记录本", "The database was written by a newer BirdCM: this version does not change its records"),
    "app.species_query": ("seen / rarity / iucn / sort 的取值不对", "Invalid seen / rarity / iucn / sort value"),
    "app.status_query": ("status 只能是 all / pending / no-bird", "status must be all / pending / no-bird"),
    "app.year": ("year 不对", "Invalid year"),
    "app.bounds": ("bounds 要是 south,west,north,east", "bounds must be south,west,north,east"),
    "app.reload": ("统计已经更新，请重新载入后再改", "The records have been updated; reload, then make the change"),
    "app.no_observation": ("没有这条观察记录", "No such observation"),
    "app.count_range": ("数量只能是 1–999998", "A count must be 1–999998"),
    "app.reload_busy": ("统计正在更新或已经更新，请重新载入后再改", "The records are updating or have been updated; reload, then make the change"),
    "app.no_subject": ("没有这张照片或这个主体", "No such photo or subject"),
    "app.subject_only": ("鸟种、数量、排除只能改某一只鸟，不能改整张照片", "Species, count and exclusion apply to one bird, not the whole photo"),
    "app.no_gps": ("这张照片没有 GPS，不能恢复成照片位置", "This photo has no GPS; it cannot go back to the photo's location"),
    "app.export_failed": ("导出失败：{e}", "Export failed: {e}"),
    "app.import_too_big": ("文件太大，或磁盘空间不够暂存和导入它", "The file is too large, or there is not enough disk space to stage and import it"),
    "app.no_file": ("没有收到文件", "No file received"),
    "app.import_expired": ("导入已过期（30 分钟），请重新选择文件", "The import expired (30 minutes); choose the file again"),
    "app.import_mode": ("mode 只能是 merge / restore，选择只能是 local / file", "mode must be merge / restore, and choices local / file"),
    "app.restore_confirm": ("只有完整备份能恢复，并且要先确认会替换记录本", "Only a full backup can be restored, and you must first confirm it replaces your records"),
    "app.preview_again": ("统计已经更新，请重新预览", "The records have been updated; preview again"),
    "app.no_import": ("没有这条导入记录", "No such import"),
    "app.original_elsewhere": ("这张照片的原图不在这台电脑上", "The original of this photo is not on this computer"),
    "app.original_gone": ("原图不见了", "The original is gone"),
    "app.original_unavailable": ("原图不可用", "The original is unavailable"),
    "app.fallback": ("fallback 只能是 refuse / include / exclude", "fallback must be refuse / include / exclude"),
    "app.fingerprinting": ("正在给照片做指纹，做完再导出", "Fingerprinting photos; export when it is done"),
    "app.online_flags": ("enabled / disclosed / places / updates 要是 true / false", "enabled / disclosed / places / updates must be true / false"),
    "app.no_cached_image": ("没有缓存的授权参考图", "No cached licensed reference image"),
    "app.warn_exiftool": ("警告：找不到 exiftool，拍摄信息和对焦点会是空的。`brew install exiftool` 安装。",
                          "Warning: exiftool not found; shooting info and focus points will be empty. Install it with `brew install exiftool`."),
    "app.warn_unreleased": ("还没有发布 {name}：{effect}", "Not released yet: {name}: {effect}"),
    "app.warn_optional": ("没有 {name}：{effect}", "Missing {name}: {effect}"),
    "app.warn_web": ("没有找到界面文件 {web}；先在 web/ 里运行 `npm install && npm run build`。",
                     "Web UI files not found at {web}; run `npm install && npm run build` in web/ first."),
    # ---- library.py ----
    "library.reason_genus": ("只认到属", "Genus only"),
    "library.reason_uncertain": ("不确定", "Uncertain"),
    "library.reason_unclassified": ("还没识别的框", "Box not identified yet"),
    "library.reason_unresolved": ("名录里没有这个学名", "Scientific name not in the checklist"),
    "library.reason_needs_match": ("需核对主体对应", "Check which bird is which"),
    "library.edit_op": ("edit.op 只能是 species / count / exclude / date / place", "edit.op must be species / count / exclude / date / place"),
    "library.edit_state": ("state 只能是 species / uncertain / none", "state must be species / uncertain / none"),
    "library.edit_unknown": ("名录里没有这个学名：{key}", "No such scientific name in the checklist: {key}"),
    "library.edit_null_key": ("不确定 / 恢复自动识别时 key 要是 null", "key must be null for uncertain / back to automatic"),
    "library.edit_count": ("数量只能是 1–999998 的整数，或 null 恢复自动", "A count must be a whole number 1–999998, or null for automatic"),
    "library.edit_exclude": ("exclude 的 value 要是 true / false", "exclude's value must be true / false"),
    "library.edit_date": ("日期要是 YYYY-MM-DD 或 YYYY-MM-DDTHH:mm:ss", "A date must be YYYY-MM-DD or YYYY-MM-DDTHH:mm:ss"),
    "library.edit_tz": ("时区偏移要在 −840 到 +840 分钟之间", "The time-zone offset must be between −840 and +840 minutes"),
    "library.edit_source": ("地点来源只能是 photo / map / device / region / none", "The place source must be photo / map / device / region / none"),
    "library.edit_label": ("地点名称要是文字", "The place name must be text"),
    "library.edit_point": ("地图 / 定位的地点要有合法经纬度", "A map / device place needs a valid latitude and longitude"),
    "library.edit_region": ("地区要有 ISO 3166 代码，且不带坐标", "A region needs an ISO 3166 code and no coordinates"),
    "library.edit_none": ("照片位置 / 无地点不带坐标和代码", "Photo location / no place takes no coordinates or code"),
    # ---- ebird.py ----
    "ebird.protocol": ("protocol 只能是 {names}", "protocol must be {names}"),
    "ebird.count": ("{sci} 的数量要是 1–999998 的整数或 X", "The count of {sci} must be a whole number 1–999998 or X"),
    "ebird.too_big": ("文件超过 eBird 的 1 MB 上限：请少选几种或分几次导出", "The file is over eBird's 1 MB limit: choose fewer species or export in parts"),
    "ebird.no_date": ("有照片没有拍摄日期（按首次识别日期统计）：请先核对，选择包含或排除这些记录",
                      "Some photos have no capture date (counted by the date first identified): check them first, then include or exclude these records"),
    # ---- archive.py ----
    "archive.unreadable": ("不是观羽的备份文件（打不开）", "Not a BirdCM backup (cannot be opened)"),
    "archive.not_backup": ("不是观羽的备份文件", "Not a BirdCM backup"),
    "archive.version": ("备份文件的格式版本不认识（可能是更新版本的观羽写的）", "Unknown backup format version (perhaps written by a newer BirdCM)"),
    "archive.tables": ("备份文件的表不对", "The backup's tables are wrong"),
    "archive.object": ("备份文件里有不认识的对象：{t} {n}", "Unknown object in the backup: {t} {n}"),
    "archive.columns": ("备份文件的 {n} 列不对", "The backup's {n} columns are wrong"),
    "archive.corrupt": ("备份文件已损坏", "The backup is damaged"),
    "archive.meta": ("备份文件缺少必要信息或版本不对", "The backup lacks required information or has the wrong version"),
    "archive.photo_ids": ("备份文件里的照片编号不对", "Wrong photo ids in the backup"),
    "archive.missing_blob": ("标为缺失的照片不能带原图", "A photo marked missing cannot carry its original"),
    "archive.blob_mismatch": ("备份文件里的原图和记录不一致", "The originals in the backup do not match its records"),
    "archive.blob_hash": ("备份文件里有原图和它的校验值对不上", "An original in the backup does not match its checksum"),
    "archive.record_ids": ("备份文件里的记录编号不对", "Wrong record ids in the backup"),
    "archive.date_source": ("备份文件里的日期来源不对", "Wrong date source in the backup"),
    "archive.date_point": ("备份文件里的日期或坐标不对", "Wrong date or coordinates in the backup"),
    "archive.place_source": ("备份文件里的地点来源不对", "Wrong place source in the backup"),
    "archive.two_current": ("同一张照片有两条当前记录", "One photo has two current records"),
    "archive.boxes": ("备份文件里的框不对", "Wrong boxes in the backup"),
    "archive.species_state": ("备份文件里的鸟种状态不对", "Wrong species state in the backup"),
    "archive.count": ("备份文件里的数量不对", "Wrong count in the backup"),
    "archive.count_fix": ("备份文件里的观察数量更正不对", "Wrong observation count correction in the backup"),
    "archive.totals": ("备份文件的计数和内容不一致", "The backup's totals do not match its contents"),
    "archive.blob_check": ("原图校验没通过，没有导入", "An original failed its check; nothing was imported"),
    # ---- xmp.py (skip reasons: the dialog's counts) ----
    "xmp.skip_format": ("JPEG / DNG：Lightroom 把它们的元数据写在文件里面，观羽不改原片",
                        "JPEG / DNG: Lightroom keeps their metadata inside the file, and BirdCM does not change originals"),
    "xmp.skip_pending": ("还没识别完", "Not identified yet"),
    "xmp.skip_missing": ("原片不在了", "The original is gone"),
    "xmp.skip_odd": ("旁边的 .xmp 不是普通文件（链接或文件夹），没动它", "The .xmp beside it is not a plain file (a link or a folder); left alone"),
    "xmp.skip_bad": ("旁边的 .xmp 读不了（不是有效的 XML），没动它", "The .xmp beside it cannot be read (not valid XML); left alone"),
    "xmp.skip_empty": ("没有星级也没有鸟种，不用写", "No stars and no species; nothing to write"),
    "xmp.exiftool_failed": ("exiftool 没写成", "exiftool did not write it"),
    "xmp.cannot_write": ("写不进去：{e}", "Cannot write: {e}"),
    "xmp.newline": ("字段含换行，拒绝交给 exiftool：{x}", "A field with a line break; not passed to exiftool: {x}"),
    "xmp.kept_changed": ("我们写入后又被改过（Lightroom 或你自己），没动它", "Changed after we wrote it (by Lightroom or you); left alone"),
    "xmp.kept_deleted": ("已经被删了", "Already deleted"),
    # ---- online.py (why / credit / changes are cached: stored as codes) ----
    "online.disclosure": (
        "在线资料会把你打开的鸟种学名或来源编号发送给 Wikipedia / Wikimedia，以及你启用的图片来源。只有点击「在线查名称/百科」才发送"
        "输入的搜索词。不会发送你的照片、拍摄信息或观察记录；除下面的地名外也不发送位置。网站也会接收到网络连接所需的 IP 地址等信息。关闭后仍可离线搜索、"
        "查看自己的记录和已经缓存的资料；可另行删除网络缓存。"
        "「用网络显示地名」只把要显示地名的经纬度（取到约 1 公里）发送给 OpenStreetMap Nominatim，换成地名后存在本机；关闭后显示离线的地区名。",
        "Online reference sends the scientific name or source id of the species you open to Wikipedia / Wikimedia and the "
        "image sources you enable. The search words you type are sent only when you click “Look up online”. Your photos, "
        "shooting info and observations are never sent, and no location except the place names below. The sites also "
        "receive what a network connection needs, such as your IP address. When it is off you can still search offline "
        "and see your own records and anything already cached; the network cache can be deleted separately. "
        "“Show place names from the network” sends only the latitude and longitude of the place to name (rounded to about "
        "1 km) to OpenStreetMap Nominatim, and keeps the name on this computer; when it is off the offline region names are shown."),
    "online.wiki_zh": ("维基百科（中文）", "Wikipedia (Chinese)"),
    "online.wikidata_differs": ("Wikidata（来源分类与 AviList 不同）", "Wikidata (its taxonomy differs from AviList)"),
    "online.unmapped": ("资料未对应：没有映射数据", "Not matched: no mapping data"),
    "online.taxonomy_differs": ("来源分类与 AviList 不同（{note}），不显示在线资料", "The source's taxonomy differs from AviList ({note}); online reference not shown"),
    "online.unverified": ("资料未对应：映射里没有这个物种的已核验条目", "Not matched: the mapping has no verified entry for this species"),
    "online.file_gone": ("来源上已没有这个文件", "The source no longer has this file"),
    "online.text_old": ("缓存的简介已超过 180 天，只保留来源链接", "The cached summary is over 180 days old; only the source link is kept"),
    "online.no_article": ("维基百科没有这个物种的中文或英文条目", "Wikipedia has no Chinese or English article on this species"),
    "online.article_gone": ("{lang} 条目已不存在", "The {lang} article no longer exists"),
    "online.article_wrong": ("{lang} 条目与这个物种不对应（消歧义或 Wikidata 条目不符）", "The {lang} article is not this species (a disambiguation page or another Wikidata item)"),
    "online.credit_wiki": ("维基百科贡献者", "Wikipedia contributors"),
    "online.changes_extract": ("原文摘录", "Excerpt of the original"),
    "online.changes_extract_zh": ("原文摘录；简体由维基百科自动转换", "Excerpt of the original; Simplified Chinese converted by Wikipedia"),
    "online.non_free": ("非自由文件", "not a free file"),
    "online.deletion": ("文件正在删除讨论中", "the file is up for deletion"),
    "online.restricted": ("文件带额外限制", "the file has extra restrictions"),
    "online.no_author": ("缺可靠的作者署名", "no reliable author credit"),
    "online.licence": ("许可不在白名单：{name}", "licence not on the allow list: {name}"),
    "online.unknown": ("未知", "unknown"),
    "online.no_wikidata_image": ("Wikidata 没有这个物种的图片", "Wikidata has no image of this species"),
    "online.no_commons_file": ("Commons 上找不到这个文件", "The file is not on Commons"),
    "online.no_licensed_image": ("暂无可用的授权参考图（{why}）", "No usable licensed reference image ({why})"),
    "online.not_image": ("不是图片", "not an image"),
    "online.changes_scaled": ("缩放为 640 px 宽", "Scaled to 640 px wide"),
    # ---- admin.py (the menu bar app and `birdcm admin`) ----
    "admin.running": ("观羽引擎已经在运行", "The BirdCM engine is already running"),
    "admin.other_program": ("另一个程序", "another program"),
    "admin.holder": ("{cmd}（pid {pid}）", "{cmd} (pid {pid})"),
    "admin.port_busy": ("端口 {port} 被 {who}占用", "Port {port} is in use by {who}"),
    "admin.started": ("观羽引擎启动", "BirdCM engine started"),
    "admin.stop_first_db": ("先停止服务，再删除数据库", "Stop the engine before deleting the database"),
    "admin.env_set": ("{env} 由环境变量指定，这里不能更改", "{env} is set by an environment variable and cannot be changed here"),
    "admin.stop_first_move": ("先停止服务再移动", "Stop the engine before moving"),
    "admin.not_dir": ("不是文件夹：{p}", "Not a folder: {p}"),
    "admin.not_empty": ("{p} 里已经有内容，请选一个空文件夹", "{p} is not empty; choose an empty folder"),
    "admin.into_itself": ("不能移到它自己里面", "Cannot move it into itself"),
    "admin.photo_folder": ("{p} 在扫描过的照片文件夹 {f} 里面；观羽不往照片文件夹里写东西，请选别处",
                           "{p} is inside the scanned photo folder {f}; BirdCM never writes into photo folders, choose another place"),
    "admin.copy_incomplete": ("复制不完整（{copied} / {moved} 字节），原位置未改动", "The copy is incomplete ({copied} / {moved} bytes); the original location is unchanged"),
    "admin.sha_mismatch": ("sha256 不符", "sha256 mismatch"),
    "admin.stop_first_models": ("先停止服务再删除模型", "Stop the engine before deleting the models"),
}


_LANG: ContextVar[str | None] = ContextVar("birdcm_lang", default=None)


def pick(value: str | None) -> str | None:
    """A language tag or locale (Accept-Language's first entry, LANG) -> "zh" / "en"; None when it says nothing."""
    v = (value or "").split(",")[0].split(";")[0].strip().lower()
    if not v or v == "*" or v.startswith(("c.", "posix")) or v == "c":
        return None
    return "zh" if v.startswith("zh") else "en"


def env_lang() -> str:
    for k in ("BIRDCM_LANG", "LC_ALL", "LC_MESSAGES", "LANG"):
        if os.environ.get(k):
            return pick(os.environ[k]) or "zh"
    return "zh"


def lang() -> str:
    return _LANG.get() or env_lang()


def use(code: str | None):
    """Set the language for this context (one API request); returns the token for reset()."""
    return _LANG.set(code)


def reset(token) -> None:
    _LANG.reset(token)


def t(key: str, /, **params) -> str:
    s = MSG[key][lang() == "en"]
    return s.format(**params) if params else s


def R(key: str, /, **params) -> list:
    """A stored message: [key, params], rendered by text() in the reader's language."""
    assert key in MSG, key
    return [key, params]


def _param(v, en: bool):
    if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and v[0] in MSG:
        return text(v)
    if isinstance(v, dict) and "sci" in v:                         # a bird's {zh, en, sci}
        return (v.get("en") if en else v.get("zh") or v.get("en")) or v.get("sci") or MSG["stars.unnamed"][en]
    return v


_ZH: dict[str, str] | None = None


def text(v):
    """A stored message in the current language: a code -> rendered; an older Chinese sentence that is a fixed message
    -> that message; anything else as it is (None stays None)."""
    global _ZH
    en = lang() == "en"
    if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and v[0] in MSG:
        s = MSG[v[0]][en]
        return s.format(**{k: _param(x, en) for k, x in v[1].items()}) if v[1] else s
    if isinstance(v, str) and en:
        if _ZH is None:
            _ZH = {zh: k for k, (zh, _) in MSG.items() if "{" not in zh}
        k = _ZH.get(v)
        return MSG[k][1] if k else v
    return v


def legacy(v) -> bool:
    """An older stored sentence that text() cannot put into English (a Chinese sentence with parameters)."""
    return isinstance(v, str) and lang() == "en" and text(v) == v and any("一" <= c <= "鿿" for c in v)
