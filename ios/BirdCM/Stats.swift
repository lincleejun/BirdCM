import MapKit
import SwiftUI

/// GBIF tiers per observation at its own place and month (§3.3), computed off the main actor with a private table connection.
struct RarityBook {
    var tiers = [String: [Int]]()          // observation id → known tiers of its supporting evidence
    var unavailable = Set<String>()
    var iucn = [String: String]()          // species → IUCN code (empty when hidden)
    static let labels = ["无记录": 0, "罕见": 1, "少见": 2, "不常见": 3, "常见": 4]
    static func compute(_ ledger: Ledger, _ range: (String, String)?) -> RarityBook {
        var book = RarityBook()
        guard let db = try? Rarity(path: Models.rarityURL) else { book.unavailable = Set(ledger.observations.map(\.id)); return book }
        // One GBIF month table per (region, month), read once; species tiers are dictionary lookups (no tier = 无记录).
        var months = [String: [String: (n: Int, tier: Int)]?]()
        let inTable = Set(db.rows("SELECT scientific FROM species", []).map { $0[0] })     // absent = unknown, not 无记录
        for o in ledger.observations where Ledger.inRange(o.day, range) {
            guard let month = Int(o.day.dropFirst(5).prefix(2)), inTable.contains(o.species) else { book.unavailable.insert(o.id); continue }
            var known = [Int]()
            for item in ledger.evidence(o) {
                // ponytail: region cached per place bucket (≈1 km); region edges inside one bucket are ignored.
                let r = item.lat.map { db.regionAt(lat: $0, lon: item.lon!, bucket: item.placeKey) }
                guard let code = item.region ?? r?.division ?? r?.country else { continue }
                let key = "\(code)|\(month)"
                if months[key] == nil { months[key] = .some(db.monthCounts(Place(lat: 0, lon: 0, label: "", source: "region", regionCode: code), month: month)?.counts) }
                if let table = months[key] ?? nil { known.append(table[o.species]?.tier ?? 0) }
            }
            if known.isEmpty { book.unavailable.insert(o.id) } else { book.tiers[o.id] = known }
        }
        if !UserDefaults.standard.bool(forKey: "hideIUCN") {
            for k in Set(ledger.observations.filter { Ledger.inRange($0.day, range) }.map(\.species)) { if let c = db.iucn(k) { book.iucn[k] = c } }
        }
        return book
    }
    func rare(_ id: String) -> Bool { tiers[id]?.contains { $0 == 1 || $0 == 2 } == true }
    /// Disjoint buckets: the minimum known tier (0 stays 无记录); unavailable when none is known.
    func bucket(_ id: String) -> Int? { tiers[id]?.min() }
    static let threatened: Set<String> = ["VU", "EN", "CR"]
}

/// 统计: scoped summary, photo calendar, rarity, map and observation list.
struct StatsView: View {
    @Environment(AppModel.self) var model
    @State private var period = Period.current()
    @State private var book: RarityBook?
    @State private var day: String?
    @State private var ebird = false
    var kind: String { switch period { case .month: return "month"; case .year: return "year"; case .all: return "all" } }
    func setKind(_ k: String) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        switch (k, period) {
        case ("month", .year(let y)): period = .month(y, y == c.year ? c.month! : 12)
        case ("month", _): period = .current()
        case ("year", .month(let y, _)): period = .year(y)
        case ("year", _): period = .year(c.year!)
        default: period = .all
        }
    }
    /// polish.md: open numbers, no box; tabular digits; orange only for the 新种 number.
    func tile(_ title: LocalizedStringKey, _ value: Int, _ id: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(.largeTitle, weight: .bold)).monospacedDigit().foregroundStyle(highlight && value > 0 ? Palette.newSpecies : Palette.ink)
            Text(title).font(.subheadline).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            .accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }
    var body: some View {
        let s = model.ledger.summary(period.range)
        let today = String(Library.wall(Date(), zone: .current).0.prefix(10))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("范围", selection: Binding(get: { kind }, set: setKind)) { Text("本月").tag("month"); Text("本年").tag("year"); Text("全部").tag("all") }.pickerStyle(.segmented).accessibilityIdentifier("stats.period")
                HStack {
                    Button { period = period.shifted(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上一段").accessibilityIdentifier("stats.previous").disabled(period == .all)
                    Spacer()
                    VStack {
                        Text(period.title).font(.headline)
                        Text(period.range.map { "\($0.0) – \($0.1)" } ?? String(localized: "全部日期")).font(.caption).monospacedDigit().foregroundStyle(Palette.secondary)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("stats.range")
                    Spacer()
                    Button { period = period.shifted(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下一段").accessibilityIdentifier("stats.next").disabled(period == .all)
                }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow { tile("鸟种", s.species, "stats.species"); tile("观察记录", s.observations, "stats.observations") }
                    GridRow { tile("估计数量", s.estimate, "stats.estimate"); tile("新种", s.newSpecies, "stats.newSpecies", highlight: true) }
                }
                Text("照片 \(s.photos) 张 · 待确认 \(s.pending) 个（\(s.pendingPhotos) 张）· 没找到鸟 \(s.noBird) 张").font(.subheadline).monospacedDigit().accessibilityIdentifier("stats.coverage")
                Text("观察记录 = 同一鸟种、同一天、同一地点合为一次；估计数量取同日同地点单张照片的最大值，可能重复见到同一只鸟；地点未知的同日记录合并，可能低估次数。新种 = 这段时间里第一次记录到的鸟种。").font(.caption).foregroundStyle(Palette.secondary)
                let future = model.ledger.observations.filter { $0.day > today && Ledger.inRange($0.day, period.range) }.count
                if future > 0 { Label("\(future) 条观察记录的日期在今天之后，请检查相机时间", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.warning) }
                if s.species == 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这段时间还没有确定到种的记录。").accessibilityIdentifier("stats.empty")
                        if s.pending > 0 { Button("去确认 \(s.pending) 个主体") { model.recordsMode = "pending"; model.tab = .records }.buttonStyle(.bordered) }
                    }
                }
                PhotoCalendar(period: $period, open: { day = $0 })
                if s.species > 0 {
                    HStack {
                        NavigationLink { SightingMap(range: period.range) } label: { Label("地图", systemImage: "map").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("stats.map")
                        NavigationLink { SightingList(title: period.title, range: period.range, day: nil) } label: { Label("观察记录", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("stats.observationList")
                    }
                    Button { ebird = true } label: { Label("导出 eBird 文件", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("stats.ebird")
                    rarity(s)
                    Text("鸟种 · \(s.list.count)").font(.headline)
                    ForEach(s.list) { st in
                        NavigationLink(value: AppModel.Route.species(st.id)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 8) {
                                    SpeciesName(key: st.id, size: .row)
                                    Text("\(st.observations) 次观察 · 估计 \(st.estimate) · \(st.photos.count) 张 · 最近 \(st.last)").font(.caption).foregroundStyle(Palette.tertiary).monospacedDigit()
                                }
                                Spacer()
                                if Ledger.inRange(model.ledger.allTime[st.id]?.first ?? "", period.range) { NewBadge() }
                                Image(systemName: "chevron.right").font(.caption)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("stats.row.\(st.id)")
                        Divider()
                    }
                }
            }.padding(16).padding(.bottom, 24)
        }
        .background(Palette.canvas)
        .navigationTitle("统计")
        .sheet(isPresented: $ebird) { EBirdSheet(title: period.title, range: period.range).debugAppearance() }
        .navigationDestination(item: $day) { d in SightingList(title: d, range: (d, d), day: d) }
        .task(id: "\(period)|\(model.ledger.observations.count)|\(model.ledger.items.count)") {
            book = nil
            let ledger = model.ledger, range = period.range
            book = await Task.detached { RarityBook.compute(ledger, range) }.value
        }
    }
    @ViewBuilder func rarity(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本地稀有度与受威胁鸟种").font(.headline)
            if let book {
                let obs = model.ledger.observations.filter { Ledger.inRange($0.day, period.range) }
                let rare = obs.filter { book.rare($0.id) }
                Text("本地罕见 / 少见：\(rare.count) 条观察记录").font(.subheadline).accessibilityIdentifier("stats.rare")
                ForEach(rare.prefix(20)) { o in
                    HStack(alignment: .firstTextBaseline) { SpeciesName(key: o.species, size: .row); Spacer(); Text(o.day).font(.caption).foregroundStyle(Palette.tertiary).monospacedDigit() }
                        .accessibilityElement(children: .combine)
                }
                let labels = [String(localized: "无记录"), String(localized: "罕见"), String(localized: "少见"), String(localized: "不常见"), String(localized: "常见")]
                let buckets = Dictionary(grouping: obs) { book.bucket($0.id) }.mapValues(\.count)
                Text((0...4).map { "\(labels[$0]) \(buckets[$0] ?? 0)" }.joined(separator: " · ") + String(localized: " · 无数据 \(buckets[nil] ?? 0)")).font(.caption).monospacedDigit().accessibilityIdentifier("stats.rarityBuckets")
                Text("按每条记录自己的地点和月份查 GBIF 观测记录份额；一条记录有多个地点时取最少见的一档。记录数不是实际种群数量。").font(.caption2).foregroundStyle(Palette.secondary)
                if !UserDefaults.standard.bool(forKey: "hideIUCN") {
                    let threatened = book.iucn.filter { RarityBook.threatened.contains($0.value) }.sorted { $0.key < $1.key }
                    Text("IUCN 受威胁（易危 / 濒危 / 极危）：\(threatened.count) 种").font(.subheadline).accessibilityIdentifier("stats.threatened")
                    ForEach(threatened, id: \.key) { k, v in HStack { SpeciesName(key: k, size: .row); Spacer(); IUCNChip(code: v, small: true) }.accessibilityElement(children: .combine) }
                }
            } else { ProgressView("正在查本地稀有度…").font(.caption) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))   // a resting panel: one quiet border, no fill, no shadow
    }
}

struct NewBadge: View {
    /// polish.md: orange is kept for 新种 alone, as text.
    var body: some View { Text("新种").font(.caption.bold()).foregroundStyle(Palette.newSpecies) }
}

/// Photo-first calendar (owner, 2026-11-18): month grid of cover crops with a species badge; year = 12 month tiles.
struct PhotoCalendar: View {
    @Environment(AppModel.self) var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var period: Period
    let open: (String) -> Void
    @State private var year = Calendar(identifier: .gregorian).component(.year, from: Date())
    func cell(_ d: Ledger.Day?, _ n: Int) -> some View {
        ZStack(alignment: .topLeading) {
            if let d, let c = d.cover {
                if c.item.missing { RoundedRectangle(cornerRadius: 6).fill(Palette.inset) }
                else { CropThumbnail(url: model.url(c.item.id), id: c.item.id, boxes: c.item.boxes, crops: c.item.crops, index: c.ordinal).clipShape(RoundedRectangle(cornerRadius: 6)) }
            } else { RoundedRectangle(cornerRadius: 6).fill(Palette.inset) }
            // Every date on an opaque backing (polish.md): readable on any photo, no shadow.
            Text("\(n)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(d == nil ? Palette.secondary : Palette.ink).padding(.horizontal, 3).padding(.vertical, 1)
                .background(d == nil ? Color.clear : Palette.surface, in: RoundedRectangle(cornerRadius: 4)).padding(3)
            if let d, d.species.count > 1 {
                Text("\(d.species.count)").font(.caption2.bold()).monospacedDigit().padding(.horizontal, 4).foregroundStyle(Palette.onAccent).background(Palette.accent, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(2)
            }
        }.aspectRatio(1, contentMode: .fit)
    }
    func label(_ d: Ledger.Day) -> String {
        String(localized: "\(d.day)，\(d.cover.map { c in model.catalogue.name(c.item.subjects.first { s in s.ordinal == c.ordinal }?.key) } ?? "")，\(d.species.count) 种，\(d.observations) 条观察")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch period {
            case let .month(y, m): month(y, m)
            case let .year(y): yearTiles(y)
            case .all: allYears
            }
        }
    }
    @ViewBuilder func month(_ y: Int, _ m: Int) -> some View {
        let range = Period.month(y, m).range!
        let days = model.ledger.days(range)
        Text("日历").font(.headline).accessibilityIdentifier("stats.calendar")
        if typeSize.isAccessibilitySize {
            // Largest type: the day list alternative.
            if days.isEmpty { Text("这个月没有确定到种的记录。").font(.subheadline) }
            ForEach(days.values.sorted { $0.day > $1.day }, id: \.day) { d in
                Button { open(d.day) } label: {
                    HStack {
                        cell(d, Int(d.day.suffix(2))!).frame(width: 64)
                        VStack(alignment: .leading) { Text(d.day).font(.headline).monospacedDigit(); Text("\(d.cover.map { c in model.catalogue.name(c.item.subjects.first { $0.ordinal == c.ordinal }?.key) } ?? "") · \(d.species.count) 种 · \(d.observations) 条观察").font(.subheadline) }
                        Spacer()
                    }.accessibilityElement(children: .combine)
                }.buttonStyle(.plain).accessibilityIdentifier("calendar.day.\(d.day)")
            }
        } else {
            let first = Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: 1))!
            let lead = (Calendar(identifier: .gregorian).component(.weekday, from: first) + 5) % 7     // Monday first
            let count = Int(range.1.suffix(2))!
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array([String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六"), String(localized: "日")].enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(Palette.secondary) }
                ForEach(0..<(lead + count), id: \.self) { i in
                    if i < lead { Color.clear.aspectRatio(1, contentMode: .fit) } else {
                        let n = i - lead + 1, key = String(format: "%04d-%02d-%02d", y, m, n), d = days[key]
                        if let d {
                            Button { open(key) } label: { cell(d, n) }.buttonStyle(.plain).accessibilityLabel(label(d)).accessibilityIdentifier("calendar.day.\(key)")
                        } else { cell(nil, n).accessibilityLabel("\(key)，没有记录") }
                    }
                }
            }
        }
    }
    @ViewBuilder func yearTiles(_ y: Int) -> some View {
        Text("\(String(y)) 年各月").font(.headline).accessibilityIdentifier("stats.calendar")
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(1...12, id: \.self) { m in
                let days = model.ledger.days(Period.month(y, m).range!)
                let cover = days.values.compactMap(\.cover).max { a, b in Ledger.later(b.item, b.item.subjects.first { $0.ordinal == b.ordinal }!, than: a) }
                let species = Set(days.values.flatMap(\.species)).count, obs = days.values.reduce(0) { $0 + $1.observations }
                Button { period = .month(y, m) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Palette.inset)
                            if let cover, !cover.item.missing { CropThumbnail(url: model.url(cover.item.id), id: cover.item.id, boxes: cover.item.boxes, crops: cover.item.crops, index: cover.ordinal).clipShape(RoundedRectangle(cornerRadius: 8)) }
                        }.aspectRatio(1, contentMode: .fit)
                        Text("\(m) 月").font(.subheadline.bold())
                        Text(obs == 0 ? "无记录" : "\(species) 种 · \(obs) 条观察").font(.caption).foregroundStyle(Palette.secondary).monospacedDigit()
                    }
                }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityIdentifier("calendar.month.\(m)")
            }
        }
    }
    @ViewBuilder var allYears: some View {
        let years = Set(model.ledger.observations.compactMap { Int($0.day.prefix(4)) }).sorted()
        if !years.isEmpty {
            Picker("年份", selection: $year) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }.accessibilityIdentifier("calendar.year")
                .onAppear { if !years.contains(year) { year = years.last! } }
            yearTiles(year)
        }
    }
}

/// Observations in a range (or one day), with first-seen, rarity, and the group-level 本次观察数量 editor.
struct SightingList: View {
    @Environment(AppModel.self) var model
    let title: String
    let range: (String, String)?
    let day: String?
    @State private var editing: Sighting?
    func place(_ o: Sighting) -> String {
        o.place == "none" ? String(localized: "地点未知（同日合并）") : model.ledger.evidence(o).first.flatMap(model.placeName) ?? o.place
    }
    var body: some View {
        let list = model.ledger.observations.filter { Ledger.inRange($0.day, range) }
        List {
            if list.isEmpty { Text("没有观察记录。") }
            ForEach(list) { o in
                Button { editing = o } label: {
                    HStack(spacing: 12) {
                        if let item = model.ledger.evidence(o).first, let sub = item.subjects.first(where: { $0.key == o.species }) {
                            CropThumbnail(url: model.url(item.id), id: item.id, boxes: item.boxes, crops: item.crops, index: sub.ordinal).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                                .opensImageViewer(.photo(id: item.id, boxes: item.boxes, crops: item.crops, index: sub.ordinal))
                        }
                        // The reported bug: this list showed the Chinese name alone; it is the shared two-line block now.
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) { SpeciesName(key: o.species, size: .row); if model.ledger.allTime[o.species]?.first == o.day { NewBadge() } }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(o.day) · \(place(o))").monospacedDigit()
                                Text("估计 \(o.estimate)\(o.override != nil ? String(localized: "（你改过）") : "") · \(o.frames.count) 张").monospacedDigit()
                            }.font(.caption).foregroundStyle(Palette.tertiary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("obs.row.\(o.species).\(o.day)")
            }
        }
        .scrollContentBackground(.hidden).background(Palette.canvas)
        .navigationTitle(day.map { "\($0) 的观察" } ?? "观察记录 · \(title)").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { o in SightingSheet(sighting: o).debugAppearance() }
    }
}

struct SightingSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let sighting: Sighting
    @State private var text = ""
    var body: some View {
        let o = model.ledger.observations.first { $0.id == sighting.id } ?? sighting
        let photos = model.ledger.evidence(o)
        NavigationStack {
            Form {
                Section {
                    SpeciesName(key: o.species, size: .row)
                    LabeledContent("日期") { Text(o.day).monospacedDigit() }
                    LabeledContent("单张照片最多", value: String(localized: "\(o.frames.values.max() ?? 0) 只"))
                    LabeledContent("照片", value: String(localized: "\(o.frames.count) 张"))
                }
                Section {
                    TextField("本次观察数量", text: $text).keyboardType(.numberPad).accessibilityIdentifier("obs.count")
                    Button("保存本次观察数量") { if let n = Int(text), model.edit({ try $0.setGroupCount(o.id, n) }) { dismiss() } }.disabled(Int(text).map { !(1...999998).contains($0) } ?? true).accessibilityIdentifier("obs.save")
                    if o.override != nil { Button("恢复为单张最大值") { if model.edit({ try $0.setGroupCount(o.id, nil) }) { dismiss() } }.accessibilityIdentifier("obs.reset") }
                } header: { Text("本次观察数量") } footer: {
                    Text("默认取同日同地点单张照片的最大值，可能重复见到同一只鸟。可以改成你的估计（可以小于单张最大值）。改日期、地点或鸟种后，这个数不会跟到新的分组。")
                }
                Section("照片") {
                    ForEach(photos) { item in
                        let sub = item.subjects.first { $0.key == o.species }?.ordinal ?? 0
                        Button { dismiss(); model.open(item.id, subject: sub) } label: {
                            HStack { CropThumbnail(url: model.url(item.id), id: item.id, boxes: item.boxes, crops: item.crops, index: sub).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6)).opensImageViewer(.photo(id: item.id, boxes: item.boxes, crops: item.crops, index: sub), before: { dismiss() }); Text(item.wall.replacingOccurrences(of: "T", with: " ")).font(.caption).monospacedDigit() }
                        }
                    }
                }
            }.navigationTitle("观察记录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onAppear { text = String(o.estimate) }
        }
    }
}

/// Lazy MapKit view of actual points, clustered per viewport by distinct observations; region-only and no-place below.
struct SightingMap: View {
    @Environment(AppModel.self) var model
    let range: (String, String)?
    @State private var region: MKCoordinateRegion?
    @State private var picked: [Sighting]?
    struct Pin: Identifiable { let id: String; let lat: Double; let lon: Double; let sightings: [Sighting] }
    var points: [(Double, Double, Sighting)] {
        model.ledger.observations.filter { Ledger.inRange($0.day, range) }.flatMap { o in model.ledger.evidence(o).compactMap { i in i.lat.map { ($0, i.lon!, o) } } }
    }
    func clusters(_ pts: [(Double, Double, Sighting)]) -> [Pin] {
        let cell = max(0.005, (region?.span.latitudeDelta ?? 40) / 8)
        let groups = Dictionary(grouping: pts) { "\(Int(floor($0.0 / cell))):\(Int(floor($0.1 / cell)))" }
        return groups.map { k, v in
            var seen = Set<String>(), list = [Sighting]()
            for p in v where seen.insert(p.2.id).inserted { list.append(p.2) }
            return Pin(id: k, lat: v.map(\.0).reduce(0, +) / Double(v.count), lon: v.map(\.1).reduce(0, +) / Double(v.count), sightings: list)
        }
    }
    var body: some View {
        let pts = points, obs = model.ledger.observations.filter { Ledger.inRange($0.day, range) }
        let regionOnly = Dictionary(grouping: obs.filter { $0.place.hasPrefix("r:") }, by: \.place).mapValues(\.count).sorted { $0.key < $1.key }
        let none = obs.filter { $0.place == "none" }.count
        List {
            Section {
                if pts.isEmpty { Text("这段时间没有带坐标的记录。").accessibilityIdentifier("map.noPoints") }
                else {
                    // At least ~50 km across, so a single point shows land around it rather than one tile of water.
                    let lats = pts.map(\.0), lons = pts.map(\.1)
                    let span = MKCoordinateSpan(latitudeDelta: max(0.5, (lats.max()! - lats.min()!) * 1.4), longitudeDelta: max(0.5, (lons.max()! - lons.min()!) * 1.4))
                    Map(initialPosition: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2, longitude: (lons.max()! + lons.min()!) / 2), span: span))) {
                        ForEach(clusters(pts)) { pin in
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)) {
                                Button { picked = pin.sightings } label: {
                                    Text("\(pin.sightings.count)").font(.caption.bold()).monospacedDigit().foregroundStyle(Palette.onAccent).frame(minWidth: 30, minHeight: 30).background(Palette.accent, in: Circle()).overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                                }.accessibilityLabel("\(pin.sightings.count) 条观察记录的照片位置")
                            }
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { region = $0.region }
                    .frame(height: 320).listRowInsets(EdgeInsets()).accessibilityIdentifier("map.canvas")
                    Text("圆点数字 = 该处照片位置涉及的不同观察记录数。底图来自 Apple 地图，需要网络；没有网络时下面的列表照常可用。").font(.caption).foregroundStyle(Palette.secondary)
                }
            }
            Section("有坐标的记录 · \(Set(pts.map(\.2.id)).count)") {
                ForEach(Array(Set(pts.map(\.2.id))).sorted().prefix(100), id: \.self) { id in
                    if let o = obs.first(where: { $0.id == id }), let i = model.ledger.evidence(o).first(where: { $0.lat != nil }) {
                        VStack(alignment: .leading, spacing: 8) {
                            SpeciesName(key: o.species, size: .row)
                            Text("\(o.day) · \(String(format: "%.3f, %.3f", i.lat!, i.lon!))").font(.caption).foregroundStyle(Palette.tertiary).monospacedDigit()
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
            Section("只选了地区的记录") {
                if regionOnly.isEmpty { Text("没有").font(.caption) }
                ForEach(regionOnly, id: \.key) { k, v in LabeledContent(String(k.dropFirst(2)), value: String(localized: "\(v) 条")) }
            }
            Section("地点未知") { LabeledContent("同日合并的记录", value: String(localized: "\(none) 条")).accessibilityIdentifier("map.noPlace") }
        }
        .scrollContentBackground(.hidden).background(Palette.canvas)
        .navigationTitle("地图").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })) {
            NavigationStack {
                List(picked ?? []) { o in
                    VStack(alignment: .leading, spacing: 8) {
                        SpeciesName(key: o.species, size: .row)
                        Text("\(o.day) · 估计 \(o.estimate)").font(.caption).foregroundStyle(Palette.tertiary).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
                    .navigationTitle("照片位置").toolbar { Button("完成") { picked = nil } }
            }.presentationDetents([.medium]).debugAppearance()
        }
    }
}
