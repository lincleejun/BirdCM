import XCTest
@testable import BirdCM

/// iNaturalist list thumbnails (BirdCM/Thumb.swift). Parsing runs one recorded /v1/taxa answer (Fixtures/inat-taxa.json,
/// 2026-11-19, trimmed to id / name / rank / is_active / default_photo); everything else goes to a stub, no live network.
final class ThumbTests: XCTestCase {
    static let fixture = Bundle(for: ThumbTests.self).resourceURL!.appendingPathComponent("Fixtures/inat-taxa.json")
    func body() throws -> Data {
        let f = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: f["body"]!)
    }

    func testParseRecordedTaxa() throws {
        let cards = try XCTUnwrap(Thumb.parse(body(), now: 5))
        XCTAssertEqual(Set(cards.keys), [13858, 2548, 6036])
        let sparrow = cards[13858]!
        XCTAssertEqual(sparrow.state, "ok")
        XCTAssertEqual(sparrow.licence, "CC BY-NC-SA"); XCTAssertEqual(sparrow.nc, true)
        XCTAssertEqual(sparrow.author, "Ximo Galarza")
        XCTAssertEqual(sparrow.file, "https://inaturalist-open-data.s3.amazonaws.com/photos/4608133/square.jpg")
        XCTAssertEqual(sparrow.sourceURL, "https://www.inaturalist.org/taxa/13858")
        XCTAssertEqual(sparrow.fetched, 5)
        XCTAssertEqual(Thumb.credit(sparrow), "© Ximo Galarza · CC BY-NC-SA · iNaturalist")
        XCTAssertEqual(cards[2548]?.licence, "CC BY-NC")
        XCTAssertEqual(cards[6036]?.state, "none")                    // license_code null: all rights reserved
        XCTAssertNil(Thumb.parse(Data("<html>".utf8), now: 0))
    }

    func testLicenceGate() {
        for (code, name, nc) in [("cc0", "CC0", false), ("cc-by", "CC BY", false), ("cc-by-sa", "CC BY-SA", false),
                                 ("cc-by-nc", "CC BY-NC", true), ("CC-BY-NC-SA", "CC BY-NC-SA", true)] {
            XCTAssertEqual(Thumb.licence(code)?.name, name); XCTAssertEqual(Thumb.licence(code)?.nc, nc)
        }
        for code in ["cc-by-nd", "cc-by-nc-nd", "", "pd", nil] { XCTAssertNil(Thumb.licence(code), code ?? "nil") }
        XCTAssertEqual(Thumb.credit(.init(state: "ok", licence: "CC0", author: "A")), "A · CC0 · iNaturalist")
    }

    func testSizeVariantAndPhotoURL() {
        XCTAssertEqual(Thumb.variant(px: 60), "square"); XCTAssertEqual(Thumb.variant(px: 88), "small")
        XCTAssertEqual(Thumb.variant(px: 240), "small"); XCTAssertEqual(Thumb.variant(px: 300), "medium")
        let sq = "https://inaturalist-open-data.s3.amazonaws.com/photos/4608133/square.jpg"
        XCTAssertEqual(Thumb.photoURL(sq, "small"), "https://inaturalist-open-data.s3.amazonaws.com/photos/4608133/small.jpg")
        XCTAssertEqual(Thumb.photoURL(sq.replacingOccurrences(of: ".jpg", with: ".jpeg"), "medium"), "https://inaturalist-open-data.s3.amazonaws.com/photos/4608133/medium.jpeg")
        for bad in ["http://inaturalist-open-data.s3.amazonaws.com/photos/1/square.jpg", "https://example.com/photos/1/square.jpg",
                    "https://static.inaturalist.org/photos/1/square.jpg", "https://inaturalist-open-data.s3.amazonaws.com/photos/1/huge.jpg"] {
            XCTAssertNil(Thumb.photoURL(bad, "small"), bad)
        }
    }

    // MARK: loader

    final class Stub: @unchecked Sendable {
        let lock = NSLock()
        var apiCalls = [(ids: [Int], at: Double)](), images = 0, active = 0, peak = 0, failAPI = false
        func transport(_ req: URLRequest, _ limit: Int) async throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), Reference.userAgent)
            let url = req.url!
            func http(_ type: String) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])! }
            if url.host == "api.inaturalist.org" {
                let ids = url.lastPathComponent.split(separator: ",").map { Int($0)! }
                let fail = lock.withLock { apiCalls.append((ids, ProcessInfo.processInfo.systemUptime)); return failAPI }
                if fail { throw URLError(.notConnectedToInternet) }
                let results = ids.map { id -> [String: Any] in
                    ["id": id, "default_photo": ["url": "https://inaturalist-open-data.s3.amazonaws.com/photos/\(id)/square.jpg",
                                                  "attribution": "(c) P\(id), some rights reserved (CC BY)", "attribution_name": "P\(id)",
                                                  "license_code": id == 7 ? "cc-by-nd" : "cc-by"]]
                }
                return (try JSONSerialization.data(withJSONObject: ["total_results": ids.count, "results": results]), http("application/json"))
            }
            XCTAssertEqual(url.host, "inaturalist-open-data.s3.amazonaws.com"); XCTAssertEqual(url.lastPathComponent, "small.jpg")
            lock.withLock { images += 1; active += 1; peak = max(peak, active) }
            try await Task.sleep(for: .milliseconds(20))
            lock.withLock { active -= 1 }
            return (Data([0xFF, 0xD8, 0xFF]), http("image/jpeg"))
        }
    }
    final class Clock: @unchecked Sendable { var t = 1_000_000.0 }

    var stub = Stub(), clock = Clock(), dir: URL!
    override func setUp() { stub = Stub(); clock = Clock(); dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    /// "S<n>" maps to taxon n (accepted); "U" is a broader match and "N" has no iNaturalist id.
    func loader(gap: Double = 0) -> Thumb.Loader {
        let stub = stub, clock = clock
        return Thumb.Loader(api: Reference.Net(transport: stub.transport, gap: gap), images: Reference.Net(transport: stub.transport, gap: 0),
                            cache: Reference.Cache(dir: dir), debounce: .milliseconds(30), now: { clock.t }) { sci in
            if sci == "U" { return .init(s: "broader", i: 1) }
            if sci == "N" { return .init(s: "exact-reviewed") }
            return Int(sci.dropFirst()).map { .init(s: "exact-reviewed", i: $0) }
        }
    }

    func testBatchesRateAndDownloadCap() async {
        let l = loader(gap: 0.2), ids = Array(1...35).filter { $0 != 7 }
        let got = await withTaskGroup(of: (Int, Bool).self) { g in
            for id in 1...35 { g.addTask { (id, await l.image("S\(id)", variant: "small", network: true) != nil) } }
            return await g.reduce(into: [Int: Bool]()) { $0[$1.0] = $1.1 }
        }
        XCTAssertEqual(got.filter(\.value).keys.sorted(), ids)       // 7 is ND: placeholder
        XCTAssertGreaterThanOrEqual(stub.apiCalls.count, 2)
        XCTAssertTrue(stub.apiCalls.allSatisfy { $0.ids.count <= Thumb.maxIDs })
        XCTAssertEqual(stub.apiCalls.flatMap(\.ids).sorted(), Array(1...35))   // each id asked once
        for (a, b) in zip(stub.apiCalls, stub.apiCalls.dropFirst()) { XCTAssertGreaterThanOrEqual(b.at - a.at, 0.19) }
        XCTAssertEqual(stub.images, 34)
        XCTAssertLessThanOrEqual(stub.peak, Thumb.downloads)
    }

    func testCacheFreshnessNegativeAndKeys() async {
        let l = loader(), cache = Reference.Cache(dir: dir)
        XCTAssertNotEqual(cache.base(Thumb.kind("small"), "S1"), cache.base("image", "S1"))
        XCTAssertNotEqual(cache.base(Thumb.kind("small"), "S1"), cache.base(Thumb.kind("square"), "S1"))
        var r = await l.image("S1", variant: "small", network: false); XCTAssertNil(r)   // nothing cached, no network: no request
        XCTAssertEqual(stub.apiCalls.count, 0)
        let ok = await l.image("S1", variant: "small", network: true)
        XCTAssertEqual(ok?.card.file, "https://inaturalist-open-data.s3.amazonaws.com/photos/1/small.jpg")
        r = await l.image("S7", variant: "small", network: true); XCTAssertNil(r)
        XCTAssertEqual(stub.apiCalls.count, 2)
        clock.t += 20 * 3600                                               // both fresh: no requests
        r = await l.image("S1", variant: "small", network: true); XCTAssertNotNil(r)
        r = await l.image("S7", variant: "small", network: true); XCTAssertNil(r)
        XCTAssertEqual(stub.apiCalls.count, 2)
        clock.t += 5 * 3600                                                // the refusal is retried after a day
        _ = await l.image("S7", variant: "small", network: true); XCTAssertEqual(stub.apiCalls.count, 3)
        clock.t += 31 * 86400; stub.failAPI = true                         // stale and offline: the cached picture stays
        r = await l.image("S1", variant: "small", network: true); XCTAssertNotNil(r); XCTAssertEqual(stub.apiCalls.count, 4)
        cache.clear()                                                      // 删除网络缓存
        r = await l.image("S1", variant: "small", network: false); XCTAssertNil(r)
    }

    func testOnlyAcceptedMappingsLeaveTheDevice() async {
        let l = loader()
        for sci in ["U", "N", "Unknown species"] { let r = await l.image(sci, variant: "small", network: true); XCTAssertNil(r) }
        XCTAssertEqual(stub.apiCalls.count, 0)
    }
}
