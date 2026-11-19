import SwiftUI
import UIKit

/// Explore-list thumbnails: the iNaturalist taxon default photo, fetched at runtime only (owner 2026-11-19: no
/// build-time data, no generated images, iNaturalist rather than Wikimedia for the list; Wikipedia text stays on the
/// species page). Same rules as 物种参考 (Reference.swift): only while 在线物种资料 is on and its disclosure was seen,
/// only accepted mappings from species-map.json (no iNaturalist id → placeholder, nothing guessed), only the taxon id
/// leaves the device, cached under the same Caches folder (counted in its cap, cleared by 删除网络缓存).
/// A web reference picture: never used in the person's records, grids or stats.
///
/// API facts (https://api.inaturalist.org/v1/docs/ and its swagger.json; API Recommended Practices,
/// https://www.inaturalist.org/pages/api+recommended+practices, read 2026-11-19 from the 2026-10-16 web.archive.org capture):
/// GET /v1/taxa/{id,id,…} returns at most 30 taxa; `default_photo` has url / square_url / medium_url, attribution and
/// license_code; sizes are changed by replacing only the size qualifier (square 75 px, small 240, medium 500); about 1
/// request a second, 429 when exceeded; identify the app with a custom User-Agent.
enum Thumb {
    static let api = "https://api.inaturalist.org/v1/taxa/"
    static let maxIDs = 30
    static let maxTaxa = 4 << 20, maxImage = 1 << 20     // no documented `fields`: 30 full taxa are about 2 MB
    static let downloads = 4                               // photos at once
    static let hint = "网络参考图 · iNaturalist"

    /// The smallest documented variant at least `px` across (square is cropped, small and medium keep the aspect).
    static func variant(px: Int) -> String { [("square", 75), ("small", 240)].first { $0.1 >= px }?.0 ?? "medium" }

    static let photo = try! Regex(#"^(https://[^/]+/photos/\d+/)(square|thumb|small|medium|large|original)(\.[A-Za-z]+)$"#)
    /// The same photo at another size: only the qualifier changes; anything else, or a host off the allowlist, is refused.
    static func photoURL(_ url: String?, _ variant: String) -> String? {
        guard let url, let m = url.wholeMatch(of: photo), let host = URL(string: url)?.host, Reference.hosts.contains(host) else { return nil }
        return String(m.output[1].substring!) + variant + String(m.output[3].substring!)
    }

    /// CC0, CC BY, CC BY-SA, CC BY-NC(-SA) (NC labelled); ND and none (all rights reserved) are refused.
    static let licences = ["cc0": "CC0", "cc-by": "CC BY", "cc-by-sa": "CC BY-SA", "cc-by-nc": "CC BY-NC", "cc-by-nc-sa": "CC BY-NC-SA"]
    static func licence(_ code: String?) -> (name: String, nc: Bool)? {
        code.flatMap { licences[$0.lowercased()] }.map { ($0, $0.contains("NC")) }
    }

    /// One entry per taxon in a /v1/taxa answer: ok (licence, author, the photo's reported url) or none (why).
    static func parse(_ data: Data, now: Double) -> [Int: Reference.Card]? {
        struct Photo: Decodable { var url: String?, attribution: String?, attribution_name: String?, license_code: String? }
        struct Taxon: Decodable { var id: Int, default_photo: Photo? }
        struct Page: Decodable { var results: [Taxon] }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        var out = [Int: Reference.Card]()
        for t in page.results {
            let source = "https://www.inaturalist.org/taxa/\(t.id)"
            guard let p = t.default_photo else { out[t.id] = .init(state: "none", why: "iNaturalist 没有默认照片", fetched: now, sourceURL: source); continue }
            guard let lic = licence(p.license_code) else {
                out[t.id] = .init(state: "none", why: "许可不在白名单：\(p.license_code ?? "保留所有权利")", fetched: now, sourceURL: source); continue
            }
            guard photoURL(p.url, "square") != nil else { out[t.id] = .init(state: "none", why: "照片地址不可用", fetched: now, sourceURL: source); continue }
            out[t.id] = .init(state: "ok", fetched: now, meta: ["license_code": p.license_code!], sourceURL: source, licence: lic.name,
                              author: p.attribution_name ?? p.attribution, nc: lic.nc, attribution: p.attribution, file: p.url)
        }
        return out
    }

    /// "© author · licence · iNaturalist" (no © on CC0, nor on the full attribution line, which carries its own "(c)").
    static func credit(_ c: Reference.Card) -> String {
        let own = c.licence == "CC0" || c.author == c.attribution
        return [own ? c.author : c.author.map { "© " + $0 }, c.licence, "iNaturalist"].compactMap { $0 }.joined(separator: " · ")
    }

    static func kind(_ variant: String) -> String { "inat-" + variant }
    /// The cached picture and its entry, only while the entry still passes the licence gate.
    static func cached(_ cache: Reference.Cache, _ sci: String, _ variant: String) -> (url: URL, card: Reference.Card)? {
        let u = cache.base(kind(variant), sci).appendingPathExtension("img")
        guard let e = cache.read(kind(variant), sci), e.state == "ok", licence(e.meta?["license_code"]) != nil,
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return (u, e)
    }

    /// Rows ask for their species; ids waiting together go out as one /v1/taxa request (≤ 30 ids, the API Net keeps
    /// ≥ 1 s between starts and backs off after 429), photos download a few at a time.
    actor Loader {
        nonisolated let api: Reference.Net, images: Reference.Net, cache: Reference.Cache
        let mapping: @Sendable (String) async -> Reference.Mapping?
        let now: @Sendable () -> Double
        let debounce: Duration
        private var order = [Int](), waiters = [Int: [CheckedContinuation<Reference.Card?, Never>]](), flushing = false
        private var inflight = [String: Task<(url: URL, card: Reference.Card)?, Never>]()
        private var free = Thumb.downloads, queue = [CheckedContinuation<Void, Never>]()

        init(api: Reference.Net, images: Reference.Net, cache: Reference.Cache = .standard, debounce: Duration = .milliseconds(100),
             now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
             mapping: @escaping @Sendable (String) async -> Reference.Mapping? = { await Reference.shared.mapping($0) }) {
            self.api = api; self.images = images; self.cache = cache; self.debounce = debounce; self.now = now; self.mapping = mapping
        }

        /// The cached picture, fetched first when `network` and the entry is missing or due (30 days; 1 day when none).
        func image(_ sci: String, variant: String, network: Bool) async -> (url: URL, card: Reference.Card)? {
            let key = Thumb.kind(variant) + "|" + sci + (network ? "|net" : "")
            if let t = inflight[key] { return await t.value }
            let t = Task { await load(sci, variant, network) }
            inflight[key] = t
            let r = await t.value
            inflight[key] = nil
            return r
        }

        private func load(_ sci: String, _ variant: String, _ network: Bool) async -> (url: URL, card: Reference.Card)? {
            let kind = Thumb.kind(variant), have = Thumb.cached(cache, sci, variant)
            let e = cache.read(kind, sci)
            let due = have == nil && e?.state == "ok" ? true : e.map { now() - ($0.fetched ?? 0) > ($0.state == "none" ? Reference.negative : Reference.fresh) } ?? true
            guard network, due, let m = await mapping(sci), Reference.accept.contains(m.s), let id = m.i else { return have }
            guard var c = await taxon(id) else { return have }              // offline or busy: keep what is cached
            guard c.state == "ok", let url = Thumb.photoURL(c.file, variant) else { cache.write(kind, sci, c); return nil }
            do {
                let (blob, headers) = try await download(url)
                guard (headers["content-type"] ?? "").hasPrefix("image/") else { return have }
                c.file = url
                // ponytail: Cache.write prunes (one directory scan) per thumb; batch the prune if scrolling ever stutters.
                cache.write(kind, sci, c, blob: blob)
            } catch Reference.NetError.notFound {
                cache.write(kind, sci, .init(state: "none", why: "照片已不在 iNaturalist", fetched: now(), sourceURL: c.sourceURL))
            } catch { return have }
            return Thumb.cached(cache, sci, variant)
        }

        /// The taxon's entry from the next batch; nil when the request failed (nothing is cached then).
        func taxon(_ id: Int) async -> Reference.Card? {
            await withCheckedContinuation { c in
                if waiters[id] == nil { order.append(id) }
                waiters[id, default: []].append(c)
                if !flushing { flushing = true; Task { await flush() } }
            }
        }
        private func flush() async {
            while !order.isEmpty {
                try? await Task.sleep(for: debounce)
                let ids = Array(order.prefix(Thumb.maxIDs))
                order.removeFirst(ids.count)
                let body = try? await api.get(Thumb.api + ids.map(String.init).joined(separator: ","), limit: Thumb.maxTaxa).0
                let got = body.flatMap { Thumb.parse($0, now: now()) }
                for id in ids {
                    let card = got.map { $0[id] ?? .init(state: "none", why: "iNaturalist 上没有这个分类", fetched: now()) }
                    for w in waiters.removeValue(forKey: id) ?? [] { w.resume(returning: card) }
                }
            }
            flushing = false
        }

        private func download(_ url: String) async throws -> (Data, [String: String]) {
            if free > 0 { free -= 1 } else { await withCheckedContinuation { queue.append($0) } }
            defer { if queue.isEmpty { free += 1 } else { queue.removeFirst().resume() } }
            return try await images.get(url, limit: Thumb.maxImage, accept: "image/*")
        }
    }

    static let shared = Loader(api: Reference.Net(transport: Reference.debugTransport ?? Reference.Net.urlSession, gap: 1),
                               images: Reference.Net(transport: Reference.debugTransport ?? Reference.Net.urlSession, gap: 0))
}

/// A species' small iNaturalist reference picture for a list row's leading slot; a placeholder when there is none.
/// Long press: author, licence, link to the taxon page.
struct SpeciesThumb: View {
    let key: String                         // scientific name, the species-map.json key
    var size: CGFloat = 44
    @State private var shown: Shown?
    final class Shown { let image: UIImage, card: Reference.Card; init(_ i: UIImage, _ c: Reference.Card) { image = i; card = c } }
    static let memory = NSCache<NSString, Shown>()

    var body: some View {
        Group {
            if let shown { Image(uiImage: shown.image).resizable().scaledToFill() }
            else { Image(systemName: "bird").font(.system(size: size * 0.45)).foregroundStyle(Palette.tertiary) }
        }
        .frame(width: size, height: size).background(Palette.inset)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2)).contentShape(RoundedRectangle(cornerRadius: size * 0.2))
        .accessibilityElement().accessibilityLabel(shown == nil ? "" : "网络参考图").accessibilityHint(shown == nil ? "" : Thumb.hint)
        .accessibilityHidden(shown == nil)
        .contextMenu {
            if let c = shown?.card {
                Text(Thumb.credit(c))
                if c.nc == true { Text("非商业许可（NC）") }
                if let s = c.sourceURL, let u = URL(string: s) { Link("在 iNaturalist 查看", destination: u) }
            }
        }
        .task(id: key) { await load() }
    }

    func load() async {
        let variant = Thumb.variant(px: Int(size * 2)), mem = "\(variant)|\(key)" as NSString
        if let m = Self.memory.object(forKey: mem) { shown = m; return }
        shown = nil
        let first = await Thumb.shared.image(key, variant: variant, network: false)
        if let first { await show(first, mem) }
        guard Reference.enabled, Reference.disclosed,
              first.map({ Date().timeIntervalSince1970 - ($0.card.fetched ?? 0) > Reference.fresh }) ?? true else { return }
        try? await Task.sleep(for: .milliseconds(150))                     // a row flung past asks for nothing
        guard !Task.isCancelled, let r = await Thumb.shared.image(key, variant: variant, network: true) else { return }
        await show(r, mem)
    }
    func show(_ r: (url: URL, card: Reference.Card), _ mem: NSString) async {
        guard let img = await Task.detached(operation: { UIImage(contentsOfFile: r.url.path)?.preparingForDisplay() }).value, !Task.isCancelled else { return }
        let s = Shown(img, r.card)
        Self.memory.setObject(s, forKey: mem); shown = s
    }
}
