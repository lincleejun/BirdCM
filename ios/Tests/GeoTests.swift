import XCTest
import CryptoKit
@testable import BirdCM
final class GeoTests: XCTestCase {
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func sha(rows v: [[Float]]) -> String { sha(Data(v.flatMap { $0.flatMap { x in withUnsafeBytes(of: x.bitPattern.littleEndian, Array.init) } })) }
    /// Sampled (20 ms) peak phys_footprint of one uncached range map. Named to sort first in the class: only the first
    /// range in a process shows it; later ones reuse pages malloc already holds (0 MB, ~0 faults). Run alone to compare.
    func testColdRangePeakMemory() throws {
        let catalogue = Catalogue.shared, geo = try XCTUnwrap(Geo.shared(catalogue))
        let j = try XCTUnwrap(catalogue.all.firstIndex { $0.sci == "Erithacus rubecula" })
        var u = rusage(); getrusage(RUSAGE_SELF, &u); let faults = u.ru_minflt
        let (v, mb, _) = try PerformanceTests.measure { try XCTUnwrap(geo.range(j, sci: "Erithacus rubecula", cache: false)) }
        getrusage(RUSAGE_SELF, &u)
        XCTAssertEqual(v.count, 69_120)
        print(String(format: "BENCH range peak %.0f MB", mb)); print("BENCH range faults \(u.ru_minflt - faults)")
        XCTAssertLessThanOrEqual(mb, 40)   // old predict (all activations kept to return): 255–525 MB; after E007 about 4 MB
    }
    /// Bit patterns of the real model's outputs, recorded before activations were released early (E007): the global range
    /// of a species other than the timing fixture's, 48 full-head weeks at one point, and a few columns at scattered points.
    func testForwardDigests() throws {
        let catalogue = Catalogue.shared, geo = try XCTUnwrap(Geo.shared(catalogue))
        let j = try XCTUnwrap(catalogue.all.firstIndex { $0.sci == "Erithacus rubecula" })
        let range = try XCTUnwrap(geo.range(j, sci: "Erithacus rubecula", cache: false))
        XCTAssertEqual(range.count, 69_120)
        XCTAssertEqual(Self.sha(Data(range)), "fd57f9f84f4002e5821e4443752223d7ad66fdd4e39c761d38b83fd1574d492c")
        let lima = try geo.network.predict((1...48).map { [Float(-12.05), Float(-77.05), Float($0)] })
        XCTAssertEqual(lima.count, 48); XCTAssertEqual(lima[0].count, 14_082)
        XCTAssertEqual(Self.sha(rows: lima), "cdebc9d0cd5b76391e7fabd829b91358fa2dc9642bdfab021d126c4e08e09691")
        let pts: [[Float]] = [[-12.05, -77.05, 10], [35.7, 139.7, 22], [-1.3, 36.8, 40], [64.1, -21.9, 3], [-54.8, -68.3, 47]]
        XCTAssertEqual(Self.sha(rows: try geo.network.predict(pts, columns: [3, 777, 5000, 9999, 14081])), "ac878ecac40df0bfc6a9f2e657abf91b8bc1ca967b0f2b59f3f460997ada111b")
    }
    /// A tiny inline graph with what the real one lacks: one name used twice by a node, an alias (Unsqueeze), an output
    /// never used, one Split half unused, and `probabilities` read again by a later node. A missing name still throws.
    func testGraphEdgeCases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("geo-e007-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func net(_ nodes: [(String, [String], [String])]) throws -> GeoNetwork {
            let graph: [String: Any] = ["initial": ["zero": ["shape": [1], "values": [0]]],
                                        "nodes": nodes.map { ["op": $0.0, "inputs": $0.1, "outputs": $0.2, "epsilon": 0] }]
            let url = dir.appendingPathComponent("\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: graph).write(to: url)
            return try GeoNetwork(weights: Models.geoURL, graphURL: url)
        }
        let g = try net([("Gather", ["input", "zero"], ["a"]), ("Unsqueeze", ["a"], ["u"]), ("Sin", ["a"], ["unused"]),
                         ("Mul", ["u", "u"], ["sq"]), ("Concat", ["a", "sq"], ["cat"]), ("Split", ["cat"], ["s0", "s1"]),
                         ("Add", ["s0", "sq"], ["probabilities"]), ("Cos", ["probabilities"], ["after"])])
        let xs: [Float] = [0.5, -3, 7.25]
        let out = try g.predict(xs.map { [$0, 1, 2] })
        XCTAssertEqual(out.map { $0.map(\.bitPattern) }, xs.map { [($0 + $0 * $0).bitPattern] })
        XCTAssertThrowsError(try net([("Gather", ["input", "zero"], ["a"]), ("Sin", ["nope"], ["probabilities"])]).predict([[1, 2, 3]]))
        // Each activation released right after its last reader (or its producer when unread); constants and `probabilities` never.
        XCTAssertEqual(g.drop.map(Set.init), [["input"], [], ["unused"], ["u"], ["a"], ["cat", "s1"], ["s0", "sq"], ["after"]])
        // Liveness by name needs single writes: a second write of a name, or a write over a constant or `input`, is refused.
        for bad in [[("Gather", ["input", "zero"], ["a"]), ("Sin", ["a"], ["a"])], [("Sin", ["input"], ["zero"])], [("Sin", ["input"], ["input"])]] {
            XCTAssertThrowsError(try net(bad))
        }
    }
    func testNativeGeoAgainstONNX() throws {
        let path=ProcessInfo.processInfo.environment["GEOMODEL"] ?? Models.geoURL.path
        let net=try GeoNetwork(weights:URL(fileURLWithPath:path),graphURL:Bundle.main.url(forResource:"geo-graph",withExtension:"json")!)
        let points=try JSONDecoder().decode([[Float]].self,from:Data(contentsOf:fixtures.appendingPathComponent("geo-points.json")))
        let reference=try Data(contentsOf:fixtures.appendingPathComponent("geo-reference.f32"))
        let expected=reference.withUnsafeBytes{$0.bindMemory(to:Float.self).map{$0}}
        let actual=try net.predict(points).flatMap{$0}
        XCTAssertEqual(actual.count,expected.count)
        XCTAssertLessThan(zip(actual,expected).map{abs($0-$1)}.max()!,2e-5)
        // Only some output columns: the same numbers as the full head.
        let cols=[0,1234,14081],some=try net.predict(points,columns:cols),full=try net.predict(points)
        for (r,row) in some.enumerated() {for (k,c) in cols.enumerated() {XCTAssertEqual(row[k],full[r][c],accuracy:1e-6)}}
    }
    func testMonthsTiersSeasonsAndGrid() {
        XCTAssertEqual(Geo.monthly((0..<48).map(Double.init)),(0..<12).map{Double($0*4)+1.5})
        XCTAssertEqual(Geo.monthly([Double](repeating:0,count:44)+[1,1,0,0]),[Double](repeating:0,count:11)+[0.5])
        XCTAssertEqual(Geo.median([3,1,2]),2);XCTAssertEqual(Geo.median([4,1,2,3]),2.5);XCTAssertTrue(Geo.median([]).isNaN)
        XCTAssertEqual([0.6,0.3,0.05,0.049,0.01,0.009].map(Geo.modelTier),["常见","不常见","少见","罕见","罕见","不太可能"])
        XCTAssertEqual(Geo.seasonMonths(.breeding,lat:40),[5,6,7]);XCTAssertEqual(Geo.seasonMonths(.breeding,lat:-30),[11,12,1])
        XCTAssertEqual(Geo.seasonMonths(.nonBreeding,lat:0),[12,1,2]);XCTAssertEqual(Geo.seasonMonths(.nonBreeding,lat:-0.5),[6,7,8])
        XCTAssertEqual(Geo.seasonMonths(.year,lat:10).count,12)
        let grid=Geo.rangeGrid(step:3)
        XCTAssertEqual(grid.count,48*120);XCTAssertEqual(grid.first!,[82.5,-178.5]);XCTAssertEqual(grid.last!,[-58.5,178.5])
        XCTAssertEqual(Geo.rangeWeek(1),2);XCTAssertEqual(Geo.rangeWeek(12),46);XCTAssertEqual(Geo.week("2026-12-10"),46)
        // A north and a south cell; June high, December low: north breeding high, south breeding low.
        var v=[UInt8](repeating:0,count:24);v[5]=255;v[12+5]=255;v[11]=51
        let map=Geo.seasonMap(v,grid:[[40,0],[-40,0]],season:.breeding)
        XCTAssertEqual(map,[1,0]);XCTAssertEqual(Geo.seasonMap(v,grid:[[40,0],[-40,0]],season:.nonBreeding),[0.2,1])
        XCTAssertEqual(Geo.seasonMap(v,grid:[[40,0],[-40,0]],season:.year),[1,1])
    }
    func testExploreInclusion() {
        XCTAssertEqual(Likelihood.inclusion(typical:0.5,tier:nil),.main)     // no GBIF coverage: the model alone
        XCTAssertEqual(Likelihood.inclusion(typical:0.6,tier:3),.main)       // likely and reported often enough
        XCTAssertEqual(Likelihood.inclusion(typical:0.6,tier:0),.rare)       // the model says yes, GBIF has nothing
        XCTAssertEqual(Likelihood.inclusion(typical:0.001,tier:4),.rare)     // common state-wide, not here
        XCTAssertEqual(Likelihood.inclusion(typical:0.2,tier:2),.rare)       // 少见 with a middling model value
        XCTAssertEqual(Likelihood.inclusion(typical:0.04,tier:nil),.rare)    // low model value
        XCTAssertEqual(Likelihood.inclusion(typical:nil,tier:1),.rare)       // a single vagrant record
        XCTAssertEqual(Likelihood.inclusion(typical:0.001,tier:1),.rare)
        XCTAssertNil(Likelihood.inclusion(typical:0.009,tier:0))
        XCTAssertNil(Likelihood.inclusion(typical:nil,tier:nil))
        XCTAssertEqual(Likely(sci:"x",median:0.3,share:nil,tier:nil,months:nil,rare:false).label,"不常见")
        XCTAssertEqual(Likely(sci:"x",median:0.3,share:nil,tier:1,months:nil,rare:false).label,"罕见")   // GBIF wins
    }
    /// `Geo.months(at:)` as first written (per element: max over ids, monthly mean, sorted median): the reference it must match.
    static func referenceMonths(_ geo: Geo, at p: Place) throws -> [[Double]?] {
        let pts = p.source == "region" ? geo.cover(p) : [Geo.snap([p.lat, p.lon])]
        var perPoint = [[[Double]?]]()
        for pt in pts {
            let q = try geo.network.predict((1...48).map { [Float(pt[0]), Float(pt[1]), Float($0)] })
            perPoint.append(geo.indices.map { ids in ids.isEmpty ? nil : Geo.monthly(q.map { row in Double(ids.map { row[$0] }.max()!) }) })
        }
        return geo.indices.indices.map { j in geo.indices[j].isEmpty ? nil : (0..<12).map { m in Geo.median(perPoint.map { $0[j]![m] }) } }
    }
    /// Bit for bit (NaN included) and nil in the same places as the reference, on places other than the timing fixtures.
    func testMonthsMatchReference() throws {
        func bits(_ v: [[Double]?]) -> [[UInt64]?] { v.map { $0?.map(\.bitPattern) } }
        let geo = try XCTUnwrap(Geo.shared(Catalogue.shared))
        for p in [Place(lat:39.0,lon:-75.5,label:"美国 · 特拉华州",source:"region"),   // 8 points: even
                  Place(lat:41.7,lon:-71.5,label:"美国 · 罗得岛州",source:"region"),   // 5 points: odd
                  Place(lat:1.35,lon:103.8,label:"新加坡",source:"region"),            // 2 points
                  Place(lat:-33.9,lon:18.4,label:"Cape Town",source:"map"),           // one point
                  Place(lat:10,lon:10,label:"no such region",source:"region")] {     // unknown label: nine points
            XCTAssertEqual(bits(try geo.months(at:p)), bits(try Self.referenceMonths(geo, at:p)), p.label)
        }
        // A species with two model ids (none in the bundled mapping) and regions with a repeated point, from test resources.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("geo-e002-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir, withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        try FileManager.default.copyItem(at:try XCTUnwrap(Bundle.main.url(forResource:"geo-graph",withExtension:"json")), to:dir.appendingPathComponent("geo-graph.json"))
        let mapping = [["scientific":"two","geo3_index":"4165|8384"], ["scientific":"three","geo3_index":"9642|8021|4165"],
                       ["scientific":"one","geo3_index":"8021"], ["scientific":"none","geo3_index":""]]
        let grid = [("even",58.3,-134.4),("even",58.3,-134.4),("even",-27.5,153.0),("even",51.5,-0.1),
                    ("odd",-27.5,153.0),("odd",-27.5,153.0),("odd",58.3,-134.4)].map { ["place":$0.0,"lat":"\($0.1)","lon":"\($0.2)"] }
        try JSONEncoder().encode(mapping).write(to:dir.appendingPathComponent("avilist-birdnet-geo3.json"))
        try JSONEncoder().encode(grid).write(to:dir.appendingPathComponent("region-grid.json"))
        // Only while Geo reads its resources: `resource(_:)` anywhere else in the host would look in `dir` too.
        UserDefaults.standard.set(dir.path, forKey:"resourceDir")
        let test = try { defer { UserDefaults.standard.removeObject(forKey:"resourceDir") }
                         return try Geo(weights:Models.geoURL, scientific:["two","three","one","none","not in mapping"]) }()
        XCTAssertEqual(test.indices, [[4165,8384],[9642,8021,4165],[8021],[],[]])
        for p in [Place(lat:0,lon:0,label:"even",source:"region"), Place(lat:0,lon:0,label:"odd",source:"region"),
                  Place(lat:-27.5,lon:153.0,label:"Brisbane",source:"map")] {
            let months = try test.months(at:p)
            XCTAssertEqual(bits(months), bits(try Self.referenceMonths(test, at:p)), p.label)
            XCTAssertNil(months[3]); XCTAssertNil(months[4])
        }
    }
    /// The real model: a place's year and the global range for the Bald Eagle; a species without a model id has neither.
    func testPlaceYearAndRangeMap() throws {
        let catalogue=Catalogue.shared,geo=try XCTUnwrap(Geo.shared(catalogue))
        let j=try XCTUnwrap(catalogue.all.firstIndex{$0.sci=="Haliaeetus leucocephalus"})
        var t=Date()
        let year=try geo.months(at:Place(lat:58.3,lon:-134.4,label:"Juneau",source:"map"))
        print(String(format:"PERF place year (all species, 48 weeks) %.3f s",Date().timeIntervalSince(t)))
        let eagle=try XCTUnwrap(year[j]);XCTAssertEqual(eagle.count,12);XCTAssertGreaterThan(eagle.max()!,0.2)
        t=Date()
        let region=try geo.months(at:Place(lat:39.8,lon:-98.6,label:"美国",source:"region",regionCode:"US"))
        print(String(format:"PERF region year (美国, %d points) %.3f s",geo.cover(Place(lat:0,lon:0,label:"美国",source:"region")).count,Date().timeIntervalSince(t)))
        XCTAssertGreaterThan(try XCTUnwrap(region[j]).max()!,0.05)
        if let none=geo.indices.firstIndex(where:\.isEmpty) {XCTAssertNil(year[none]);XCTAssertNil(try geo.range(none,sci:"none",cache:false))}
        t=Date()
        let v=try XCTUnwrap(geo.range(j,sci:"Haliaeetus leucocephalus",cache:false))
        print(String(format:"PERF range map %d cells x 12 months %.3f s",Geo.rangeGrid().count,Date().timeIntervalSince(t)))
        let grid=Geo.rangeGrid(),map=Geo.seasonMap(v,grid:grid,season:.year)
        func at(_ lat:Double,_ lon:Double) -> Double {map[grid.indices.min{abs(grid[$0][0]-lat)+abs(grid[$0][1]-lon) < abs(grid[$1][0]-lat)+abs(grid[$1][1]-lon)}!]}
        XCTAssertGreaterThan(at(58,-134),0.3,"Alaska");XCTAssertLessThan(at(-25,134),0.05,"Australia")
    }
    /// Peak phys_footprint (sampled every 20 ms) of `months(at:)` for 美国, printed as a BENCH line.
    func testRegionYearPeakMemory() throws {
        let geo=try XCTUnwrap(Geo.shared(Catalogue.shared))
        let (region,mb,_)=try PerformanceTests.measure { try geo.months(at:Place(lat:39.8,lon:-98.6,label:"美国",source:"region",regionCode:"US")) }
        XCTAssertEqual(region.count,geo.indices.count)
        print(String(format:"BENCH months region peak %.0f MB",mb))
        XCTAssertLessThanOrEqual(mb,120)
    }
}
