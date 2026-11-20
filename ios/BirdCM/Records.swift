import Charts
import MapKit
import SwiftUI

/// 记录: species grid / all photos / pending subjects (§6).
struct RecordsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var search = ""
    /// 照片 order: 最近查看 (default, the order of model.items), capture date, or species name.
    @State private var photoSort = "viewed"
    /// 鸟种 order: 最近识别 (default; owner 2026-11-18: a bird just identified comes first), 最近见到, 首次见到, 名称.
    @State private var sort = "identified"
    @State private var deleting: PhotoItem?
    var species: [SpeciesStat] {
        let all = Array(model.ledger.allTime.values)
        switch sort {
        case "first": return all.sorted { $0.first != $1.first ? $0.first > $1.first : $0.id < $1.id }
        case "name": return all.sorted { model.catalogue.name($0.id).localizedStandardCompare(model.catalogue.name($1.id)) == .orderedAscending }
        case "recent": return all.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
        default: return Self.recentlyIdentified(all, items: model.items)
        }
    }
    /// Each species by its newest photo's last identification, correction or opening (the 照片 order's key), newest first.
    static func recentlyIdentified(_ all: [SpeciesStat], items: [PhotoItem]) -> [SpeciesStat] {
        let byPhoto = Dictionary(items.map { ($0.hash, $0.viewed ?? $0.identified) }, uniquingKeysWith: max)
        let key = Dictionary(uniqueKeysWithValues: all.map { s in (s.id, s.photos.compactMap { byPhoto[$0] }.max() ?? "") })
        return all.sorted { key[$0.id]! != key[$1.id]! ? key[$0.id]! > key[$1.id]! : $0.id < $1.id }
    }
    var photos: [PhotoItem] {
        let found = model.items.filter { model.matches($0, search) }
        switch photoSort {
        case "name": return found.sorted { (model.label($0), $1.day) < (model.label($1), $0.day) }
        case "date": return found.sorted { ($0.day, $0.wall) > ($1.day, $1.wall) }
        default: return found
        }
    }
    var body: some View {
        Group {
            switch model.recordsMode {
            case "photos": photoList
            case "pending": pendingList
            default: speciesGrid
            }
        }
        .background(Palette.canvas)
        .navigationTitle("记录")
        .confirmationDialog("删除这张照片的记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let d = deleting { model.delete(d.id) } }.accessibilityIdentifier("history.confirmDelete")
            Button("取消", role: .cancel) {}
        } message: { Text("只从观羽的记录与统计中移除；相册或文件里的原图不受影响。") }
    }
    /// Part of each list's scrolling content (owner 2026-11-18: a scrolled root keeps only its title).
    var modePicker: some View {
        @Bindable var model = model
        return Picker("记录", selection: $model.recordsMode) {
            Text("鸟种").tag("species"); Text("照片").tag("photos"); Text("待确认").tag("pending")
        }.pickerStyle(.segmented).accessibilityIdentifier("records.mode")
    }
    @ViewBuilder var speciesGrid: some View {
        if model.ledger.allTime.isEmpty {
            VStack(spacing: 0) { modePicker.padding(.horizontal).padding(.vertical, 8); speciesEmpty }
        } else {
            ScrollView {
                modePicker.padding(.horizontal).padding(.vertical, 8)
                let count = Text("\(model.ledger.allTime.count) 种").font(.headline)
                let picker = Picker("排序", selection: $sort) { Text("最近识别").tag("identified"); Text("最近见到").tag("recent"); Text("首次见到").tag("first"); Text("名称").tag("name") }.accessibilityIdentifier("records.sort")
                ViewThatFits(in: .horizontal) { HStack { count; Spacer(); picker }; VStack(alignment: .leading) { count; picker } }.padding(.horizontal)
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(species) { s in
                        NavigationLink(value: AppModel.Route.species(s.id)) { SpeciesCard(stat: s, wide: typeSize.isAccessibilitySize) }.buttonStyle(.plain).accessibilityIdentifier("records.species.\(s.id)")
                    }
                }.padding(.horizontal).padding(.bottom, 24)
            }
        }
    }
    var speciesEmpty: some View {
        ContentUnavailableView {
            Label("还没有鸟种", systemImage: "bird")
        } description: { Text(model.items.isEmpty ? "还没有记录，从识别一张照片开始。" : "已有照片，但还没有确定到种的鸟。可以去“待确认”更正。") } actions: {
            Button("开始识别") { model.tab = .identify }.buttonStyle(.bordered)
        }.accessibilityIdentifier("records.empty")
    }
    var photoList: some View {
        List {
            modePicker.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            Section {
                TextField("搜索鸟名、地点或日期", text: $search, prompt: Text("搜索鸟名、地点或日期").foregroundColor(Palette.secondary)).accessibilityIdentifier("history.search").frame(minHeight: 44)
                let names = ["viewed": String(localized: "最近查看"), "date": String(localized: "拍摄日期"), "name": String(localized: "鸟种名称")]
                Menu {
                    Picker("排序", selection: $photoSort) { Text("最近查看").tag("viewed"); Text("拍摄日期").tag("date"); Text("鸟种名称").tag("name") }
                } label: { Label("排序：\(names[photoSort] ?? "")", systemImage: "arrow.up.arrow.down").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                    .accessibilityIdentifier("history.sort").accessibilityHint("选择排序方式")
            } footer: { Text(photoSort == "name" ? "按鸟种名称排序。" : photoSort == "date" ? "按统计日期排序，最新在前。" : "最近打开或识别的在前；没打开过的按识别时间。") }
            if model.items.isEmpty { ContentUnavailableView("还没有记录，从识别一张照片开始", systemImage: "bird").listRowBackground(Palette.surface) }
            else if photos.isEmpty {
                ContentUnavailableView { Label("没有匹配的记录", systemImage: "magnifyingglass") } description: { Text("试试中文名、英文名、学名、地点或日期。") } actions: { Button("清除搜索") { search = "" } }
            }
            ForEach(photos) { r in
                Button { model.open(r.id) } label: { HistoryRow(item: r) }.buttonStyle(.plain).accessibilityIdentifier("history.item.\(r.id)").listRowBackground(Palette.surface)
                    .swipeActions { Button("删除", role: .destructive) { deleting = r }.accessibilityIdentifier("history.delete.\(r.id)") }
            }
        }.scrollContentBackground(.hidden).contentMargins(.top, 4, for: .scrollContent)   // the picker follows the title, like 统计
    }
    var pendingList: some View {
        let pending = model.ledger.pending
        let unprocessed = pending.filter { $0.subject.level == "unclassified" && $0.subject.state == "none" }.count
        return List {
            modePicker.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
            if pending.isEmpty {
                ContentUnavailableView("所有已识别主体都已确定到种", systemImage: "checkmark.circle").accessibilityIdentifier("pending.empty")
            } else {
                Section { Text("\(pending.count) 个主体待确认，来自 \(Set(pending.map(\.item.id)).count) 张照片；其中 \(unprocessed) 个还没识别。它们不计入鸟种和观察记录。").font(.footnote) }
                ForEach(pending) { p in
                    Button { model.open(p.item.id, subject: p.subject.ordinal) } label: {
                        HStack(spacing: 12) {
                            CropThumbnail(url: model.url(p.item.id), id: p.item.id, boxes: p.item.boxes, crops: p.item.crops, index: p.subject.ordinal).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                                .opensImageViewer(.photo(id: p.item.id, boxes: p.item.boxes, crops: p.item.crops, index: p.subject.ordinal))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("鸟 \(p.subject.ordinal + 1) · \(p.reason)").font(.subheadline)
                                Text("\(p.item.day) · \(model.placeName(p.item) ?? String(localized: "没有地点"))").font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.frame(minHeight: 56).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("pending.item.\(p.subject.id)").listRowBackground(Palette.surface)
                }
            }
            let noBird = model.items.filter { $0.subjects.isEmpty }.count
            if noBird > 0 { Section { Text("另有 \(noBird) 张照片没找到鸟，保留在“照片”里，不算待确认。").font(.footnote) } }
        }.scrollContentBackground(.hidden).contentMargins(.top, 4, for: .scrollContent)
    }
}

struct SpeciesCard: View {
    @Environment(AppModel.self) var model
    let stat: SpeciesStat
    let wide: Bool
    var body: some View {
        // An open photo card (polish.md): photo, the card name block, then the counts 8 pt below; no box, no shadow.
        let thumb = Group {
            if let c = stat.cover { CropThumbnail(url: model.url(c.item.id), id: c.item.id, boxes: c.item.boxes, crops: c.item.crops, index: c.ordinal) } else { Rectangle().fill(Palette.inset) }
        }.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 8) {
            thumb.frame(height: wide ? 160 : 140)
            VStack(alignment: .leading, spacing: 8) {
                SpeciesName(key: stat.id, size: .card)
                Text("\(stat.observations) 次观察 · \(stat.photos.count) 张 · 首次 \(stat.first)").font(.footnote).foregroundStyle(Palette.tertiary).monospacedDigit()
            }.padding(.horizontal, 2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

/// Species page: read-time names/IUCN, own photos only, all-time or invoking scope.
struct SpeciesPage: View {
    @Environment(AppModel.self) var model
    let key: String
    var body: some View {
        let sp = model.catalogue.species(key), stat = model.ledger.allTime[key]
        let sightings = model.ledger.observations.filter { $0.species == key }
        let photos = model.ledger.photos(of: key)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = stat?.cover {
                    CropThumbnail(url: model.url(c.item.id), id: c.item.id, boxes: c.item.boxes, crops: c.item.crops, index: c.ordinal).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityLabel("最近一次的照片")
                        .opensImageViewer(.photo(id: c.item.id, boxes: c.item.boxes, crops: c.item.crops, index: c.ordinal))
                }
                SpeciesName(key: key, size: .hero).accessibilityIdentifier("species.name").accessibilityAddTraits(.isHeader)
                // A plain state in gray (polish.md): accent is for actions and selection only.
                Text(stat == nil ? "我的观察 · 未见" : "我的观察 · 已见").font(.subheadline).foregroundStyle(Palette.secondary).accessibilityIdentifier("species.seen")
                VStack(alignment: .leading, spacing: 8) {
                    if let sp { LabeledContent("科", value: sp.family); LabeledContent("属", value: sp.genus) }
                    if let code = model.iucn(key) { IUCNChip(code: code) }
                }.font(.subheadline)
                if let stat {
                    Divider()
                    Text("全部记录").font(.headline)
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow { Text("首次").foregroundStyle(Palette.secondary); Text(stat.first).monospacedDigit() }
                        GridRow { Text("最近").foregroundStyle(Palette.secondary); Text(stat.last).monospacedDigit() }
                        GridRow { Text("观察记录").foregroundStyle(Palette.secondary); Text("\(stat.observations)").monospacedDigit().accessibilityIdentifier("species.observations") }
                        GridRow { Text("估计数量").foregroundStyle(Palette.secondary); Text("\(stat.estimate)").monospacedDigit() }
                        GridRow { Text("照片").foregroundStyle(Palette.secondary); Text("\(stat.photos.count)").monospacedDigit() }
                    }.font(.subheadline)
                    Text("估计数量：同日同地点取单张最大值；可能重复见到同一只鸟。").font(.caption).foregroundStyle(Palette.secondary)
                    months(sightings)
                    places(sightings)
                    Text("照片 · \(photos.count)").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(photos) { item in
                            let ordinal = item.subjects.first { Ledger.eligible($0, model.catalogue.contains) && $0.key == key }?.ordinal ?? 0
                            Button { model.open(item.id, subject: ordinal) } label: {
                                CropThumbnail(url: model.url(item.id), id: item.id, boxes: item.boxes, crops: item.crops, index: ordinal).frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.accessibilityLabel("\(item.day) 的照片").accessibilityIdentifier("species.photo.\(item.id)")
                        }
                    }
                } else {
                    Text("仅有自己的照片，没有内置参考图。你还没有记录这种鸟。").foregroundStyle(Palette.secondary)
                }
                Divider()
                SpeciesLocal(key: key)
                Divider()
                SpeciesRangeMap(key: key)
                Divider()
                SpeciesReferenceSection(sci: key, own: stat != nil)
                Divider()
                if let code = EBird.names[key]?.code, !code.isEmpty { Link("在 eBird 查看", destination: URL(string: "https://ebird.org/species/" + code)!).frame(minHeight: 44).accessibilityIdentifier("species.ebird") }
                Link("在维基百科搜索学名", destination: URL(string: "https://en.wikipedia.org/w/index.php?search=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))!).frame(minHeight: 44)
                Button("复制学名") { UIPasteboard.general.string = key }.frame(minHeight: 44)
                Text("链接会在浏览器中打开，需要网络。").font(.caption).foregroundStyle(Palette.secondary)
            }.padding(20)
        }
        .background(Palette.canvas)
        .navigationTitle(model.catalogue.name(key)).navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder func months(_ sightings: [Sighting]) -> some View {
        let counts = (1...12).map { m in sightings.filter { Int($0.day.dropFirst(5).prefix(2)) == m }.count }
        VStack(alignment: .leading, spacing: 6) {
            Text("各月观察记录 · 全部年份按月份合计").font(.subheadline.bold())
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { i in
                    VStack(spacing: 2) {
                        Text("\(counts[i])").font(.caption2).monospacedDigit()
                        RoundedRectangle(cornerRadius: 3).fill(counts[i] == 0 ? Palette.surface : Palette.accent.opacity(0.35 + 0.65 * Double(counts[i]) / Double(max(1, counts.max()!)))).frame(height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.secondary.opacity(0.5)))
                        Text("\(i + 1)").font(.caption2)
                    }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore).accessibilityLabel("\(i + 1) 月 \(counts[i]) 次")
                }
            }
        }
    }
    @ViewBuilder func places(_ sightings: [Sighting]) -> some View {
        let groups = Dictionary(grouping: sightings, by: \.place)
        let rows = groups.map { place, list -> (String, Int) in
            let label = place == "none" ? String(localized: "地点未知（同日合并）") : model.items.first { $0.placeKey == place }.flatMap(model.placeName) ?? place
            return (label, list.count)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        // Photo points on one static map (region-only and unknown places stay in the list only).
        var seen = Set<String>()
        let points = model.ledger.photos(of: key).compactMap { i in i.lat.map { CLLocationCoordinate2D(latitude: $0, longitude: i.lon!) } }
            .filter { seen.insert(String(format: "%.3f,%.3f", $0.latitude, $0.longitude)).inserted }
        VStack(alignment: .leading, spacing: 6) {
            Text("地点").font(.subheadline.bold())
            if !points.isEmpty { PlaceSnapshot(points: points, label: String(localized: "\(points.count) 个拍摄位置"), height: 150) }
            ForEach(rows, id: \.0) { r in LabeledContent(r.0, value: String(localized: "\(r.1) 次")).font(.subheadline) }
        }
    }
}

/// 当地可能性: this month's word at the home place (the GBIF tier when the table covers it, else the model's word on
/// the same labels) and the model's 12 months there. Offline; the same place identification uses.
struct SpeciesLocal: View {
    @Environment(AppModel.self) var model
    let key: String
    enum Outcome: Equatable { case loading, unknown, months([Double], word: String, gbif: Bool) }
    @State private var outcome = Outcome.loading
    @State private var choosePlace = false
    let month = Calendar(identifier: .gregorian).component(.month, from: Date())
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当地可能性").font(.headline).accessibilityAddTraits(.isHeader)
            if let place = model.homePlace {
                let name = model.placeName(place) ?? place.label
                switch outcome {
                case .loading: ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                case .unknown: Text("地点模型没有这个物种，无法估计在 \(name) 的可能性。").font(.subheadline).foregroundStyle(Palette.secondary)
                case let .months(values, word, gbif):
                    Text("在 \(name) 本月：\(loc(word))").font(.subheadline.weight(.semibold)).accessibilityIdentifier("species.localWord")
                    Text(gbif ? "按 GBIF 观测记录的本地频次（与结果页同一套分级）。" : "这里本月没有观测数据，按地点模型估计。").font(.caption).foregroundStyle(Palette.secondary)
                    Chart(0..<12, id: \.self) { i in
                        BarMark(x: .value("月份", "\(i + 1)"), y: .value("可能性", values[i]))
                            .foregroundStyle(i + 1 == month ? Palette.accent : Palette.accent.opacity(0.3))
                            .accessibilityLabel("\(i + 1) 月").accessibilityValue(values[i].formatted(.percent.precision(.fractionLength(0))))
                    }
                    .chartYScale(domain: 0...max(0.05, (values.max() ?? 0) * 1.1))
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(d.formatted(.percent.precision(.fractionLength(0)))) } } } }
                    .frame(height: 140).accessibilityIdentifier("species.monthChart")
                    Text("柱高是地点模型（BirdNET）估计的各月出现可能（每月取 4 个模型周的平均\(place.source == "region" ? String(localized: "，地区内取中位数") : "")），不是观测数量；深色是本月。").font(.caption).foregroundStyle(Palette.secondary)
                }
            } else {
                Text("还没有地点：设置后显示这种鸟在那里各月的可能性。").font(.subheadline).foregroundStyle(Palette.secondary)
                Button("选择地点") { choosePlace = true }.frame(minHeight: 44).accessibilityIdentifier("species.choosePlace")
            }
        }
        .sheet(isPresented: $choosePlace) { PlacePicker(onChoose: { model.chooseHome($0) }).debugAppearance() }
        .task(id: "\(key)|\(model.homePlace?.stableCode ?? "")|\(model.homePlace?.source ?? "")") {
            guard var place = model.homePlace else { return }
            outcome = .loading
            let catalogue = model.catalogue, key = key, m = month
            // A region choice is looked up by its ISO code (old region places stored only a label), as in localRarity.
            if place.source == "region", place.regionCode == nil { place.regionCode = Library.regionCodes[place.label] }
            outcome = await Task.detached { () -> Outcome in
                let year = Likelihood.compute(place: place, month: m, catalogue: catalogue).months
                guard let j = catalogue.all.firstIndex(where: { $0.sci == key }), year.indices.contains(j), let values = year[j] else { return .unknown }
                let gbif = catalogue.rarity?.lookup(key, place: place, month: m).label
                if let gbif, Likelihood.tierNames.contains(gbif) { return .months(values, word: gbif, gbif: true) }
                return .months(values, word: Geo.modelTier(values[m - 1]), gbif: false)
            }.value
        }
    }
}

/// 分布图: the model over a global grid on a plain background with country outlines from the bundled region table
/// (no map tiles, works offline). 全年 / 繁殖季 / 非繁殖季 come from one cached cells × months evaluation.
struct SpeciesRangeMap: View {
    @Environment(AppModel.self) var model
    let key: String
    @State private var season = Geo.Season.year
    @State private var values: [UInt8]?
    @State private var unknown = false
    @State private var progress = 0.0
    static let grid = Geo.rangeGrid()
    /// Country rings in map units (x = lon + 180, y = 84 − lat), built once.
    static let land: Path = {
        var path = Path()
        for ring in Catalogue.shared.rarity?.countryRings() ?? [] where ring.count >= 6 {
            path.move(to: CGPoint(x: Double(ring[0]) + 180, y: Geo.rangeLat.1 - Double(ring[1])))
            for i in stride(from: 2, to: ring.count, by: 2) { path.addLine(to: CGPoint(x: Double(ring[i]) + 180, y: Geo.rangeLat.1 - Double(ring[i + 1]))) }
            path.closeSubpath()
        }
        return path
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分布图").font(.headline).accessibilityAddTraits(.isHeader)
            if unknown {
                Text("地点模型没有这个物种，无法画分布。").font(.subheadline).foregroundStyle(Palette.secondary)
            } else {
                Picker("季节", selection: $season) { ForEach(Geo.Season.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("species.season")
                let span = Geo.rangeLat.1 - Geo.rangeLat.0
                ZStack {
                    if let values { map(Geo.seasonMap(values, grid: Self.grid, season: season)) }
                    else { RoundedRectangle(cornerRadius: 12).fill(Palette.surface); ProgressView(value: progress) { Text("正在计算分布…").font(.caption) }.padding(.horizontal, 40) }
                }.aspectRatio(360 / span, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(loc(season.rawValue))分布图，地点模型估计").accessibilityIdentifier("species.rangeMap")
                Text("地点模型（BirdNET）在 \(Int(Geo.rangeStep))° 网格上的估计，颜色越浓越可能出现，不是观测记录。全年取 12 个月中最高；繁殖季 = 北半球 5–7 月、南半球 11–1 月，非繁殖季 = 北半球 12–2 月、南半球 6–8 月（按格点所在半球，热带只是近似）。\(model.homePlace == nil ? "" : String(localized: "圆圈是你的地点。"))")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
        }
        .task(id: key) {
            values = nil; unknown = false; progress = 0
            let key = key, catalogue = model.catalogue
            let result = await Task.detached(priority: .userInitiated) { () -> [UInt8]?? in
                guard let geo = Geo.shared(catalogue), let j = catalogue.all.firstIndex(where: { $0.sci == key }) else { return .some(nil) }
                return try? geo.range(j, sci: key) { f in Task { @MainActor in progress = max(progress, f) } }
            }.value
            switch result { case .some(.some(let v)): values = v; default: unknown = true }
        }
    }
    func map(_ cells: [Double]) -> some View {
        let home = model.homePlace
        return Canvas { ctx, size in
            let span = Geo.rangeLat.1 - Geo.rangeLat.0, sx = size.width / 360, sy = size.height / span, step = Geo.rangeStep
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.surface))
            let land = Self.land.applying(CGAffineTransform(scaleX: sx, y: sy))
            ctx.fill(land, with: .color(Palette.inset))
            for (c, v) in cells.enumerated() where v >= 0.02 {
                let p = Self.grid[c]
                let rect = CGRect(x: (p[1] + 180 - step / 2) * sx, y: (Geo.rangeLat.1 - p[0] - step / 2) * sy, width: step * sx + 0.5, height: step * sy + 0.5)
                ctx.fill(Path(rect), with: .color(Palette.accent.opacity(0.2 + 0.8 * v)))
            }
            ctx.stroke(land, with: .color(Palette.secondary.opacity(0.5)), lineWidth: 0.5)
            if let home {
                let c = CGPoint(x: (home.lon + 180) * sx, y: (Geo.rangeLat.1 - home.lat) * sy)
                let dot = Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
                ctx.stroke(dot, with: .color(Palette.canvas), lineWidth: 4); ctx.stroke(dot, with: .color(Palette.ink), lineWidth: 2)
            }
        }
    }
}

