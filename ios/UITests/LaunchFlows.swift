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

    /// Cold launch → picker usable → (models ready) → first and second real identification.
    func testPerfLaunchAndIdentify() throws {
        var t=Date();launch()
        wait("home.photos",120);print(String(format:"PERF ui home.photos %.2f s",Date().timeIntervalSince(t)))
        expectation(for:NSPredicate(format:"enabled == YES"),evaluatedWith:element("home.photos"));waitForExpectations(timeout:120)
        print(String(format:"PERF ui picker enabled %.2f s",Date().timeIntervalSince(t)))
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
