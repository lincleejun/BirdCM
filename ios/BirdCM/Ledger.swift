import Foundation

/// Read-only name catalogue (names.tsv + zh-names.json) and GBIF table, independent of Engine so browsing never loads BioCLIP.
final class Catalogue {
    struct Species: Hashable, Identifiable {
        let sci: String, en: String, zh: String, genus: String, family: String
        var id: String { sci }
        var name: String { zh.isEmpty ? (en.isEmpty ? sci : en) : zh }
    }
    static let shared = Catalogue()
    let all: [Species]
    private let index: [String: Int]
    private let folded: [[String]]
    let rarity: Rarity?
    init(dir: URL = Models.dir) {
        let zh = Dictionary((resource("zh-names", as: [[String: String]].self)).compactMap { r in r["scientific"].map { ($0, r["zh"] ?? "") } }, uniquingKeysWith: { a, _ in a })
        let text = (try? String(contentsOf: dir.appendingPathComponent("names.tsv"), encoding: .utf8)) ?? ""
        all = text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count >= 5 }
            .map { Species(sci: $0[0], en: $0[1], zh: zh[$0[0]] ?? "", genus: $0[3], family: $0[4]) }
        index = Dictionary(all.enumerated().map { ($1.sci, $0) }, uniquingKeysWith: { a, _ in a })
        folded = all.map { [$0.zh, $0.en, $0.sci].map(Self.fold) }
        rarity = try? Rarity(path: Models.rarityURL)
    }
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
    func contains(_ key: String?) -> Bool { key.map { index[$0] != nil } ?? false }
    func species(_ key: String?) -> Species? { key.flatMap { index[$0] }.map { all[$0] } }
    func name(_ key: String?) -> String { species(key)?.name ?? key ?? "未知" }
    /// Exact > prefix > substring over Chinese / English / scientific; ties by scientific name. Empty query: alphabetical.
    /// Pinyin (full, no spaces) and initials per Chinese name, built once off the main actor with Foundation's
    /// Mandarin transliteration. A convenience only: never an identity, never guaranteed pronunciation.
    private(set) var pinyin: [(String, String)]?
    func preparePinyin() async {
        guard pinyin == nil else { return }
        let names = all.map(\.zh)
        let built = await Task.detached { names.map { Catalogue.pinyinOf($0) } }.value
        await MainActor.run { pinyin = built }
    }
    static func pinyinOf(_ zh: String) -> (String, String) {
        guard !zh.isEmpty, let latin = zh.applyingTransform(.mandarinToLatin, reverse: false) else { return ("", "") }
        let tokens = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split { !$0.isLetter }.map(String.init)
        return (tokens.joined(), String(tokens.compactMap(\.first)))
    }
    func search(_ query: String) -> [Species] {
        let q = Self.fold(query)
        guard !q.isEmpty else { return all.sorted { $0.sci < $1.sci } }
        let latin = pinyin != nil && q.allSatisfy { $0.isASCII && $0.isLetter }
        var hits = [(Int, Int)]()
        for (i, names) in folded.enumerated() {
            var best = 3
            for n in names where !n.isEmpty { best = min(best, n == q ? 0 : n.hasPrefix(q) ? 1 : n.contains(q) ? 2 : 3) }
            if latin, best > 1, let p = pinyin?[i], !p.0.isEmpty {
                best = min(best, p.0 == q || p.1 == q ? 1 : p.0.hasPrefix(q) || p.1.hasPrefix(q) ? 2 : best)
            }
            if best < 3 { hits.append((best, i)) }
        }
        return hits.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : all[$0.1].sci < all[$1.1].sci }.map { all[$0.1] }
    }
    static var resourceVersions: String {
        let shas = Dictionary(Models.assets.filter { ["names.tsv", "rarity-global.sqlite"].contains($0.path) }.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        return String(decoding: (try? JSONEncoder().encode(shas)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

struct Sighting: Identifiable {
    let id: String, species: String, day: String, place: String
    var frames: [String: Int] = [:]          // asset hash → that photo's sum of subject estimates
    var override: Int?
    var estimate: Int { override ?? frames.values.max() ?? 0 }
}
struct SpeciesStat: Identifiable {
    let id: String
    var first = "", last = "", observations = 0, estimate = 0
    var photos = Set<String>()
    var cover: (item: PhotoItem, ordinal: Int)?
}
struct Pending: Identifiable { let item: PhotoItem; let subject: SubjectItem; let reason: String; var id: String { subject.id } }
struct Summary { var species = 0, observations = 0, estimate = 0, newSpecies = 0, photos = 0, pending = 0, pendingPhotos = 0, noBird = 0, activeDays = 0; var list = [SpeciesStat]() }

/// §3: a counted observation = effective species × local day × place bucket; estimate = max photo sum, or the group override.
struct Ledger {
    let items: [PhotoItem]
    private let byHash: [String: PhotoItem]
    let observations: [Sighting]
    let allTime: [String: SpeciesStat]
    let known: (String) -> Bool
    init(items: [PhotoItem] = [], edits: [String: Int] = [:], known: @escaping (String) -> Bool = { _ in true }) {
        self.items = items; self.known = known
        byHash = Dictionary(items.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        var groups = [String: Sighting]()
        for item in items {
            for s in item.subjects where !s.excluded {
                guard let k = s.key, known(k) else { continue }
                let g = Library.groupKey(k, item.day, item.placeKey)
                groups[g, default: Sighting(id: g, species: k, day: item.day, place: item.placeKey, override: edits[g])].frames[item.hash, default: 0] += s.count ?? 1
            }
        }
        observations = groups.values.sorted { $0.day != $1.day ? $0.day > $1.day : $0.id < $1.id }
        allTime = Self.stats(items: items, observations: observations, known: known, range: nil)
    }
    /// Shared cover rule (engine library.cover_of): latest by capture wall time ("" when none), then hash, then subject id.
    static func later(_ item: PhotoItem, _ sub: SubjectItem, than c: (item: PhotoItem, ordinal: Int)) -> Bool {
        let old = c.item.subjects.first { $0.ordinal == c.ordinal }?.id ?? ""
        return (item.capture ?? "", item.hash, sub.id) > (c.item.capture ?? "", c.item.hash, old)
    }
    struct Day { var day: String; var species = Set<String>(); var observations = 0; var cover: (item: PhotoItem, ordinal: Int)? }
    /// Calendar cells: observations and species per local day, with the day's cover bird.
    func days(_ range: (String, String)?) -> [String: Day] {
        var out = [String: Day]()
        for o in observations where Self.inRange(o.day, range) { out[o.day, default: Day(day: o.day)].observations += 1; out[o.day]!.species.insert(o.species) }
        for item in items where out[item.day] != nil {
            for sub in item.subjects where Self.eligible(sub, known) {
                if let c = out[item.day]!.cover, !Self.later(item, sub, than: c) { continue }
                out[item.day]!.cover = (item, sub.ordinal)
            }
        }
        return out
    }
    /// The photos supporting one observation (one per distinct hash).
    func evidence(_ o: Sighting) -> [PhotoItem] { o.frames.keys.sorted().compactMap { byHash[$0] } }
    static func eligible(_ s: SubjectItem, _ known: (String) -> Bool) -> Bool { !s.excluded && s.key.map(known) == true }
    static func inRange(_ day: String, _ r: (String, String)?) -> Bool { r.map { day >= $0.0 && day <= $0.1 } ?? true }
    static func stats(items: [PhotoItem], observations: [Sighting], known: (String) -> Bool, range: (String, String)?) -> [String: SpeciesStat] {
        var out = [String: SpeciesStat]()
        for o in observations where inRange(o.day, range) {
            var s = out[o.species] ?? SpeciesStat(id: o.species, first: o.day, last: o.day)
            s.first = min(s.first, o.day); s.last = max(s.last, o.day); s.observations += 1; s.estimate += o.estimate
            out[o.species] = s
        }
        for item in items where inRange(item.day, range) {
            for sub in item.subjects where eligible(sub, known) {
                let k = sub.key!
                out[k]?.photos.insert(item.hash)
                if let c = out[k]?.cover, !Self.later(item, sub, than: c) { continue }
                out[k]?.cover = (item, sub.ordinal)
            }
        }
        return out
    }
    func summary(_ range: (String, String)?) -> Summary {
        var s = Summary()
        let obs = observations.filter { Self.inRange($0.day, range) }
        let scoped = Self.stats(items: items, observations: obs, known: known, range: range)
        s.species = scoped.count; s.observations = obs.count; s.estimate = obs.reduce(0) { $0 + $1.estimate }
        s.newSpecies = allTime.values.filter { Self.inRange($0.first, range) }.count
        s.activeDays = Set(obs.map(\.day)).count
        let photos = items.filter { Self.inRange($0.day, range) }
        s.photos = Set(photos.map(\.hash)).count
        s.noBird = photos.filter { $0.subjects.isEmpty }.count
        let pend = pending.filter { Self.inRange($0.item.day, range) }
        s.pending = pend.count; s.pendingPhotos = Set(pend.map(\.item.id)).count
        s.list = scoped.values.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
        return s
    }
    var pending: [Pending] {
        items.flatMap { item in item.subjects.filter { !$0.excluded && !Self.eligible($0, known) }.map { Pending(item: item, subject: $0, reason: Self.reason($0, known)) } }
    }
    static func reason(_ s: SubjectItem, _ known: (String) -> Bool) -> String {
        if s.state == "uncertain" { return "已标为不确定" }
        if let k = s.key, !known(k) { return "名录中没有 \(k)，请更正" }
        switch s.level {
        case "genus": return "只到属：\(s.modelKey ?? "")"
        case "unclassified": return "这只还没识别"
        default: return "模型未能确定到种"
        }
    }
    func photos(of species: String) -> [PhotoItem] { items.filter { $0.subjects.contains { Self.eligible($0, known) && $0.key == species } } }
}

/// Gregorian month / year of the device's today, applied to stored local calendar days.
enum Period: Hashable {
    case month(Int, Int), year(Int), all
    static func current(_ today: Date = Date()) -> Period {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: today)
        return .month(c.year!, c.month!)
    }
    var range: (String, String)? {
        switch self {
        case let .month(y, m):
            let days = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: DateComponents(calendar: Calendar(identifier: .gregorian), year: y, month: m).date!)!.count
            return (String(format: "%04d-%02d-01", y, m), String(format: "%04d-%02d-%02d", y, m, days))
        case let .year(y): return (String(format: "%04d-01-01", y), String(format: "%04d-12-31", y))
        case .all: return nil
        }
    }
    var title: String {
        switch self {
        case let .month(y, m): return "\(y) 年 \(m) 月"
        case let .year(y): return "\(y) 年"
        case .all: return "全部记录"
        }
    }
    func shifted(_ d: Int) -> Period {
        switch self {
        case let .month(y, m): let t = y * 12 + m - 1 + d; return .month(t / 12, t % 12 + 1)
        case let .year(y): return .year(y + d)
        case .all: return .all
        }
    }
}
