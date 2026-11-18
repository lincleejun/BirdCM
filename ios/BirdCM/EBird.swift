import SwiftUI

/// eBird Record Format from the life list (§8.1), a port of engine/birdcm/ebird.py `lifelist_csv`; byte-identical on
/// docs/fixtures/lifelist/ebird-v1.csv. 19 fields, no header, no quoting, LF, ≤1,000,000 bytes, Incidental / N.
enum EBird {
    /// AviList scientific → (Clements English name, Cornell species code); bundled `ebird-names.csv` (CC BY 4.0, NOTICE).
    static let names: [String: (en: String, code: String)] = {
        guard let url = Bundle.main.url(forResource: "ebird-names", withExtension: "csv"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out = [String: (String, String)]()
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {    // CRLF is one Character in Swift
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if f.count >= 3 { out[f[0]] = (f[1], f[2]) }
        }
        return out
    }()
    static let limits = [128, 64, 64, 6, 4000, 254, 12, 12, 10, 5, 3, 2, 16, 4, 4, 1, 8, 8, 4000]
    static let note = "From BirdCM photo review; not a complete count"
    static func clean(_ v: String, _ limit: Int) -> String {
        let s = v.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ",", with: " ")
        let joined = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(String.UnicodeScalarView(joined.unicodeScalars.prefix(limit)))
    }
    struct Checklist: Identifiable {
        let day: String, placeKey: String, date: String, start: String, name: String
        let lat: Double?, lon: Double?, state: String, country: String, fallback: Bool
        let sightings: [Sighting]
        var id: String { day + "|" + placeKey }
    }
    /// One checklist per (local day, place bucket). Coordinates / names from the first evidence by (capture wall or "", hash, subject id).
    static func checklists(_ ledger: Ledger, _ range: (String, String)?, rarity: Rarity?) -> [Checklist] {
        let groups = Dictionary(grouping: ledger.observations.filter { Ledger.inRange($0.day, range) }) { $0.day + "|" + $0.place }
        return groups.keys.sorted { a, b in let x = a.split(separator: "|", maxSplits: 1), y = b.split(separator: "|", maxSplits: 1); return (x[0], x[1]) < (y[0], y[1]) }.map { key in
            let list = groups[key]!, day = list[0].day, pk = list[0].place
            var rows = [(item: PhotoItem, sub: SubjectItem)]()
            for o in list { for item in ledger.evidence(o) { for sub in item.subjects where Ledger.eligible(sub, ledger.known) && sub.key == o.species { rows.append((item, sub)) } } }
            rows.sort { ($0.item.capture ?? "", $0.item.hash, $0.sub.id) < ($1.item.capture ?? "", $1.item.hash, $1.sub.id) }
            let first = rows[0].item
            var lat: Double?, lon: Double?, name = "", state = "", country = ""
            if let a = first.lat, let o = first.lon {
                lat = min(89.99999, max(-89.99999, a)); lon = o
                (name, state, country) = pointCodes(lat!, lon!, rarity)
                name = "\(name) \(String(format: "%.4f", lat!)) \(String(format: "%.4f", lon!))".trimmingCharacters(in: .whitespaces)
            } else if let code = first.region {
                let en = rarity?.rows("SELECT name_en FROM regions WHERE code=?", [code]).first?.first ?? code
                name = en + (code.contains("-") ? " " + code.prefix(2) : ""); state = code.contains("-") ? String(code.split(separator: "-", maxSplits: 1)[1]) : ""; country = String(code.prefix(2))
            }
            let timed = rows.filter { ["photo", "user"].contains($0.item.dateSource) && ($0.item.capture?.count ?? 0) >= 16 }.map { $0.item.capture! }
            let p = day.split(separator: "-")
            return Checklist(day: day, placeKey: pk, date: "\(p[1])/\(p[2])/\(p[0])", start: timed.min().map { String($0.dropFirst(11).prefix(5)) } ?? "", name: name.isEmpty ? "BirdCM location" : name,
                             lat: lat, lon: lon, state: state, country: country, fallback: rows.contains { $0.item.dateSource.hasPrefix("identified") }, sightings: list.sorted { $0.species < $1.species })
        }
    }
    /// A point → (English location name, state code, country code) through the one point → region mapping (Rarity.regionAt).
    static func pointCodes(_ lat: Double, _ lon: Double, _ rarity: Rarity?) -> (String, String, String) {
        guard let rarity else { return ("", "", "") }
        let r = rarity.regionAt(lat: lat, lon: lon)
        guard let country = r.country else { return ("", "", "") }
        if let div = r.division {
            let en = rarity.rows("SELECT name_en FROM regions WHERE code=?", [div]).first?.first ?? div
            return ("\(en) \(country)", String(div.split(separator: "-", maxSplits: 1).last ?? ""), country)
        }
        return (Place.countries.first { $0["code"] == country }?["en"] ?? rarity.rows("SELECT name_en FROM regions WHERE code=?", [country]).first?.first ?? country, "", country)
    }
    enum Fallback { case include, exclude }
    static func csv(_ checklists: [Checklist], fallback: Fallback, estimates: Bool) throws -> String {
        var lines = [String]()
        for cl in checklists where !(cl.fallback && fallback == .exclude) {
            for o in cl.sightings {
                let parts = o.species.split(separator: " ", maxSplits: 1).map(String.init)
                let n = estimates ? String(o.estimate) : "X"
                let comment = note + (cl.fallback ? "; capture date missing (identification date used)" : "")
                let row = [names[o.species]?.en ?? "", parts[0], parts.count > 1 ? parts[1] : "", n, "", cl.name,
                           cl.lat.map { String(format: "%.5f", $0) } ?? "", cl.lon.map { String(format: "%.5f", $0) } ?? "",
                           cl.date, cl.start, cl.state, cl.country, "Incidental", "", "", "N", "", "", comment]
                lines.append(zip(row, limits).map { clean($0, $1) }.joined(separator: ","))
            }
        }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        guard text.utf8.count <= 1_000_000 else { throw StoreError(message: "文件超过 eBird 的 1 MB 上限：请缩短时间范围后分几次导出") }
        return text
    }
}

/// Preview grouped by checklist, explicit choice for fallback-date rows, then a file through Files (manual upload to eBird).
struct EBirdSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let title: String
    let range: (String, String)?
    @State private var fallback: EBird.Fallback?
    @State private var estimates = false
    @State private var file: BackupView.Exported?
    @State private var message = ""
    var body: some View {
        let lists = EBird.checklists(model.ledger, range, rarity: model.catalogue.rarity)
        let fallbackCount = lists.filter(\.fallback).count
        let unmapped = Set(lists.flatMap { $0.sightings.map(\.species) }.filter { EBird.names[$0] == nil })
        NavigationStack {
            List {
                Section {
                    Text("导出为 eBird 的 Record Format 文件，需要你自己在 eBird 网站上传核对；不会自动提交。默认“偶遇（Incidental）”、非完整清单、数量 X，不编造观鸟时长和距离。").font(.footnote)
                    Toggle("用估计数量代替 X", isOn: $estimates).accessibilityIdentifier("ebird.estimates")
                    if fallbackCount > 0 {
                        Picker("缺拍摄日期的 \(fallbackCount) 份清单", selection: $fallback) {
                            Text("请选择").tag(EBird.Fallback?.none); Text("包含（按首次识别日期）").tag(EBird.Fallback?.some(.include)); Text("排除").tag(EBird.Fallback?.some(.exclude))
                        }.accessibilityIdentifier("ebird.fallback")
                    }
                    if !unmapped.isEmpty { Text("\(unmapped.count) 种在 eBird 名录里没有对应英文名，只写学名；上传时可能需要在 Fix Species 里手动对应。").font(.footnote).foregroundStyle(Palette.rust) }
                    let pending = model.ledger.summary(range).pending
                    if pending > 0 { Text("另有 \(pending) 个待确认主体（属级、不确定、未识别）不导出。").font(.footnote) }
                    Button("导出 eBird 文件") { export(lists) }.buttonStyle(PrimaryActionStyle()).disabled(lists.isEmpty || (fallbackCount > 0 && fallback == nil)).accessibilityIdentifier("ebird.export")
                    if !message.isEmpty { Text(message).accessibilityIdentifier("ebird.message") }
                }
                ForEach(lists) { cl in
                    Section("\(cl.day) · \(cl.name)\(cl.fallback ? " · 按识别日期" : "")") {
                        ForEach(cl.sightings) { o in LabeledContent(model.catalogue.name(o.species), value: estimates ? "\(o.estimate)" : "X") }
                    }
                }
                if lists.isEmpty { Text("这段时间没有可导出的观察记录。") }
            }
            .navigationTitle("eBird · \(title)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.accessibilityIdentifier("ebird.close") } }
            .sheet(item: $file) { f in DocumentExporter(url: f.url) { ok in message = ok ? String(localized: "文件已写入，可在 eBird 网站的“上传数据”里选择它。") : String(localized: "已取消。"); file = nil } }
        }
    }
    func export(_ lists: [EBird.Checklist]) {
        do {
            let text = try EBird.csv(lists, fallback: fallback ?? .include, estimates: estimates)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BirdCM-eBird-\(title.replacingOccurrences(of: " ", with: "")).csv")
            try Data(text.utf8).write(to: url)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "uiTesting") { message = String(localized: "测试：已生成 \(text.split(separator: "\n").count) 行"); return }
            #endif
            file = BackupView.Exported(url: url)
        } catch { message = error.localizedDescription }
    }
}
