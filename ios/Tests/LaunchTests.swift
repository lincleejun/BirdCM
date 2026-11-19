import XCTest
@testable import BirdCM

/// Launch without waiting: integrity hashing once per build, and a photo picked before the models are ready.
final class LaunchTests: XCTestCase {
    func testFullHashOncePerBuildThenSizeOnly() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let defaults=UserDefaults(suiteName:UUID().uuidString)!
        try Data("abc".utf8).write(to:dir.appendingPathComponent("a"))
        let assets=[Models.Asset(path:"a",url:"",sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",bytes:3)]
        func check(full:Bool=false,build:String="1.0(6)") throws -> (invalid:[String],hashed:Bool) {try Models.check(dir:dir,assets:assets,full:full,defaults:defaults,build:build)}
        var r=try check();XCTAssertEqual(r.invalid,[]);XCTAssertTrue(r.hashed,"first launch of a build hashes")
        r=try check();XCTAssertEqual(r.invalid,[]);XCTAssertFalse(r.hashed,"later launches only stat")
        // Same size, different bytes: only the explicit 完整校验 sees it (the signed bundle cannot change in place).
        try Data("abd".utf8).write(to:dir.appendingPathComponent("a"))
        r=try check();XCTAssertEqual(r.invalid,[]);XCTAssertFalse(r.hashed)
        r=try check(full:true);XCTAssertEqual(r.invalid,["a"]);XCTAssertTrue(r.hashed)
        r=try check();XCTAssertTrue(r.hashed,"a failed pass is not remembered");XCTAssertEqual(r.invalid,["a"])
        try Data("abc".utf8).write(to:dir.appendingPathComponent("a"))
        XCTAssertTrue(try check().hashed);XCTAssertFalse(try check().hashed)
        // A new build hashes again; a wrong size or a missing file fails without hashing.
        XCTAssertTrue(try check(build:"1.0(7)").hashed)
        try Data("abcd".utf8).write(to:dir.appendingPathComponent("a"))
        r=try check(build:"1.0(7)");XCTAssertEqual(r.invalid,["a"]);XCTAssertFalse(r.hashed)
        try FileManager.default.removeItem(at:dir.appendingPathComponent("a"))
        r=try check(build:"1.0(7)");XCTAssertEqual(r.invalid,["a"]);XCTAssertFalse(r.hashed)
        XCTAssertEqual(try Models.check(dir:dir,assets:[],defaults:defaults).invalid,["integrity.json"])
    }

    // The hosted test app does not load models on its own, so each test below starts the load through the queue.
    @MainActor func model() throws -> AppModel {
        try? FileManager.default.removeItem(at:Models.support.appendingPathComponent("LaunchTestHistory"))
        AppModel.loadAttempts=0
        return AppModel(history:"LaunchTestHistory")
    }
    override func tearDown() {for k in ["failModelLoad","delayModelLoad"] {UserDefaults.standard.removeObject(forKey:k)}}
    var photo:Data {get throws {try Data(contentsOf:fixtures.appendingPathComponent("photo-0.jpg"))}}
    @MainActor func until(_ seconds:Double,_ done:@escaping () -> Bool) async {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end {
            if done() {return}
            try? await Task.sleep(for:.milliseconds(50))
        }
    }

    /// Picked before ready: the photo is shown at once with the honest stage, then the result arrives with no second tap.
    /// A failed load keeps the photo; 重试 continues the same identification.
    @MainActor func testPickedBeforeReadyFailsThenRetryContinues() async throws {
        UserDefaults.standard.set(1,forKey:"failModelLoad");UserDefaults.standard.set(0.5,forKey:"delayModelLoad")
        let m=try model(), data=try photo
        let first=Task {await m.identify(data)}
        await until(1) {m.status == AppModel.preparing}
        XCTAssertTrue(m.busy);XCTAssertEqual(m.status,AppModel.preparing);XCTAssertNotNil(m.picked);XCTAssertEqual(m.queued,data)
        await first.value
        XCTAssertNotNil(m.modelError);XCTAssertFalse(m.busy);XCTAssertEqual(m.queued,data,"the photo stays for 重试");XCTAssertNotNil(m.picked);XCTAssertNil(m.current)
        m.retry()
        await until(60) {m.current != nil}
        XCTAssertNil(m.modelError);XCTAssertNil(m.queued);XCTAssertNil(m.picked);XCTAssertFalse(m.busy)
        XCTAssertEqual(m.current?.result?.top5.first?.scientific,"Haliaeetus leucocephalus")
        XCTAssertTrue(m.modelReady);XCTAssertEqual(m.items.count,1)
    }
    /// Cancel while waiting: nothing is saved when the models arrive later.
    @MainActor func testCancelWhileWaitingDropsThePhoto() async throws {
        UserDefaults.standard.set(1,forKey:"delayModelLoad")
        let m=try model(), data=try photo
        let job=Task {await m.identify(data)}
        await until(1) {m.status == AppModel.preparing}
        m.cancel()
        XCTAssertFalse(m.busy);XCTAssertNil(m.queued);XCTAssertNil(m.picked)
        await job.value
        await until(60) {m.modelReady}
        XCTAssertTrue(m.modelReady);XCTAssertNil(m.current);XCTAssertTrue(m.items.isEmpty)
    }
}
