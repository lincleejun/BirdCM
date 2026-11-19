import XCTest
@testable import BirdCM
final class GeoTests: XCTestCase {
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
}
