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
    }
}
