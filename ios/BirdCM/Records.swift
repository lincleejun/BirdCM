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
        .background(Palette.paper)
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
        let sp = model.catalogue.species(stat.id)
        let thumb = Group {
            if let c = stat.cover { CropThumbnail(url: model.url(c.item.id), id: c.item.id, boxes: c.item.boxes, crops: c.item.crops, index: c.ordinal) } else { Rectangle().fill(Palette.paper) }
        }.clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
        let text = VStack(alignment: .leading, spacing: 4) {
            Text(model.catalogue.name(stat.id)).font(.headline).lineLimit(wide ? nil : 2)
            if let sp, !sp.en.isEmpty, !sp.zh.isEmpty { Text(sp.en).font(.caption).foregroundStyle(Palette.secondary).lineLimit(wide ? nil : 1) }
            Text("\(stat.observations) 次观察 · \(stat.photos.count) 张").font(.caption).monospacedDigit()
            Text("首次 \(stat.first)").font(.caption).foregroundStyle(Palette.secondary).monospacedDigit()
        }
        Group {
            if wide { VStack(alignment: .leading, spacing: 8) { thumb.frame(height: 160); text } }
            else { VStack(alignment: .leading, spacing: 8) { thumb.frame(height: 120); text }.frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .combine)
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
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(sp?.zh.isEmpty == false ? sp!.zh : (sp?.en ?? key)).font(.largeTitle.bold()).accessibilityIdentifier("species.name")
                    if sp?.zh.isEmpty == true { Text("暂无中文名").font(.caption).foregroundStyle(Palette.secondary) }
                    if let en = sp?.en, !en.isEmpty { Text(en).font(.title3) }
                    Text(key).italic().foregroundStyle(Palette.secondary)
                }
                Text(stat == nil ? "未见" : "已见").font(.headline).padding(.horizontal, 10).padding(.vertical, 4).foregroundStyle(stat == nil ? Palette.ink : Color.white).background(stat == nil ? Palette.paper : Palette.button, in: Capsule()).accessibilityIdentifier("species.seen")
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
                SpeciesReferenceSection(sci: key, own: stat != nil)
                Divider()
                if let code = EBird.names[key]?.code, !code.isEmpty { Link("在 eBird 查看", destination: URL(string: "https://ebird.org/species/" + code)!).frame(minHeight: 44).accessibilityIdentifier("species.ebird") }
                Link("在维基百科搜索学名", destination: URL(string: "https://en.wikipedia.org/w/index.php?search=" + (key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))!).frame(minHeight: 44)
                Button("复制学名") { UIPasteboard.general.string = key }.frame(minHeight: 44)
                Text("链接会在浏览器中打开，需要网络。").font(.caption).foregroundStyle(Palette.secondary)
            }.padding(20)
        }
        .background(Palette.paper)
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
                        RoundedRectangle(cornerRadius: 3).fill(counts[i] == 0 ? Palette.surface : Palette.green.opacity(0.35 + 0.65 * Double(counts[i]) / Double(max(1, counts.max()!)))).frame(height: 18)
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
            ForEach(rows, id: \.0) { r in LabeledContent(r.0, value: "\(r.1) 次").font(.subheadline) }
        }
    }
}

