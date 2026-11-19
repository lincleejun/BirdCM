import SwiftUI

/// §6.1: search all 11,172 species offline; explicit Save is the commit; cancel changes nothing.
struct CorrectionSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let record: Record
    let index: Int
    @State private var query = ""
    @State private var results = [Catalogue.Species]()
    @State private var limit = 50
    @State private var picked: Catalogue.Species?
    var effective: AppModel.Effective { model.effective(record, index) }
    func row(_ sp: Catalogue.Species) -> some View {
        Button { picked = sp } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sp.zh.isEmpty ? "\(sp.en) · 暂无中文名" : sp.zh).font(.body)
                    if !sp.zh.isEmpty { Text(sp.en).font(.caption) }
                    Text(sp.sci).font(.caption).italic().foregroundStyle(Palette.secondary)
                }
                Spacer()
                if model.ledger.allTime[sp.sci] != nil { Text("已见").font(.caption.bold()).foregroundStyle(Palette.accent) }
                if picked == sp { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("correction.row.\(sp.sci)")
    }
    var body: some View {
        NavigationStack {
            List {
                Section("当前") {
                    LabeledContent("模型判断", value: effective.model.map { m in title(m) + (m.level == "species" ? " · " + (m.top5.first?.p ?? 0).formatted(.percent.precision(.fractionLength(1))) : "") } ?? "未识别")
                    if effective.state != "none" { LabeledContent("你的更正", value: effective.name).accessibilityIdentifier("correction.current") }
                }
                if let picked {
                    Section("确认更正") {
                        Text("\(effective.name) → \(picked.name)").font(.headline).accessibilityIdentifier("correction.review")
                        Text(picked.sci).italic().foregroundStyle(Palette.secondary)
                        Button("保存更正") { save("species", picked.sci) }.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("correction.save")
                    }
                }
                Section {
                    Button("标为不确定", systemImage: "questionmark.circle") { save("uncertain", nil) }.accessibilityIdentifier("correction.uncertain").frame(minHeight: 44)
                    if effective.state != "none" { Button("恢复自动识别", systemImage: "arrow.uturn.backward") { save("none", nil) }.accessibilityIdentifier("correction.reset").frame(minHeight: 44) }
                } footer: { Text("更正只代表你的判断，不改变模型把握；恢复自动识别不会重新运行模型。") }
                if query.isEmpty, let top = effective.model?.top5, !top.isEmpty {
                    Section("模型前五") { ForEach(top.compactMap { model.catalogue.species($0.scientific) }) { row($0) } }
                }
                Section(query.isEmpty ? "全部 \(model.catalogue.all.count) 种（按学名）" : "搜索结果 · \(results.count)") {
                    ForEach(results.prefix(limit)) { row($0) }
                    if results.count > limit { Button("再显示 50 种") { limit += 50 }.frame(minHeight: 44) }
                    if !query.isEmpty && results.isEmpty { Text("没有匹配的鸟种。试试英文名或学名。") }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("中文、英文或学名"))
            .task { await model.catalogue.preparePinyin() }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                results = model.catalogue.search(query); limit = 50
            }
            .navigationTitle("更正鸟种").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("correction.cancel") } }
        }
    }
    func save(_ state: String, _ key: String?) {
        guard let subject = effective.subject else { return }
        if model.edit({ try $0.correct(subject, state: state, key: key) }) { dismiss() }
    }
}

struct CountSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let record: Record
    let index: Int
    @State private var text = ""
    var body: some View {
        let e = model.effective(record, index)
        NavigationStack {
            Form {
                Section {
                    TextField("估计数量", text: $text).keyboardType(.numberPad).accessibilityIdentifier("count.field")
                } footer: { Text("这个框里大约有几只（1–999998），适合一个框框住一群鸟。估计数量：同日同地点取单张照片的最大值；可能重复见到同一只鸟。") }
                Section {
                    Button("保存") { if let n = Int(text), model.edit({ try $0.setCount(e.subject!, n) }) { dismiss() } }.disabled(Int(text).map { !(1...999998).contains($0) } ?? true).accessibilityIdentifier("count.save")
                    if e.count != nil { Button("恢复自动（1 只）") { if model.edit({ try $0.setCount(e.subject!, nil) }) { dismiss() } }.accessibilityIdentifier("count.reset") }
                }
            }.navigationTitle("数量").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onAppear { text = String(e.count ?? 1) }
        }.presentationDetents([.medium, .large])
    }
}

/// Camera wall clock edit (no timezone conversion: the picker runs in UTC so the shown clock is the stored clock).
struct DateSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let item: PhotoItem
    @State private var date = Date()
    static let utc = TimeZone(identifier: "UTC")!
    static func formatter() -> DateFormatter { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("拍摄时间", selection: $date).environment(\.timeZone, Self.utc).accessibilityIdentifier("date.picker")
                Text("改的是整张照片的日期，照片里的每只鸟都按新日期统计。时区沿用照片记录（没有就留空）。").font(.footnote)
                Button("保存") {
                    let wall = Self.formatter().string(from: date)
                    if model.edit({ try $0.setDate(item.id, wall: wall, offset: item.dateSource == "photo" || item.dateSource == "user" ? item.offset : nil) }) { dismiss() }
                }.accessibilityIdentifier("date.save")
                if item.dateSource == "user" { Button("恢复照片原始日期") { if model.edit({ try $0.setDate(item.id, wall: nil, offset: nil) }) { dismiss() } }.accessibilityIdentifier("date.reset") }
            }.navigationTitle("修改日期").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onAppear { date = Self.formatter().date(from: item.wall.count == 10 ? item.wall + "T12:00:00" : item.wall) ?? Date() }
        }.presentationDetents([.medium, .large])
    }
}
