import XCTest

/// Launch and model-loading behaviour with the bundled engine. PERF tests print timings; the app's own
/// marks (process start → home, → models ready, per identification, main-thread hitches) go to Caches/perf.log.
final class LaunchFlows: XCTestCase {
    let app=XCUIApplication()
    var image:String {Bundle(for:LaunchFlows.self).resourceURL!.appendingPathComponent("Fixtures/photo-0.jpg").path}
    override func setUp(){continueAfterFailure=false}
    func element(_ id:String)->XCUIElement {
        let matches=app.descendants(matching:.any).matching(identifier:id)
        return matches.allElementsBoundByIndex.first(where:{$0.isHittable}) ?? matches.firstMatch
    }
    func launch(_ extra:[String]=[],reset:Bool=true) {
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory",reset ? "YES":"NO","-fixtureImage",image]+extra;app.launch()
    }
    func wait(_ id:String,_ timeout:Double,file:StaticString=#filePath,line:UInt=#line) {XCTAssertTrue(element(id).waitForExistence(timeout:timeout),"missing \(id)",file:file,line:line)}
    /// Settings → 诊断 → CC0 fixture: the real receive path with the bundled engine.
    func pickFixture() {
        element("home.more").tap();wait("settings.done",5);element("home.diagnostics").tap()
        wait("sheet.done",5)
        for _ in 0..<6 where !(element("diagnostics.fixture").exists && element("diagnostics.fixture").isHittable) {app.swipeUp()}
        element("diagnostics.fixture").tap()
    }
    func back() {app.navigationBars.buttons.allElementsBoundByIndex.first{$0.isHittable && $0.identifier != "home.more" && $0.label != "结果操作"}?.tap()}

    func status(_ text:String,_ timeout:Double) {
        expectation(for:NSPredicate(format:"label CONTAINS %@",text),evaluatedWith:element("home.modelStatus"));waitForExpectations(timeout:timeout)
    }
    /// While the models load, home, its place controls, picker, camera and all four tabs work; the state is one quiet line.
    func testHomeUsableWhileModelsLoad() throws {
        launch(["-delayModelLoad","60"]);wait("home.photos",10)
        XCTAssertTrue(element("home.photos").isEnabled);XCTAssertTrue(element("home.camera").isEnabled);XCTAssertTrue(element("home.map").isEnabled)
        XCTAssertTrue(element("home.modelStatus").label.contains("正在准备"));XCTAssertFalse(element("identifying").exists)
        for (label,id) in [("记录","records.mode"),("统计","stats.period"),("探索","explore.mode")] {app.tabBars.buttons[label].firstMatch.tap();wait(id,10)}
        app.tabBars.buttons["识别"].firstMatch.tap();wait("home.photos",5)
        element("home.map").tap();XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout:5))
    }
    /// A photo taken before the models are ready is shown at once with the honest stage, then finishes with no second tap.
    func testPickBeforeReadyContinuesAutomatically() throws {
        launch(["-delayModelLoad","15","-cameraFixture","YES"]);wait("home.camera",10)
        element("home.camera").tap();wait("place.skip",5);element("place.skip").tap()
        wait("identifying",5);XCTAssertEqual(element("identifying.stage").label,"正在准备模型…")
        XCTAssertTrue(element("identifying.cancel").exists)
        wait("result.name",90);XCTAssertEqual(element("result.name").label,"白头海雕")
    }
    /// The first load fails: the waiting photo stays with the error and 重试 continues it; home shows its own 重试.
    func testLoadFailureThenRetry() throws {
        launch(["-delayModelLoad","2","-failModelLoad","1","-cameraFixture","YES"]);wait("home.camera",10)
        element("home.camera").tap();wait("place.skip",5);element("place.skip").tap()
        wait("identifying.retry",30);XCTAssertTrue(element("home.modelStatus").label.contains("失败") || !element("home.modelStatus").isHittable)
        element("identifying.retry").tap()
        wait("result.name",90);XCTAssertEqual(element("result.name").label,"白头海雕")
        launch(["-failModelLoad","1"]);wait("home.modelRetry",30);XCTAssertTrue(element("home.modelStatus").label.contains("失败"))
        element("home.modelRetry").tap();status("就绪",90)
    }

    /// Cold launch → picker usable → models ready → first and second real identification.
    func testPerfLaunchAndIdentify() throws {
        var t=Date();launch()
        wait("home.photos",120);print(String(format:"PERF ui home.photos %.2f s",Date().timeIntervalSince(t)))
        expectation(for:NSPredicate(format:"enabled == YES"),evaluatedWith:element("home.photos"));waitForExpectations(timeout:120)
        print(String(format:"PERF ui picker enabled %.2f s",Date().timeIntervalSince(t)))
        if element("home.modelStatus").exists {status("就绪",120);print(String(format:"PERF ui models ready %.2f s",Date().timeIntervalSince(t)))}
        sleep(8)
        t=Date();pickFixture();wait("result.name",120);print(String(format:"PERF ui first identification %.2f s",Date().timeIntervalSince(t)))
        back();t=Date();pickFixture();wait("result.name",120);print(String(format:"PERF ui second identification %.2f s",Date().timeIntervalSince(t)))
    }
    /// 10,000 synthetic photos: browse records and statistics; the app logs main-thread waits > 100 ms as HITCH lines.
    func testPerfTenThousandBrowse() throws {
        launch(["-fixtureState","normal","-seedSynthetic","10000"]);wait("home.photos",300)
        var t=Date();launch(["-fixtureState","normal"],reset:false);wait("home.photos",120)
        print(String(format:"PERF ui 10k cold launch to home %.2f s",Date().timeIntervalSince(t)))
        t=Date();app.tabBars.buttons["记录"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'records.species.'")).firstMatch.waitForExistence(timeout:60))
        print(String(format:"PERF ui 10k records %.2f s",Date().timeIntervalSince(t)))
        for _ in 0..<3 {app.swipeUp()}
        app.segmentedControls.buttons["照片"].firstMatch.tap();wait("history.sort",60)
        for _ in 0..<4 {app.swipeUp()}
        t=Date();app.tabBars.buttons["统计"].firstMatch.tap();wait("stats.species",60)
        print(String(format:"PERF ui 10k statistics %.2f s",Date().timeIntervalSince(t)))
        for _ in 0..<3 {app.swipeUp()}
        element("stats.period").buttons["本年"].tap();sleep(1)
        element("stats.period").buttons["全部"].firstMatch.tap();sleep(1)
        app.tabBars.buttons["识别"].firstMatch.tap();sleep(2)
    }
}
