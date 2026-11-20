import SwiftUI

/// §6.2 “这里这个月”: the geo model's value this month at the place (the point itself; a region by the median over its
/// grid) + GBIF record share for the place and month. Read-only and offline; independent of the identification Engine.
struct Likely: Identifiable {
    let sci: String
    let median: Double?                   // this month's model value; nil = unknown prior, never 0
    let share: Double?, tier: Int?        // GBIF record share / tier in the source region-month
    let months: [Double]?                 // 12 monthly model values at the place
    /// Only sparse GBIF records or a low model value: the collapsed 罕见 / 偶见 section, not the main list.
    let rare: Bool
    var id: String { sci }
    /// The row's local word: the GBIF tier when the table covers the month, else the model's word (Geo.modelTier).
    var label: String? { tier.map { Likelihood.tierNames[max(0, min(4, $0))] } ?? median.map(Geo.modelTier) }
}
/// `months`: every catalogue species (by catalogue index) at the place, nil where the model has no such species.
struct LikelyResult { var rows: [Likely]; var geo: Bool; var gbif: Bool; var coverage: String?; var months: [[Double]?] = [] }

enum Likelihood {
    static let tierNames = ["无记录", "罕见", "少见", "不常见", "常见"]
    /// Main list: this month's model value at the place at least typicalFloor AND, where GBIF covers the region-month,
    /// a tier of 不常见 and up (owner, 2026-11-19, Cupertino in November: either-or listed 287–462 species because the
    /// tier is state-wide and the model is generous; both together list 196). No GBIF coverage: the model alone. The
    /// rest with a model value ≥ rareFloor or any GBIF record (罕见, single vagrants included) goes to 罕见 / 偶见.
    static let typicalFloor = 0.5
    static let mainTier = 3
    static let rareFloor = 0.01
    enum Inclusion: Equatable { case main, rare }
    static func inclusion(typical: Double?, tier: Int?) -> Inclusion? {
        if (typical ?? 0) >= typicalFloor && (tier.map { $0 >= mainTier } ?? true) { return .main }
        if (typical ?? 0) >= rareFloor || (tier ?? 0) >= 1 { return .rare }
        return nil
    }
    private static var cache = [(String, LikelyResult)]()       // session LRU, at most four place/month results
    private static let lock = NSLock()
    static func compute(place: Place, month: Int, catalogue: Catalogue) -> LikelyResult {
        let key = "\(place.stableCode)|\(place.source)|\(month)|\(Catalogue.resourceVersions)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache.first(where: { $0.0 == key }) { return hit.1 }
        // The year at the place, reused for any month (and by the species page).
        let months = cache.first(where: { $0.0.hasPrefix("\(place.stableCode)|\(place.source)|") && !$0.1.months.isEmpty })?.1.months
            ?? Geo.shared(catalogue).flatMap { try? $0.months(at: place) }
        let gbif = (try? Rarity(path: Models.rarityURL))?.monthCounts(place, month: month)
        var rows = [Likely]()
        for (i, sp) in catalogue.all.enumerated() {
            let year = months?[i], med = year?[month - 1]
            // Covered month without this species: tier 0 (无记录), as on the result page.
            let c = gbif?.counts[sp.sci], tier = gbif == nil ? nil : c.map { $0.n > 0 ? max(1, $0.tier) : 0 } ?? 0
            guard let fit = inclusion(typical: med, tier: tier) else { continue }
            rows.append(Likely(sci: sp.sci, median: med, share: c.map { Double($0.n) / Double(max(1, gbif!.total)) }, tier: tier, months: year, rare: fit == .rare))
        }
        let result = LikelyResult(rows: rows, geo: months != nil, gbif: gbif != nil, coverage: gbif?.coverage, months: months ?? [])
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
    @State private var rareResults = [Catalogue.Species]()
    @State private var byKey = [String: Likely]()
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
                        Text(likely.geo ? (likely.gbif ? "按地点模型与 GBIF 观测记录排序。\(likely.coverage == "country" ? String(localized: "按全国数据估计。") : "")" : "按地点模型排序；这个地方这个月没有观测数据。") : (likely.gbif ? "地点模型不可用，按观测记录排序。" : "这个地方这个月没有观测数据，列出全部物种，不作“可能见到”判断。"))
                            + Text(" 表示适宜度与被报告的程度，不是散步时见到的概率；只有零星记录或模型值很低的鸟列在最后的“罕见 / 偶见”里。小条是这里全年 12 个月的模型估计（相对该鸟最可能的月份），下划线是所选月份。“未见”= 全部记录里还没有。")
                    }
                } else { Text("离线搜索 \(model.catalogue.all.count) 种（中文、英文、学名、拼音或首字母）。没有内置参考图片或介绍。") }
            }
            Section(header: Text(header)) {
                if computing { ProgressView("正在计算这里这个月的鸟…").accessibilityIdentifier("explore.computing") }
                // Every row, no paging (owner 2026-11-19): List builds rows lazily; a row only reads precomputed values.
                ForEach(results) { sp in row(sp) }
                if results.isEmpty && rareResults.isEmpty && !computing { Text(seen == "seen" ? "还没有已见的鸟种。" : "没有匹配的鸟种。").accessibilityIdentifier("explore.empty") }
            }
            if local && !rareResults.isEmpty {
                Section {
                    ForEach(rareResults) { sp in row(sp) }
                } header: { Text("罕见 / 偶见 · \(rareResults.count)").accessibilityIdentifier("explore.rare") }
                  footer: { Text("只有零星观测记录，或地点模型估计很低：可能是迷鸟或偶尔路过。") }
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
            let all = filtered()
            byKey = Dictionary(uniqueKeysWithValues: (likely?.rows ?? []).map { ($0.sci, $0) })
            results = local ? all.filter { byKey[$0.sci]?.rare != true } : all
            rareResults = local ? all.filter { byKey[$0.sci]?.rare == true } : []
        }
        .sheet(isPresented: $choosePlace) { PlacePicker(onChoose: { model.chooseHome($0) }).debugAppearance() }
        .navigationTitle("探索")
    }
    var header: String {
        local ? String(localized: "这里这个月可能见到的鸟 · \(results.count)") : query.isEmpty ? String(localized: "按学名排列 · \(results.count)") : String(localized: "搜索结果 · \(results.count)")
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
        let l = local ? byKey[sp.sci] : nil
        return NavigationLink(value: AppModel.Route.species(sp.sci)) {
            HStack(spacing: 12) {
                SpeciesThumb(key: sp.sci, size: 64)
                VStack(alignment: .leading, spacing: 8) {
                    SpeciesName(title: sp.name, alt: sp.alt, sci: sp.sci, size: .row)
                    // Facts under the name so the name keeps the row's width. Text carries the local word; the colored
                    // capsule (罕见 / 少见, as on the result page) only reinforces it.
                    let seen = model.ledger.allTime[sp.sci] != nil, code = iucn[sp.sci]
                    if l != nil || seen || code != nil {
                        let tags = Group {
                            if let l { localTag(l) }
                            if let code { IUCNChip(code: code, small: true) }
                            if seen { Label("已见", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Palette.secondary).fixedSize() }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { tags; if let m = l?.months { MonthStrip(values: m, current: month) } }
                            VStack(alignment: .leading, spacing: 4) { HStack(spacing: 8) { tags }; if let m = l?.months { MonthStrip(values: m, current: month) } }
                            VStack(alignment: .leading, spacing: 4) { tags; if let m = l?.months { MonthStrip(values: m, current: month) } }
                        }
                    }
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 64)
        }.accessibilityIdentifier("explore.row.\(sp.sci)")
    }
    @ViewBuilder func localTag(_ l: Likely) -> some View {
        if let word = l.label {
            StateTag(text: l.tier == nil ? String(localized: "估计：\(loc(word))") : String(localized: "本地：\(loc(word))"), state: ThemeContrast.rarity[word] ?? ThemeContrast.unavailable, strong: ["罕见", "少见"].contains(word), small: true).fixedSize()
        }
    }
}

/// Twelve small bars of the model's monthly values at a place, each relative to the species' own best month; the
/// `current` month is outlined. Read by VoiceOver as the peak months.
struct MonthStrip: View {
    let values: [Double]
    let current: Int
    var body: some View {
        let top = max(values.max() ?? 0, 0.001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<12, id: \.self) { i in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.accent.opacity(0.12 + 0.88 * values[i] / top)).frame(width: 6, height: 14)
                    // The selected month: a small ink tick under its bar.
                    Capsule().fill(i + 1 == current ? Palette.ink : .clear).frame(width: 6, height: 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("全年：\(values.indices.filter { values[$0] >= top * 0.8 }.map { "\($0 + 1)" }.joined(separator: String(localized: "、"))) 月最可能")
    }
}
