import XCTest
@testable import BirdCM

/// Online species reference (BirdCM/Reference.swift) over the engine's recorded answers (Fixtures/online, copied from
/// engine/tests/fixtures/online; recorded 2026-11-18/19 from zh/en.wikipedia.org, text CC BY-SA 4.0, Wikipedia
/// contributors, and commons.wikimedia.org file metadata). No live network: every request goes to a stub that fails the
/// test on a URL it does not know. Image bytes are drawn here; no third-party photo is committed. Mirrors
/// engine/tests/test_online.py case for case.
final class ReferenceTests: XCTestCase {
    static let fx = Bundle(for: ReferenceTests.self).resourceURL!.appendingPathComponent("Fixtures/online")
    static let zh = "https://zh.wikipedia.org/api/rest_v1/page/summary/", en = "https://en.wikipedia.org/api/rest_v1/page/summary/"
    static let commons = "https://commons.wikimedia.org/w/api.php", thumb = "https://thumb.wikimedia.org/"
    let sparrow = Reference.Mapping(s: "exact-reviewed", q: "Q14683", zh: "家麻雀", en: "House sparrow", f: "House Sparrow, England - May 09.jpg", i: 13858, g: 5231190)
    let sci = "Passer domesticus"

    enum Reply { case fixture([String: Any]), bytes(Data), error(Error) }
    final class Stub: @unchecked Sendable {
        var routes = [(String, Reply)](), calls = [String]()
        subscript(prefix: String) -> Reply? {
            get { routes.first { $0.0 == prefix }?.1 }
            set { routes.removeAll { $0.0 == prefix }; if let newValue { routes.append((prefix, newValue)) } }
        }
        @Sendable func transport(_ req: URLRequest, _ limit: Int) async throws -> (Data, HTTPURLResponse) {
            let url = req.url!.absoluteString
            calls.append(url)
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), Reference.userAgent)
            guard let reply = routes.first(where: { url.hasPrefix($0.0) })?.1 else { XCTFail("unexpected request \(url)"); throw URLError(.cancelled) }
            func http(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse { HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)! }
            switch reply {
            case .error(let e): throw e
            case .bytes(let d): return (d, http(200, ["Content-Type": "image/jpeg"]))
            case .fixture(let f):
                let status = f["status"] as? Int ?? 200
                let body = try JSONSerialization.data(withJSONObject: f["body"] ?? [:])
                return (body, http(status, (f["headers"] as? [String: String] ?? [:]).merging(["Content-Type": "application/json"]) { a, _ in a }))
            }
        }
    }
    final class Clock: @unchecked Sendable { var t = Date().timeIntervalSince1970 }

    var stub = Stub(), clock = Clock(), dir: URL!
    var maps = [String: Reference.Mapping]()
    var service: Reference.Service!

    override func setUp() {
        stub = Stub(); clock = Clock(); maps = [sci: sparrow]
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("reference-\(UUID().uuidString)")
        makeService()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    func makeService() {
        let stub = stub, clock = clock, maps = maps
        service = Reference.Service(net: Reference.Net(transport: stub.transport, gap: 0), cache: Reference.Cache(dir: dir), now: { clock.t }, mapping: { maps })
    }
    func fixture(_ name: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(contentsOf: Self.fx.appendingPathComponent(name))) as! [String: Any]
    }
    /// The fixture with one extmetadata value replaced.
    func commons(_ name: String, _ changes: [String: String]) -> [String: Any] {
        var f = fixture(name), body = f["body"] as! [String: Any], query = body["query"] as! [String: Any]
        var pages = query["pages"] as! [[String: Any]], info = pages[0]["imageinfo"] as! [[String: Any]], meta = info[0]["extmetadata"] as! [String: Any]
        for (k, v) in changes { meta[k] = ["value": v] }
        info[0]["extmetadata"] = meta; pages[0]["imageinfo"] = info; query["pages"] = pages; body["query"] = query; f["body"] = body
        return f
    }
    var jpeg: Reply { .bytes(Reference.drawnJPEG()) }
    func card(_ kind: String, network: Bool = true, force: Bool = false, _ sci: String? = nil) async -> Reference.Card {
        await service.card(kind, sci ?? self.sci, network: network, force: force)
    }

    // MARK: the bundled mapping
    func testMappingPackage() throws {
        let m = try XCTUnwrap(Reference.loadMapping())
        XCTAssertEqual(m.count, 11172)
        XCTAssertEqual(m[sci], sparrow)
        XCTAssertEqual(m["Porphyrio porphyrio"]?.s, "narrower")                                   // a reviewed lump: no content
        XCTAssertNil(m["Nothing here"])
        let accepted = m.values.filter { Reference.accept.contains($0.s) }
        XCTAssertTrue(accepted.allSatisfy { $0.q != nil })
        XCTAssertEqual(Set(accepted.map(\.q)).count, accepted.count, "no accepted QID shared by two species")
        XCTAssertTrue(m.values.filter { ["ambiguous", "unmapped"].contains($0.s) }.allSatisfy { $0.q == nil })
        let names = Set(EBird.names.keys)
        XCTAssertTrue(names.isEmpty || Set(m.keys) == names, "one row per AviList key")
        let links = Dictionary(uniqueKeysWithValues: Reference.links(m[sci]).map { ($0.name, $0.url) })
        XCTAssertEqual(links["Wikidata"], "https://www.wikidata.org/wiki/Q14683")
        XCTAssertEqual(links["维基百科（中文）"], "https://zh.wikipedia.org/wiki/%E5%AE%B6%E9%BA%BB%E9%9B%80")
        XCTAssertEqual(links["Wikipedia (English)"], "https://en.wikipedia.org/wiki/House_sparrow")
        XCTAssertEqual(links["iNaturalist"], "https://www.inaturalist.org/taxa/13858")
        XCTAssertEqual(links["GBIF"], "https://www.gbif.org/species/5231190")
    }
    func testLinksOnlyForAcceptedStates() {
        XCTAssertTrue(Reference.links(nil).isEmpty)
        var m = sparrow; m.s = "narrower"; m.i = nil; m.g = nil
        XCTAssertEqual(Reference.links(m).map(\.name), ["Wikidata（来源分类与 AviList 不同）"])
        m.s = "ambiguous"; m.q = nil
        XCTAssertEqual(Reference.links(m).map(\.name), [])
    }

    // MARK: Wikipedia summary
    func testSummaryZh() async {
        stub[Self.zh] = .fixture(fixture("zh-summary-passer-domesticus.json"))
        let c = await card("summary")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(c.lang, "zh"); XCTAssertEqual(c.title, "家麻雀")
        XCTAssertTrue(c.text!.contains("麻雀属"))
        XCTAssertEqual(c.licence, "CC BY-SA 4.0"); XCTAssertTrue(c.licenceURL!.hasPrefix("https://creativecommons.org/licenses/by-sa/4.0"))
        XCTAssertEqual(c.revision, "87011385"); XCTAssertTrue(c.historyURL!.hasSuffix("action=history")); XCTAssertTrue(c.sourceURL!.hasPrefix("https://zh.wikipedia.org/"))
        XCTAssertTrue(c.changes!.contains("原文摘录")); XCTAssertEqual(c.credit, "维基百科贡献者")
        XCTAssertNil(c.meta); XCTAssertNil(c.sci); XCTAssertNotNil(c.cachedAt)
        XCTAssertEqual(stub.calls, [Self.zh + "%E5%AE%B6%E9%BA%BB%E9%9B%80"])
        // cached: no second request, and offline reading gives the same card
        let again = await card("summary")
        XCTAssertEqual(again.state, "ok"); XCTAssertEqual(stub.calls.count, 1)
        let offline = await card("summary", network: false)
        XCTAssertEqual(offline.text, c.text); XCTAssertEqual(offline.due, false)
    }
    func testSummaryMissingZhFallsBackToEnOnce() async {
        maps[sci]?.zh = nil; makeService()
        stub[Self.en] = .fixture(fixture("en-summary-passer-domesticus.json"))
        let c = await card("summary")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(c.lang, "en"); XCTAssertTrue(c.text!.hasPrefix("The house sparrow"))
        XCTAssertEqual(stub.calls, [Self.en + "House_sparrow"])
    }
    func testSummaryZh404ThenEn() async {
        stub[Self.zh] = .fixture(fixture("zh-summary-404.json"))
        stub[Self.en] = .fixture(fixture("en-summary-passer-domesticus.json"))
        let c = await card("summary")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(c.lang, "en"); XCTAssertEqual(stub.calls.count, 2)
    }
    func testSummary404EverywhereIsNegativeCached() async {
        stub[Self.zh] = .fixture(fixture("zh-summary-404.json")); stub[Self.en] = .fixture(fixture("zh-summary-404.json"))
        let a = await card("summary"), b = await card("summary")
        XCTAssertEqual(a.state, "none"); XCTAssertEqual(b.state, "none"); XCTAssertEqual(stub.calls.count, 2)     // a day
        _ = await card("summary", force: true)                                                                      // a retry asks
        XCTAssertEqual(stub.calls.count, 4)
        clock.t += Reference.day + 1
        _ = await card("summary")
        XCTAssertEqual(stub.calls.count, 6, "the negative cache lasts a day")
    }
    func testSummaryWrongItemOrDisambiguationIsNotThisSpecies() async {
        stub[Self.zh] = .fixture(fixture("zh-summary-404.json"))
        stub[Self.en] = .fixture(fixture("en-summary-swamphen-genus-redirect.json"))                            // the genus: another QID
        let c = await card("summary")
        XCTAssertEqual(c.state, "none"); XCTAssertTrue(c.why!.contains("不对应"))
        var d = fixture("en-summary-passer-domesticus.json"), body = d["body"] as! [String: Any]
        body["type"] = "disambiguation"; d["body"] = body
        stub[Self.en] = .fixture(d)
        let e = await card("summary", force: true)
        XCTAssertEqual(e.state, "none")
    }
    func testSummaryTimeoutAndOfflineCacheHit() async {
        stub[Self.zh] = .error(URLError(.timedOut))
        let a = await card("summary")
        XCTAssertEqual(a.state, "unavailable")
        XCTAssertNil(Reference.Cache(dir: dir).read("summary", sci), "a timeout is not cached as absent")
        stub[Self.zh] = .fixture(fixture("zh-summary-passer-domesticus.json"))
        let b = await card("summary")
        XCTAssertEqual(b.state, "ok")
        // a month later, offline: the cached copy, marked stale with its date
        clock.t += 31 * Reference.day
        stub[Self.zh] = .error(URLError(.notConnectedToInternet))
        let c = await card("summary")
        XCTAssertEqual(c.state, "stale"); XCTAssertEqual(c.problem, "unavailable"); XCTAssertNotNil(c.text); XCTAssertNotNil(c.cachedAt)
        // half a year later the text is no longer shown, only the link
        clock.t += 150 * Reference.day
        let d = await card("summary", network: false)
        XCTAssertEqual(d.state, "stale"); XCTAssertNil(d.text); XCTAssertNotNil(d.sourceURL); XCTAssertEqual(d.due, true)
    }
    func testSummary429CoolsDown() async {
        stub[Self.zh] = .fixture(["status": 429, "headers": ["Retry-After": "120"], "body": [:]])
        let a = await card("summary")
        XCTAssertEqual(a.state, "busy")
        let n = stub.calls.count
        let b = await card("summary")
        XCTAssertEqual(b.state, "busy"); XCTAssertEqual(stub.calls.count, n, "not asked again")
    }
    func testUnmappedSpeciesNeverAsks() async {
        maps["Porphyrio porphyrio"] = Reference.Mapping(s: "narrower", q: "Q187902", n: "lump", en: "Western swamphen", f: "Purpurhuhn.jpg"); makeService()
        for kind in ["summary", "image"] {
            let a = await card(kind, "Nothing here"), b = await card(kind, "Porphyrio porphyrio")
            XCTAssertEqual(a.state, "unmapped"); XCTAssertEqual(a.why, "资料未对应：没有映射数据")
            XCTAssertEqual(b.state, "unmapped"); XCTAssertTrue(b.why!.contains("来源分类与 AviList 不同"))
        }
        XCTAssertEqual(stub.calls, [])
    }
    func testHostsAreFixed() async {
        let net = Reference.Net(transport: stub.transport, gap: 0)
        for url in ["https://evil.example/x", "http://zh.wikipedia.org/x"] {
            do { _ = try await net.get(url, limit: 100); XCTFail("asked \(url)") } catch { XCTAssertEqual(error as? Reference.NetError, .refused(url)) }
        }
        XCTAssertEqual(stub.calls, [])
    }
    func testOversizedResponseIsRefused() async {
        stub[Self.zh] = .fixture(fixture("zh-summary-passer-domesticus.json"))
        let net = Reference.Net(transport: stub.transport, gap: 0)
        do { _ = try await net.get(Self.zh + "x", limit: 100); XCTFail("accepted") } catch { XCTAssertEqual(error as? Reference.NetError, .offline("response too large")) }
    }

    // MARK: licence gate and the Commons image
    let base = ["Artist": #"<a href="//commons.wikimedia.org/wiki/User:X">X</a>"#, "Restrictions": "", "LicenseUrl": ""]
    func testLicenceGate() {
        let table: [(String, String?, Bool)] = [
            ("cc0", "CC0 1.0", false), ("cc-by-4.0", "CC BY 4.0", false), ("cc-by-sa-3.0", "CC BY-SA 3.0", false),
            ("cc-by-sa-3.0-de", "CC BY-SA 3.0", false), ("cc-by-nc-4.0", "CC BY-NC 4.0", true), ("cc-by-nc-sa-2.0", "CC BY-NC-SA 2.0", true),
            ("cc-by-nd-4.0", nil, false), ("cc-by-nc-nd-4.0", nil, false), ("cc-by-sa", nil, false),                  // no version
            ("pd", nil, false), ("gfdl", nil, false), ("", nil, false),
        ]
        for (code, name, nc) in table {
            let gate = Reference.licence(base.merging(["License": code]) { $1 })
            if let name {
                guard case .ok(let l) = gate else { XCTFail("refused \(code)"); continue }
                XCTAssertEqual(l.licence, name); XCTAssertEqual(l.nc, nc); XCTAssertEqual(l.author, "X"); XCTAssertTrue(l.url.hasPrefix("https://creativecommons.org/"), code)
            } else if case .ok = gate { XCTFail("accepted \(code)") }
        }
    }
    func testLicenceGateRefusesRestrictedNonfreeDeletedOrAnonymous() {
        let by = base.merging(["License": "cc-by-4.0"]) { $1 }
        for change in [["Restrictions": "personality"], ["NonFree": "true"], ["DeletionReason": "copyvio"], ["Artist": "<span> </span>"]] {
            if case .ok = Reference.licence(by.merging(change) { $1 }) { XCTFail("accepted \(change)") }
        }
        guard case .ok(let l) = Reference.licence(by.merging(["Artist": "<script>x</script>A &amp; B"]) { $1 }) else { return XCTFail() }
        XCTAssertEqual(l.author, "xA & B")
    }
    func testAuthorIsNotATaxonAuthority() {
        let table: [(String, String?)] = [
            ("Salvadori, 1876", nil), ("(Linnaeus, 1758)", nil), ("Gould & Sharpe, 1880", nil), ("<span> </span>", nil), ("Diliff", "Diliff"),
            (#"<a href="//commons.wikimedia.org/wiki/User:X">JJ Harrison</a> (https://www.jjharrison.com.au/)"#, "JJ Harrison (https://www.jjharrison.com.au/)"),
            ("Ernst Haeckel 1904", "Ernst Haeckel 1904"),
        ]
        for (artist, author) in table {
            XCTAssertEqual(Reference.author(["Artist": artist]), author, artist)
            XCTAssertEqual(Reference.author(["Artist": artist, "Attribution": "<b>Photo by Y</b>"]), "Photo by Y")   // the required credit line wins
        }
    }
    func testPlainDecodesEntitiesAndDropsMarkup() {
        XCTAssertEqual(Reference.plain("<i>Passer</i> &lt;x&gt; &#233;t&#xE9; &quot;q&quot;"), "Passer <x> été \"q\"")
    }
    func testCommonsRequestMatchesTheEngine() async {
        // The engine's recorded request URL, byte for byte: the same query order and quote_plus encoding.
        let f = fixture("commons-imageinfo-cc-by-sa.json")
        stub[f["url"] as! String] = .fixture(f); stub[Self.thumb] = jpeg
        let c = await card("image")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(stub.calls.first, f["url"] as? String)
    }
    func testCC0WithAuthorityAsArtistPointsToTheFilePage() async {
        stub[Self.commons] = .fixture(fixture("commons-imageinfo-authority-as-artist.json")); stub[Self.thumb] = jpeg
        let c = await card("image")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(c.licence, "CC0 1.0"); XCTAssertNil(c.author)
        XCTAssertEqual(c.credit, "Naturalis Biodiversity Center"); XCTAssertTrue(c.sourceURL!.hasPrefix("https://commons.wikimedia.org/wiki/File:"))
    }
    func testAttributionLicenceWithAuthorityAsArtistIsRefused() async {
        stub[Self.commons] = .fixture(commons("commons-imageinfo-authority-as-artist.json", ["License": "cc-by-4.0"]))
        let c = await card("image")
        XCTAssertEqual(c.state, "none"); XCTAssertTrue(c.why!.contains("作者")); XCTAssertNil(service.cache.image(sci))
        stub[Self.commons] = .fixture(commons("commons-imageinfo-authority-as-artist.json", ["License": "cc-by-sa-3.0", "Artist": ""]))
        let d = await card("image", force: true)
        XCTAssertEqual(d.state, "none")
    }
    func testDisclosureNamesOnlyWhatIsBuilt() {
        XCTAssertTrue(Reference.disclosure.contains("不会发送你的照片"))
        for absent in ["地区包", "在线查名称", "Nominatim"] { XCTAssertFalse(Reference.disclosure.contains(absent), absent) }
    }
    func testImageRendition404IsAbsent() async {
        stub[Self.commons] = .fixture(fixture("commons-imageinfo-cc-by-sa.json")); stub[Self.thumb] = .fixture(["status": 404, "body": [:]])
        let c = await card("image")
        XCTAssertEqual(c.state, "none"); XCTAssertEqual(service.cache.read("image", sci)?.state, "none")
    }
    func testImageEntryWithoutItsFileIsFetchedAgain() async throws {
        stub[Self.commons] = .fixture(fixture("commons-imageinfo-cc-by-sa.json")); stub[Self.thumb] = jpeg
        _ = await card("image")
        try FileManager.default.removeItem(at: XCTUnwrap(service.cache.image(sci)))
        let a = await card("image", network: false)
        XCTAssertEqual(a.state, "missing")
        let b = await card("image")
        XCTAssertEqual(b.state, "ok"); XCTAssertNotNil(service.cache.image(sci))
    }
    func testImageOkCachedAndServed() async throws {
        stub[Self.commons] = .fixture(fixture("commons-imageinfo-cc-by-sa.json")); stub[Self.thumb] = jpeg
        let c = await card("image")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(c.licence, "CC BY-SA 3.0"); XCTAssertEqual(c.author, "Diliff"); XCTAssertEqual(c.nc, false)
        XCTAssertEqual(c.sourceURL, "https://commons.wikimedia.org/wiki/File:House_Sparrow,_England_-_May_09.jpg")
        XCTAssertEqual(c.width, 640); XCTAssertEqual(c.mime, "image/jpeg"); XCTAssertNil(c.meta)
        let file = try XCTUnwrap(service.cache.image(sci))
        XCTAssertEqual(try Data(contentsOf: file).prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(stub.calls.count, 2)
        let again = await card("image")
        XCTAssertEqual(again.state, "ok"); XCTAssertEqual(stub.calls.count, 2)
    }
    func testNCImageIsLabelled() async {
        stub[Self.commons] = .fixture(commons("commons-imageinfo-cc-by-sa.json", ["License": "cc-by-nc-sa-2.0", "LicenseUrl": ""])); stub[Self.thumb] = jpeg
        let c = await card("image")
        XCTAssertEqual(c.state, "ok"); XCTAssertEqual(c.nc, true); XCTAssertEqual(c.licence, "CC BY-NC-SA 2.0")
        XCTAssertEqual(c.licenceURL, "https://creativecommons.org/licenses/by-nc-sa/2.0/")
    }
    func testImageRefusedLicenceWritesNoFile() async {
        stub[Self.commons] = .fixture(commons("commons-imageinfo-cc-by-sa.json", ["License": "cc-by-nd-4.0"]))
        let c = await card("image")
        XCTAssertEqual(c.state, "none"); XCTAssertTrue(c.why!.contains("暂无可用的授权参考图"))
        XCTAssertFalse(stub.calls.contains { $0.hasPrefix(Self.thumb) }); XCTAssertNil(service.cache.image(sci))
    }
    func testCacheCapDropsImagesFirst() async throws {
        stub[Self.commons] = .fixture(fixture("commons-imageinfo-cc-by-sa.json")); stub[Self.thumb] = jpeg
        stub[Self.zh] = .fixture(fixture("zh-summary-passer-domesticus.json"))
        _ = await card("image"); _ = await card("summary")
        let cache = service.cache
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        cache.prune(cap: try files.filter { $0.pathExtension != "img" }.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) })   // room for all but the image
        XCTAssertNil(cache.image(sci)); XCTAssertNotNil(cache.read("summary", sci))
        XCTAssertGreaterThan(cache.clear(), 0); XCTAssertNil(cache.read("summary", sci))
    }
}
