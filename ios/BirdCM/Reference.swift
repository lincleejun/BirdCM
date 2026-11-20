import Foundation
import CryptoKit
import UIKit

/// Online species reference: the Wikipedia summary and one Commons reference image, fetched on demand when a species
/// page opens and cached in Caches. The iOS port of engine/birdcm/online.py (docs/design-species-search.md §4–§9; owner
/// decisions 2026-11-18: on by default and only when needed, the first use shows the disclosure, no translation, NC
/// images allowed but labelled). Same mapping, hosts, states, freshness and licence gate; the tests run the engine's
/// recorded answers (Tests/Fixtures/online).
///
/// Only ids and titles from the bundled mapping (species-map.json, ios/tools/build_species_map.py) leave the device:
/// a species without an accepted mapping gets nothing, nothing is guessed. Never photos, places or typed text.
enum Reference {
    static let userAgent = "BirdCM-iOS/1.0 (https://github.com/lincleejun/BirdCM; open-source local bird photo app)"
    static let hosts: Set<String> = ["zh.wikipedia.org", "en.wikipedia.org", "commons.wikimedia.org", "upload.wikimedia.org", "thumb.wikimedia.org",
                                         "api.inaturalist.org", "inaturalist-open-data.s3.amazonaws.com"]   // Thumb.swift: taxa API, open-licence photos
    static let accept: Set<String> = ["exact-reviewed", "synonym-reviewed"]
    static let day = 86400.0
    static let fresh = 30 * day, textMax = 180 * day, negative = day            // design §6.2
    static let cacheCap = 200 << 20                                                // iOS budget (desktop engine: 500 MiB)
    static let maxJSON = 1 << 20, maxImage = 2 << 20
    static let bySA = "https://creativecommons.org/licenses/by-sa/4.0/"
    static let disclosure = String(localized: "在线资料会把你打开的鸟种对应的 Wikipedia 条目名、Wikidata 编号和 Commons 文件名发送给 Wikipedia / Wikimedia，只在打开物种页时发送；列表里的物种缩略图会把该鸟种的 iNaturalist 分类编号发送给 iNaturalist。不会发送你的照片、拍摄信息、观察记录、位置或输入的搜索词。网站也会接收到网络连接所需的 IP 地址等信息。关闭后仍可离线搜索、查看自己的记录和已经缓存的资料；可在“设置”里删除网络缓存。")

    // MARK: settings (this device only)
    /// On by default (owner 2026-11-18). UI and unit tests read off unless they pass -referenceOnline YES.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "referenceOnline") == nil ? !testing : UserDefaults.standard.bool(forKey: "referenceOnline") }   // a launch argument is the string "YES"
        set { UserDefaults.standard.set(newValue, forKey: "referenceOnline") }
    }
    static var disclosed: Bool {
        get { UserDefaults.standard.bool(forKey: "referenceDisclosed") }
        set { UserDefaults.standard.set(newValue, forKey: "referenceDisclosed") }
    }
    static let testing = UserDefaults.standard.bool(forKey: "uiTesting") || NSClassFromString("XCTestCase") != nil

    // MARK: the mapping
    struct Mapping: Decodable, Equatable {
        var s: String                       // Wikidata match state
        var q: String?, n: String?          // QID, concept note
        var zh: String?, en: String?        // Wikipedia titles
        var f: String?                      // Commons file (P18)
        var i: Int?, g: Int?                // iNaturalist id, GBIF legacy key (only when that source is accepted)
        func article(_ lang: String) -> String? { lang == "zh" ? zh : en }
    }
    static func loadMapping(_ url: URL? = Bundle.main.url(forResource: "species-map", withExtension: "json")) -> [String: Mapping]? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Mapping].self, from: $0) }
    }
    static func articleURL(_ lang: String, _ title: String) -> String {
        "https://\(lang).wikipedia.org/wiki/" + quote(title.replacingOccurrences(of: " ", with: "_"), safe: "/")
    }
    /// Verified deep links only; eBird stays the page's own link (the AviList code in ebird-names.csv).
    static func links(_ m: Mapping?) -> [(name: String, url: String)] {
        guard let m else { return [] }
        var out = [(name: String, url: String)]()
        if accept.contains(m.s) {
            for (lang, name) in [("zh", String(localized: "维基百科（中文）")), ("en", "Wikipedia (English)")] {
                if let t = m.article(lang) { out.append((name, articleURL(lang, t))) }
            }
            if let q = m.q { out.append(("Wikidata", "https://www.wikidata.org/wiki/\(q)")) }
        } else if let q = m.q {
            out.append((String(localized: "Wikidata（来源分类与 AviList 不同）"), "https://www.wikidata.org/wiki/\(q)"))
        }
        if let i = m.i { out.append(("iNaturalist", "https://www.inaturalist.org/taxa/\(i)")) }
        if let g = m.g { out.append(("GBIF", "https://www.gbif.org/species/\(g)")) }
        return out
    }

    // MARK: text helpers
    /// Python's urllib.parse.quote: ASCII unreserved characters and `safe` stay, everything else is UTF-8 percent-encoded.
    static func quote(_ s: String, safe: String = "") -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + safe)) ?? s
    }
    /// urlencode (quote_plus): a space becomes "+".
    static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { quote($0.0) + "=" + quote($0.1, safe: " ").replacingOccurrences(of: " ", with: "+") }.joined(separator: "&")
    }
    /// Markup to plain text: tags dropped, entities decoded, never rendered (no NSAttributedString HTML import).
    static func plain(_ v: String?) -> String {
        var s = (v ?? "").replacing(try! Regex("<[^>]+>"), with: "")
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": "\u{a0}"]
        s = s.replacing(try! Regex("&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+|#39);")) { m -> String in
            let body = String(m.output[1].substring ?? "")
            if let n = named[body] { return n }
            let code = body.hasPrefix("#x") || body.hasPrefix("#X") ? UInt32(body.dropFirst(2), radix: 16) : body.hasPrefix("#") ? UInt32(body.dropFirst()) : nil
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.output[0].substring ?? "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: licence gate (design §7, owner decision on NC)
    struct Licence: Equatable { var licence: String, url: String, nc: Bool, author: String? }
    enum Gate: Equatable { case ok(Licence), refused(String) }
    /// "Salvadori, 1876", "(Linnaeus, 1758)": a taxon authority, not an author.
    static let authority = try! Regex(#"^\(?\s*[^\d()]+,\s*\d{4}\s*\)?$"#)
    static let cc = try! Regex(#"^cc-by(-nc)?(-sa)?-(\d\.\d)(-[a-z]{2,3})?$"#)
    /// Attribution (the author's own required credit line) first, then Artist; an empty Artist or a taxon authority is none.
    static func author(_ meta: [String: String]) -> String? {
        let att = plain(meta["Attribution"])
        if !att.isEmpty { return att }
        let a = plain(meta["Artist"])
        return a.isEmpty || a.wholeMatch(of: authority) != nil ? nil : a
    }
    /// CC0, CC BY, CC BY-SA with a version pass; CC BY-NC(-SA) pass labelled nc; ND, PD without a verified basis, GFDL,
    /// unknown, version-less, non-free, restricted, being deleted, or (unless CC0) without a reliable author do not.
    static func licence(_ meta: [String: String]) -> Gate {
        let code = (meta["License"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if ["true", "1"].contains((meta["NonFree"] ?? "").lowercased()) { return .refused(String(localized: "非自由文件")) }
        if !(meta["DeletionReason"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return .refused(String(localized: "文件正在删除讨论中")) }
        if !plain(meta["Restrictions"]).isEmpty { return .refused(String(localized: "文件带额外限制")) }
        let who = author(meta), url = (meta["LicenseUrl"] ?? "").trimmingCharacters(in: .whitespaces)
        if code == "cc0" { return .ok(Licence(licence: "CC0 1.0", url: url.isEmpty ? "https://creativecommons.org/publicdomain/zero/1.0/" : url, nc: false, author: who)) }
        guard let who else { return .refused(String(localized: "缺可靠的作者署名")) }
        guard let m = code.wholeMatch(of: cc), !code.contains("-nd") else {
            let short = meta["LicenseShortName"] ?? ""
            return .refused(String(localized: "许可不在白名单：\(short.isEmpty ? (code.isEmpty ? String(localized: "未知") : code) : short)"))
        }
        let nc = m.output[1].substring != nil, sa = m.output[2].substring != nil, v = String(m.output[3].substring!)
        let name = "CC BY" + (nc ? "-NC" : "") + (sa ? "-SA" : "") + " \(v)", path = "by" + (nc ? "-nc" : "") + (sa ? "-sa" : "")
        return .ok(Licence(licence: name, url: url.isEmpty ? "https://creativecommons.org/licenses/\(path)/\(v)/" : url, nc: nc, author: who))
    }

    // MARK: cards
    /// One card's state, the same protocol as the engine: ok / stale / none / unmapped / off / unavailable / busy / missing.
    /// On disk it is the entry (with sci, fetched, meta); shown, it carries cachedAt instead.
    struct Card: Codable, Equatable {
        var state: String
        var why: String?, problem: String?, cachedAt: String?, due: Bool?
        var fetched: Double?, sci: String?, meta: [String: String]?
        var lang: String?, title: String?, text: String?, sourceURL: String?, historyURL: String?, revision: String?
        var licence: String?, licenceURL: String?, credit: String?, changes: String?
        var author: String?, nc: Bool?, attribution: String?, file: String?, mime: String?, width: Int?, height: Int?
    }

    enum NetError: Error, Equatable { case offline(String), busy(Double), notFound, refused(String) }
    typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    /// All Wikimedia requests: fixed https hosts, one start every `gap` seconds (30 a minute, design §2.1), a cool-down
    /// after 429 / 503 (Retry-After, else 5 s, 15 s, 60 s), size caps, 3 s per request and 8 s per item.
    actor Net {
        let transport: Transport, gap: Double
        var now: @Sendable () -> Double
        private var last = -Double.infinity, until = 0.0, strikes = 0
        init(transport: @escaping Transport = Net.urlSession, gap: Double = 2, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
            self.transport = transport; self.gap = gap; self.now = now
        }
        func get(_ url: String, limit: Int, accept: String = "application/json", headers: [String: String] = [:]) async throws -> (Data, [String: String]) {
            guard let u = URL(string: url), u.scheme == "https", let host = u.host, Reference.hosts.contains(host) else { throw NetError.refused(url) }
            if now() < until { throw NetError.busy(until - now()) }
            let wait = max(0, gap - (now() - last))
            last = now() + wait
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            var req = URLRequest(url: u)
            req.setValue(Reference.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(accept, forHTTPHeaderField: "Accept")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let data: Data, r: HTTPURLResponse
            do { (data, r) = try await transport(req, limit) }
            catch let e as NetError { throw e }
            catch { throw NetError.offline(error.localizedDescription) }
            switch r.statusCode {
            case 200..<300:
                guard data.count <= limit else { throw NetError.offline("response too large") }
                strikes = 0
                return (data, Dictionary(r.allHeaderFields.map { ("\($0.key)".lowercased(), "\($0.value)") }, uniquingKeysWith: { a, _ in a }))
            case 404: throw NetError.notFound
            case 429, 503:
                let delay = (r.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? [5.0, 15, 60][min(strikes, 2)]
                strikes += 1; until = now() + delay
                throw NetError.busy(delay)
            default: throw NetError.offline("HTTP \(r.statusCode)")
            }
        }

        /// No cookies, no URL cache, redirects only to the same fixed hosts, body streamed against the cap.
        static let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 3; c.timeoutIntervalForResource = 8
            c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: c, delegate: Guard(), delegateQueue: nil)
        }()
        static let urlSession: Transport = { req, limit in
            let (bytes, resp) = try await session.bytes(for: req)
            guard let r = resp as? HTTPURLResponse else { throw NetError.offline("not http") }
            if resp.expectedContentLength > limit { throw NetError.offline("response too large") }
            var d = Data()
            for try await b in bytes { d.append(b); if d.count > limit { throw NetError.offline("response too large") } }
            return (d, r)
        }
        final class Guard: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
                guard let u = request.url, u.scheme == "https", let h = u.host, Reference.hosts.contains(h) else { return nil }   // the 3xx comes back: offline
                return request
            }
        }
    }

    /// One JSON entry per (kind, species), the image bytes beside it, under Caches (not backed up, not in .birdcm).
    struct Cache {
        let dir: URL
        var cap = Reference.cacheCap
        static let standard = Cache(dir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OnlineReference"))
        func base(_ kind: String, _ sci: String) -> URL {
            dir.appendingPathComponent(kind + "-" + Insecure.SHA1.hash(data: Data(sci.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
        }
        func read(_ kind: String, _ sci: String) -> Card? {
            guard let d = try? Data(contentsOf: base(kind, sci).appendingPathExtension("json")), let e = try? JSONDecoder().decode(Card.self, from: d) else { return nil }   // missing or damaged: fetched again
            return e.sci == sci ? e : nil
        }
        /// Atomic: the image first, then the entry that points at it; a full disk leaves the old entry.
        func write(_ kind: String, _ sci: String, _ entry: Card, blob: Data? = nil) {
            var e = entry; e.sci = sci
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let blob { try blob.write(to: base(kind, sci).appendingPathExtension("img"), options: .atomic) }
                try JSONEncoder().encode(e).write(to: base(kind, sci).appendingPathExtension("json"), options: .atomic)
            } catch { return }
            prune()
        }
        /// Under the cap: oldest images go first, then the oldest entries (with their image).
        func prune(cap: Int? = nil) {
            let cap = cap ?? self.cap, keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
            var files = urls.map { u -> (URL, Int, Date) in
                let v = try? u.resourceValues(forKeys: Set(keys)); return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
            }
            var total = files.reduce(0) { $0 + $1.1 }
            guard total > cap else { return }
            files.sort { a, b in
                let (x, y) = (a.0.pathExtension != "img", b.0.pathExtension != "img")
                return x != y ? !x : a.2 < b.2
            }
            for (u, size, _) in files where total > cap {
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                try? FileManager.default.removeItem(at: u); total -= size
                if u.pathExtension == "json" {
                    let img = u.deletingPathExtension().appendingPathExtension("img")
                    if let s = try? img.resourceValues(forKeys: [.fileSizeKey]).fileSize { try? FileManager.default.removeItem(at: img); total -= s }
                }
            }
        }
        func size() -> Int {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        @discardableResult func clear() -> Int { let n = size(); try? FileManager.default.removeItem(at: dir); return n }
        /// The cached reference image, only while its entry still passes the licence gate.
        func image(_ sci: String) -> URL? {
            let u = base("image", sci).appendingPathExtension("img")
            guard let e = read("image", sci), e.state == "ok", case .ok = Reference.licence(e.meta ?? [:]), FileManager.default.fileExists(atPath: u.path) else { return nil }
            return u
        }
    }

    actor Service {
        nonisolated let net: Net, cache: Cache
        var now: @Sendable () -> Double
        private var maps: [String: Mapping]?
        private let mapLoader: @Sendable () -> [String: Mapping]?
        private var inflight = [String: Task<Card, Never>]()
        init(net: Net = Net(), cache: Cache = .standard, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
             mapping: @escaping @Sendable () -> [String: Mapping]? = { Reference.loadMapping() }) {
            self.net = net; self.cache = cache; self.now = now; self.mapLoader = mapping
        }
        /// Read once, off the main thread (about 2 MB of JSON).
        func mapping(_ sci: String) -> Mapping? {
            if maps == nil { maps = mapLoader() ?? [:] }
            return maps?[sci]
        }
        func links(_ sci: String) -> [(name: String, url: String)] { Reference.links(mapping(sci)) }

        /// The card from the cache, refreshed from the source when network is allowed and the entry is missing or stale
        /// (or force: a person's retry, which also skips the one-day negative cache). Errors become states.
        func card(_ kind: String, _ sci: String, network: Bool, force: Bool = false) async -> Card {
            guard let m = mapping(sci) else { return Card(state: "unmapped", why: String(localized: "资料未对应：没有映射数据")) }
            guard Reference.accept.contains(m.s) else {
                return Card(state: "unmapped", why: ["broader", "narrower", "split-lump"].contains(m.s) ? String(localized: "来源分类与 AviList 不同（\(m.n ?? m.s)），不显示在线资料") : String(localized: "资料未对应：映射里没有这个物种的已核验条目"))
            }
            let key = kind + "|" + sci
            if let t = inflight[key] { return await t.value }       // one fetch per species and kind
            let t = Task { await load(kind, sci, m, network: network, force: force) }
            inflight[key] = t
            let c = await t.value
            inflight[key] = nil
            return c
        }
        private func load(_ kind: String, _ sci: String, _ m: Mapping, network: Bool, force: Bool) async -> Card {
            var e = cache.read(kind, sci)
            if let x = e, kind == "image", x.state == "ok", !FileManager.default.fileExists(atPath: cache.base(kind, sci).appendingPathExtension("img").path) { e = nil }   // the image went: fetch again
            var age = e.map { now() - ($0.fetched ?? 0) }
            let due = force || e.map { now() - ($0.fetched ?? 0) > ($0.state == "none" ? Reference.negative : Reference.fresh) } ?? true
            if network && due {
                do {
                    let (entry, blob) = kind == "summary" ? (try await summary(m), nil) : try await image(m)
                    cache.write(kind, sci, entry, blob: blob); e = entry; age = 0
                } catch NetError.notFound {                               // e.g. the file's rendition is gone: absent for a day
                    let x = Card(state: "none", why: String(localized: "来源上已没有这个文件"), fetched: now()); cache.write(kind, sci, x); e = x; age = 0
                } catch NetError.busy {
                    return shown(e, age, "busy")
                } catch {
                    return shown(e, age, "unavailable")
                }
            }
            guard let e else { return Card(state: network ? "unavailable" : "missing", due: true) }
            var out = shown(e, age, nil); out.due = due && !network
            return out
        }
        private func shown(_ e: Card?, _ age: Double?, _ problem: String?) -> Card {
            guard var out = e else { return Card(state: problem ?? "unavailable") }
            out.sci = nil; out.meta = nil
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            out.cachedAt = f.string(from: Date(timeIntervalSince1970: e!.fetched ?? 0)); out.fetched = nil
            if out.state == "ok", let age, age > Reference.fresh { out.state = "stale" }
            if e!.state == "ok", out.text != nil, let age, age > Reference.textMax {
                return Card(state: "stale", why: String(localized: "缓存的简介已超过 180 天，只保留来源链接"), cachedAt: out.cachedAt, sourceURL: out.sourceURL)
            }
            if let problem {
                out.problem = problem
                if e!.state == "ok" { out.state = "stale" }
            }
            return out
        }

        /// zh article first (its simplified variant), then en; no translation. A disambiguation page or one whose
        /// Wikidata item is not the mapped QID is not this species' summary.
        func summary(_ m: Mapping) async throws -> Card {
            var why = String(localized: "维基百科没有这个物种的中文或英文条目")
            for lang in ["zh", "en"] {
                guard let title = m.article(lang) else { continue }
                let url = "https://\(lang).wikipedia.org/api/rest_v1/page/summary/" + Reference.quote(title.replacingOccurrences(of: " ", with: "_"))
                let body: Data
                do { body = try await net.get(url, limit: Reference.maxJSON, headers: lang == "zh" ? ["Accept-Language": "zh-cn"] : [:]).0 }
                catch NetError.notFound { why = String(localized: "\(lang) 条目已不存在"); continue }
                guard let s = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let extract = s["extract"] as? String else { throw NetError.offline("malformed summary") }
                let text = extract.trimmingCharacters(in: .whitespacesAndNewlines)
                if s["type"] as? String == "disambiguation" || s["wikibase_item"] as? String != m.q || text.isEmpty {
                    why = String(localized: "\(lang) 条目与这个物种不对应（消歧义或 Wikidata 条目不符）"); continue
                }
                let page = ((s["content_urls"] as? [String: Any])?["desktop"] as? [String: Any]) ?? [:]
                let shownTitle = Reference.plain(s["displaytitle"] as? String)
                return Card(state: "ok", fetched: now(), lang: lang, title: shownTitle.isEmpty ? (s["title"] as? String ?? title) : shownTitle, text: text,
                            sourceURL: page["page"] as? String ?? Reference.articleURL(lang, title), historyURL: page["revisions"] as? String,
                            revision: s["revision"].map { "\($0)" }, licence: "CC BY-SA 4.0", licenceURL: Reference.bySA,
                            credit: String(localized: "维基百科贡献者"), changes: lang == "zh" ? String(localized: "原文摘录；简体由维基百科自动转换") : String(localized: "原文摘录"))
            }
            return Card(state: "none", why: why, fetched: now())
        }

        /// The Commons file the build chose (Wikidata P18), its metadata, the licence gate, then the 640 px rendition.
        func image(_ m: Mapping) async throws -> (Card, Data?) {
            guard let f = m.f else { return (Card(state: "none", why: String(localized: "Wikidata 没有这个物种的图片"), fetched: now()), nil) }
            let q = Reference.form([("action", "query"), ("prop", "imageinfo"), ("titles", "File:\(f)"), ("format", "json"), ("formatversion", "2"),
                                    ("iiprop", "url|extmetadata|sha1|mime|size"), ("iiurlwidth", "640"),
                                    ("iiextmetadatafilter", "Artist|Credit|Attribution|LicenseShortName|License|LicenseUrl|UsageTerms|Restrictions|NonFree|DeletionReason|ObjectName")])
            let body = try await net.get("https://commons.wikimedia.org/w/api.php?" + q, limit: Reference.maxJSON).0
            guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let page = ((root["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
                  let info = (page["imageinfo"] as? [[String: Any]])?.first else {
                return (Card(state: "none", why: String(localized: "Commons 上找不到这个文件"), fetched: now()), nil)
            }
            var meta = [String: String]()
            for (k, v) in info["extmetadata"] as? [String: Any] ?? [:] {
                let value = (v as? [String: Any])?["value"]
                meta[k] = value.map { $0 as? String ?? "\($0)" } ?? ""
            }
            let source = info["descriptionurl"] as? String
            guard case .ok(let lic) = Reference.licence(meta) else {
                if case .refused(let why) = Reference.licence(meta) { return (Card(state: "none", why: String(localized: "暂无可用的授权参考图（\(why)）"), fetched: now(), sourceURL: source), nil) }
                return (Card(state: "none", fetched: now()), nil)
            }
            let thumb = info["thumburl"] as? String ?? ""
            guard (info["mime"] as? String ?? "").hasPrefix("image/"), let h = URL(string: thumb)?.host, Reference.hosts.contains(h) else {
                return (Card(state: "none", why: String(localized: "暂无可用的授权参考图（不是图片）"), fetched: now()), nil)
            }
            let (blob, headers) = try await net.get(thumb, limit: Reference.maxImage, accept: "image/*")
            guard (headers["content-type"] ?? "").hasPrefix("image/") else { throw NetError.offline("not an image") }
            return (Card(state: "ok", fetched: now(), meta: meta, sourceURL: source, licence: lic.licence, licenceURL: lic.url,
                         credit: Reference.plain(meta["Credit"]), changes: String(localized: "缩放为 640 px 宽"), author: lic.author, nc: lic.nc,
                         attribution: Reference.plain(meta["Attribution"]), file: f, mime: headers["content-type"],
                         width: info["thumbwidth"] as? Int, height: info["thumbheight"] as? Int), blob)
        }
    }

    static let shared = Service(net: Net(transport: debugTransport ?? Net.urlSession))
    #if DEBUG
    /// -referenceFixtures <dir>: answers from the engine's recorded fixtures (exact URL), a drawn JPEG for any
    /// thumb.wikimedia.org rendition, and an error for anything else. Starts from an empty cache.
    static let debugTransport: Transport? = {
        guard let dir = UserDefaults.standard.string(forKey: "referenceFixtures") else { return nil }
        Cache.standard.clear()
        var routes = [String: (Int, Data)]()
        for u in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [] {
            guard let d = try? Data(contentsOf: u), let f = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let url = f["url"] as? String,
                  let body = f["body"], let data = try? JSONSerialization.data(withJSONObject: body) else { continue }
            routes[url] = (f["status"] as? Int ?? 200, data)
        }
        let r = routes
        return { req, _ in
            let url = req.url!.absoluteString
            func reply(_ status: Int, _ type: String, _ data: Data) -> (Data, HTTPURLResponse) {
                (data, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!)
            }
            if url.hasPrefix("https://thumb.wikimedia.org/") { return reply(200, "image/jpeg", drawnJPEG()) }
            guard let (status, data) = r[url] else { throw NetError.offline("no fixture for \(url)") }
            return reply(status, "application/json", data)
        }
    }()
    /// A made-up picture: no third-party photo is committed.
    static func drawnJPEG() -> Data {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 538), format: f).jpegData(withCompressionQuality: 0.8) { c in
            UIColor(red: 0.62, green: 0.55, blue: 0.45, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 640, height: 538))
            UIColor(red: 0.36, green: 0.27, blue: 0.2, alpha: 1).setFill(); UIBezierPath(ovalIn: CGRect(x: 200, y: 180, width: 260, height: 170)).fill()
            UIBezierPath(ovalIn: CGRect(x: 410, y: 140, width: 110, height: 100)).fill()
        }
    }
    #else
    static let debugTransport: Transport? = nil
    #endif
}

/// Update check, the iOS port of engine/birdcm/update.py: off by default (UserDefaults "updateCheck", like the other
/// network switches). When on, at most one GET a day to GitHub's public API for the latest release tag; the request
/// carries nothing about the person or this install (ephemeral session: no cookie, cache or credential; no current
/// version; the fixed User-Agent of Reference). Redirects are not followed. Any failure is silent and counts as the
/// day's check. Settings links to the Releases page; nothing is downloaded or installed.
enum Update {
    static let latest = URL(string: "https://api.github.com/repos/lincleejun/BirdCM/releases/latest")!
    static let releases = URL(string: "https://github.com/lincleejun/BirdCM/releases")!
    static let day = 86400.0
    static var current: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// "release/vX.Y.Z" -> "X.Y.Z"; anything else (v1.2.3, release/v1.2.3-beta) is no answer.
    static func version(tag: String?) -> String? {
        guard let m = tag?.wholeMatch(of: /release\/v(\d+)\.(\d+)\.(\d+)/) else { return nil }
        return "\(m.1).\(m.2).\(m.3)"
    }
    /// latest is a release x.y.z; cur may be a prerelease (0.0.2b0, 0.0.2-beta), which is older than the same x.y.z.
    static func newer(_ latest: String?, _ cur: String?) -> Bool {
        func parse(_ s: String?) -> (Int, Int, Int, Int)? {        // the last field: 1 for a release, 0 for a prerelease
            guard let m = s?.wholeMatch(of: /(\d+)\.(\d+)\.(\d+)(.*)/), let x = Int(m.1), let y = Int(m.2), let z = Int(m.3) else { return nil }
            return (x, y, z, m.4.isEmpty ? 1 : 0)
        }
        guard let a = parse(latest), a.3 == 1, let b = parse(cur) else { return false }
        return a > b
    }
    /// Off asks nothing; on asks when there is no check yet or the last one is not within the past day.
    static func due(enabled: Bool, checked: Double?, now: Double) -> Bool {
        guard enabled else { return false }
        guard let checked else { return true }
        return !(0..<day).contains(now - checked)
    }
    static var request: URLRequest {
        var r = URLRequest(url: latest)
        r.setValue(Reference.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")   // fixed: CFNetwork would otherwise send the device's languages
        return r
    }
    /// The latest release's version, nil on any failure (offline, rate limit, 404, a 3xx, a body we cannot read).
    static func ask(_ transport: Reference.Transport) async -> String? {
        guard let (data, r) = try? await transport(request, Reference.maxJSON), r.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return version(tag: json["tag_name"] as? String)
    }
    /// The newer version to offer, or nil. Asks the network only when `due`; the stamp is written before the request,
    /// so overlapping calls send one, and a failure counts as checked.
    static func check(_ d: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970, current: String? = Update.current,
                      transport: Reference.Transport = Update.transport) async -> String? {
        let enabled = d.bool(forKey: "updateCheck")
        if due(enabled: enabled, checked: d.object(forKey: "updateChecked") as? Double, now: now) {
            d.set(now, forKey: "updateChecked")
            let v = await ask(transport)
            if let v { d.set(v, forKey: "updateLatest") } else { d.removeObject(forKey: "updateLatest") }
        }
        let v = d.string(forKey: "updateLatest")
        return enabled && newer(v, current) ? v : nil
    }
    /// Ephemeral: no cookie, URL cache or stored credential; short timeouts; a redirect is not followed (the 3xx is a failure).
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3; c.timeoutIntervalForResource = 8
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()
    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }
    static let transport: Reference.Transport = { req, limit in
        let (data, resp) = try await session.data(for: req)
        guard let r = resp as? HTTPURLResponse, data.count <= limit else { throw URLError(.badServerResponse) }
        return (data, r)
    }
}
