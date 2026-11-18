import XCTest
@testable import BirdCM

/// The app's whole path against mobile/check.py's Python one (mobile/expected/), on the same photos.
/// Needs the converted models in mobile/build (the simulator reads the Mac's files directly).
final class PipelineTests: XCTestCase {
    func testMatchesPython() throws {
        let expDir = fixtures
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: expDir.appendingPathComponent("expected.json"))) as! [[String: Any]]
        let models=ProcessInfo.processInfo.environment["MODELDIR"] ?? Models.dir.path
        let engine = try Engine(dir: URL(fileURLWithPath: models))
        var visual=[Double](repeating:0,count:engine.rows.count)
        visual[engine.rows.firstIndex{$0[0]=="Turdus merula"}!]=0.5
        visual[engine.rows.firstIndex{$0[0]=="Agelaius phoeniceus"}!]=0.5
        var synthetic=Confirm.decide(p:visual,rows:engine.rows,wide:nil,typical:nil);synthetic.visual=visual
        XCTAssertEqual(synthetic.level,"uncertain")
        let place=Place(lat:33.7,lon:-118.06,label:"Bolsa Chica, California",source:"map")
        var date=Shooting(data:Data());date.takenAt="2026-11-14"
        let local=try engine.rerank(synthetic,place:place,shooting:date)
        XCTAssertEqual(local.level,"species");XCTAssertEqual(local.top5[0].scientific,"Agelaius phoeniceus")
        for (i, c) in cases.enumerated() {
            if i==1 {engine.releaseBioCLIP();XCTAssertNil(engine.lastEmbedding)}
            let path = fixtures.appendingPathComponent(c["path"] as! String).standardized.path, name = URL(fileURLWithPath: path).lastPathComponent   // relative to the repo
            let photo = try XCTUnwrap(Photo(data: Data(contentsOf: URL(fileURLWithPath: path))))
            let size = c["size"] as! [Int]
            XCTAssertEqual([photo.frame.w, photo.frame.h], size, name)
            let box = try XCTUnwrap(engine.detect(photo).first, name)
            let want = c["box"] as! [Double]
            XCTAssertGreaterThan(iou(box, want), 0.95, "\(name) box \(box) vs \(want)")

            // the 224 px input, pixel by pixel
            let mine = engine.crop(photo, want).image
            let theirs = try XCTUnwrap(RGB.load(Data(contentsOf: expDir.appendingPathComponent("\(i).png"))))
            let diffs = zip(mine.px, theirs.px).map { abs(Int($0) - Int($1)) }
            let mean = Double(diffs.reduce(0, +)) / Double(diffs.count)
            print("\(name): 224 px input mean |diff| \(mean), max \(diffs.max()!), exact \(diffs.filter { $0 == 0 }.count)/\(diffs.count)")
            XCTAssertLessThan(mean, 1.0, name)

            let id = try engine.identify(photo, box: want)
            if i==0 {
                let reranked=try engine.rerank(id,place:place,shooting:date)
                let fresh=try engine.identify(photo,box:want,place:place,shooting:date)
                XCTAssertEqual(reranked.top5,fresh.top5);XCTAssertEqual(reranked.level,fresh.level)
            }
            let referencePoints=c["points_normalized"] as! [[Double]],visible=c["visible"] as! [Double]
            let eye=visible[1]>=visible[2] ? 1:2
            for (point,index) in [(id.beak,0),(id.eye,eye)] {
                if let point {for axis in 0..<2 {XCTAssertEqual(point[axis],referencePoints[index][axis],accuracy:0.02)}}
            }
            let e = try XCTUnwrap(engine.lastEmbedding), we = (c["embedding"] as! [Double]).map(Float.init)
            let cos = zip(e, we).map(*).reduce(0, +)
            let top = (c["top5"] as! [[String: Any]]).map { $0["scientific"] as! String }
            print("\(name): cosine to Python \(cos); top5 \(id.top5.map(\.scientific)) vs \(top); flying \(id.flying ?? -1) vs \(c["flying"]!)")
            XCTAssertGreaterThan(cos, 0.995, name)
            XCTAssertEqual(id.top5[0].scientific, top[0], name)
            XCTAssertGreaterThanOrEqual(Set(id.top5.map(\.scientific)).intersection(top).count, 4, name)
            if let f = id.flying { XCTAssertEqual(f > 0.5, (c["flying"] as! Double) > 0.5, name) }
        }
    }

}
