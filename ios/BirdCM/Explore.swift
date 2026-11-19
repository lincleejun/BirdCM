import SwiftUI

/// §6.2 “这里这个月”: geo prior (median = score, max = inclusion support) + GBIF record share for a place and month.
/// Read-only and offline; independent of the identification Engine. Kept as plain values so a future online source
/// (pictures / text) can sit beside it without changing this layer.
struct Likely: Identifiable {
    let sci: String
    let median: Double?, max: Double?     // nil = unknown prior, never 0
    let share: Double?, tier: Int?        // GBIF record share / tier in the source region-month
    var id: String { sci }
}
struct LikelyResult { var rows: [Likely]; var geo: Bool; var gbif: Bool; var coverage: String? }

enum Likelihood {
    private static var geo: Geo?
    private static var cache = [(String, LikelyResult)]()       // session LRU, at most four place/month results
    private static let lock = NSLock()
    static func compute(place: Place, month: Int, catalogue: Catalogue) -> LikelyResult {
        let key = "\(place.stableCode)|\(place.source)|\(month)|\(Catalogue.resourceVersions)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache.first(where: { $0.0 == key }) { return hit.1 }
        if geo == nil, FileManager.default.fileExists(atPath: Models.geoURL.path) { geo = try? Geo(weights: Models.geoURL, scientific: catalogue.all.map(\.sci)) }
        // Month-only query uses its 15th day; a region choice spreads over the whole region grid (Geo.cover).
        let spread = geo.flatMap { try? $0.spread(place, date: String(format: "2026-%02d-15", month)) }
        let gbif = (try? Rarity(path: Models.rarityURL))?.monthCounts(place, month: month)
        var rows = [Likely]()
        for (i, sp) in catalogue.all.enumerated() {
            let med = spread.flatMap { $0.typical[i].isNaN ? nil : $0.typical[i] }, mx = spread.flatMap { $0.wide[i].isNaN ? nil : $0.wide[i] }
            let c = gbif?.counts[sp.sci]
            guard (mx ?? 0) >= 0.01 || (c?.n ?? 0) > 0 else { continue }
            rows.append(Likely(sci: sp.sci, median: med, max: mx, share: c.map { Double($0.n) / Double(max(1, gbif!.total)) }, tier: c?.tier))
        }
        let result = LikelyResult(rows: rows, geo: spread != nil, gbif: gbif != nil, coverage: gbif?.coverage)
        cache.insert((key, result), at: 0); if cache.count > 4 { cache.removeLast() }
        return result
    }
    /// Known median desc, then GBIF share desc, then scientific name; unknown prior after known.
    static func likelihoodOrder(_ a: Likely, _ b: Likely) -> Bool {
        switch (a.median, b.median) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (a.share ?? -1, b.sci) > (b.share ?? -1, a.sci)
        }
    }
}

/// 探索: whole catalogue or “这里这个月”, with seen / rarity / IUCN / family filters.
struct ExploreView: View {
    @Environment(AppModel.self) var model
    #if DEBUG
    /// Snapshot tests open the tab with a search already typed.
    @State private var query = UserDefaults.standard.string(forKey: "exploreQuery") ?? ""
    #else
    @State private var query = ""
    #endif
    @State private var mode = "local"
    @State private var seen = "all"
    @State private var tier = 0
    @State private var threatened = false
    @State private var family = ""
    @State private var sort = "likely"
    @State private var month = Calendar(identifier: .gregorian).component(.month, from: Date())
    @State private var likely: LikelyResult?
    @State private var computing = false
    @State private var results = [Catalogue.Species]()
    @State private var limit = 50
    @State private var choosePlace = false
    @State private var iucn = [String: String]()
    var local: Bool { mode == "local" && model.homePlace != nil }
    var body: some View {
        List {
            Section {
                Picker("范围", selection: $mode) { Text("这里这个月").tag("local"); Text("全部物种").tag("all") }.pickerStyle(.segmented).accessibilityIdentifier("explore.mode")
                if mode == "local" {
                    Button { choosePlace = true } label: { LabeledContent("地点", value: model.placeName(model.homePlace) ?? String(localized: "选择地点")) }.accessibilityIdentifier("explore.place")
                    Picker("月份", selection: $month) { ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) } }.accessibilityIdentifier("explore.month")
                }
                Picker("已见", selection: $seen) { Text("全部").tag("all"); Text("已见").tag("seen"); Text("未见").tag("unseen") }.pickerStyle(.segmented).accessibilityIdentifier("explore.filter")
                if local {
                    Picker("本地频次", selection: $tier) { Text("不限").tag(0); Text("罕见").tag(1); Text("少见").tag(2); Text("不常见").tag(3); Text("常见").tag(4) }.accessibilityIdentifier("explore.tier")
                    Picker("排序", selection: $sort) { Text("可能性").tag("likely"); Text("观测记录份额").tag("share"); Text("名称").tag("name"); Text("未见优先").tag("unseen") }.accessibilityIdentifier("explore.sort")
                }
                if !UserDefaults.standard.bool(forKey: "hideIUCN") { Toggle("只看 IUCN 受威胁", isOn: $threatened).accessibilityIdentifier("explore.threatened") }
                Picker("科", selection: $family) { Text("全部科").tag(""); ForEach(Array(Set(model.catalogue.all.map(\.family))).sorted(), id: \.self) { Text($0).tag($0) } }.accessibilityIdentifier("explore.family")
            } footer: {
                if mode == "local" {
                    if model.homePlace == nil { Text("还没有地点：先选择地点；下面先列出全部物种。") }
                    else if let likely {
                        Text(likely.geo ? (likely.gbif ? "按地点模型（中位数）与 GBIF 观测记录排序。\(likely.coverage == "country" ? "按全国数据估计。" : "")" : "地点模型不可用，按观测记录排序。") : (likely.gbif ? "" : "这个地方这个月没有观测数据，列出全部物种，不作“可能见到”判断。"))
                            + Text(" 表示适宜度与被报告的程度，不是散步时见到的概率。“未见”= 全部记录里还没有。")
                    }
                } else { Text("离线搜索 \(model.catalogue.all.count) 种（中文、英文、学名、拼音或首字母）。没有内置参考图片或介绍。") }
            }
            Section(header: Text(header)) {
                if computing { ProgressView("正在计算这里这个月的鸟…").accessibilityIdentifier("explore.computing") }
                ForEach(results.prefix(limit)) { sp in row(sp) }
                if results.count > limit { Button("再显示 50 种") { limit += 50 }.frame(minHeight: 44).accessibilityIdentifier("explore.more") }
                if results.isEmpty && !computing { Text(seen == "seen" ? "还没有已见的鸟种。" : "没有匹配的鸟种。").accessibilityIdentifier("explore.empty") }
            }
        }
        .scrollContentBackground(.hidden).background(Palette.canvas)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("搜索全部鸟种"))
        .task { await model.catalogue.preparePinyin() }
        .task(id: "\(mode)|\(month)|\(model.homePlace?.stableCode ?? "")") {
            guard mode == "local", let place = model.homePlace else { likely = nil; return }
            computing = true; defer { computing = false }
            let catalogue = model.catalogue, m = month
            likely = await Task.detached { Likelihood.compute(place: place, month: m, catalogue: catalogue) }.value
        }
        .task(id: "\(query)|\(seen)|\(tier)|\(threatened)|\(family)|\(sort)|\(likely?.rows.count ?? -1)|\(mode)|\(model.ledger.allTime.count)") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            // Same read as every other screen (Rarity.iucn); near-threatened and worse get a badge on the row.
            if iucn.isEmpty, let db = model.catalogue.rarity { iucn = db.iucn(codes: ["NT", "VU", "EN", "CR", "EW", "EX"]) }
            results = filtered(); limit = 50
        }
        .sheet(isPresented: $choosePlace) { PlacePicker(onChoose: { model.chooseHome($0) }).debugAppearance() }
        .navigationTitle("探索")
    }
    var header: String {
        local ? "这里这个月可能见到的鸟 · \(results.count)" : query.isEmpty ? "按学名排列 · \(results.count)" : "搜索结果 · \(results.count)"
    }
    func filtered() -> [Catalogue.Species] {
        let seenSet = model.ledger.allTime
        var list = model.catalogue.search(query)
        if local, let likely {
            let by = Dictionary(uniqueKeysWithValues: likely.rows.map { ($0.sci, $0) })
            list = list.filter { by[$0.sci] != nil && (tier == 0 || by[$0.sci]?.tier == tier) }
            if query.isEmpty {
                list.sort { a, b in
                    let x = by[a.sci]!, y = by[b.sci]!
                    switch sort {
                    case "share": return (x.share ?? -1, b.sci) > (y.share ?? -1, a.sci)
                    case "name": return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    case "unseen": let u = (seenSet[a.sci] == nil, seenSet[b.sci] == nil); return u.0 != u.1 ? u.0 : Likelihood.likelihoodOrder(x, y)
                    default: return Likelihood.likelihoodOrder(x, y)
                    }
                }
            }
        }
        return list.filter { (seen == "all" || (seenSet[$0.sci] != nil) == (seen == "seen")) && (family.isEmpty || $0.family == family) && (!threatened || RarityBook.threatened.contains(iucn[$0.sci] ?? "")) }
    }
    func row(_ sp: Catalogue.Species) -> some View {
        let l = likely?.rows.first { $0.sci == sp.sci }
        return NavigationLink(value: AppModel.Route.species(sp.sci)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sp.zh.isEmpty ? sp.en : sp.zh)
                    Text(sp.zh.isEmpty ? "暂无中文名 · " + sp.sci : sp.en + " · " + sp.sci).font(.caption).foregroundStyle(Palette.secondary)
                    if local, let l {
                        Text([l.median.map { "地点模型 \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? "地点模型未知", l.share.map { "观测记录 \($0.formatted(.percent.precision(.fractionLength(2))))" }, l.tier.map { ["无记录", "罕见", "少见", "不常见", "常见"][max(0, min(4, $0))] }].compactMap { $0 }.joined(separator: " · ")).font(.caption2).monospacedDigit()
                    }
                }
                Spacer()
                if let code = iucn[sp.sci] { IUCNChip(code: code, small: true) }
                if model.ledger.allTime[sp.sci] != nil { Label("已见", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(Palette.accent) }
            }.frame(minHeight: 44)
        }.accessibilityIdentifier("explore.row.\(sp.sci)")
    }
}
