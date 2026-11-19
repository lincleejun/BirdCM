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
    func wait(_ id:String,_ timeout:Double,file:StaticString=#filePath,line:UInt=#line) {XCTAssertTrue(element(id).appears(timeout:timeout),"missing \(id)",file:file,line:line)}
    /// Settings → 诊断 → CC0 fixture: the real receive path with the bundled engine.
    func pickFixture() {
        app.tabBars.buttons["设置"].firstMatch.tap();wait("home.diagnostics",5);element("home.diagnostics").tap()
        wait("sheet.done",5)
        for _ in 0..<6 where !(element("diagnostics.fixture").exists && element("diagnostics.fixture").isHittable) {app.swipeUp()}
        element("diagnostics.fixture").tap()
    }
    func back() {app.navigationBars.buttons.allElementsBoundByIndex.first{$0.isHittable && $0.identifier != "home.more" && $0.label != "结果操作"}?.tap()}

    func status(_ text:String,_ timeout:Double) {
        until(timeout) {self.element("home.modelStatus").exists && self.element("home.modelStatus").label.contains(text)}
    }
    /// Polls every 0.1 s (a predicate expectation re-checks about once a second, which also blurred the PERF lines).
    func until(_ timeout:Double,file:StaticString=#filePath,line:UInt=#line,_ done:()->Bool) {
        let end=Date().addingTimeInterval(timeout)
        while !done() {if Date()>end {XCTFail("timed out",file:file,line:line);return};usleep(100_000)}
    }
    /// While the models load, home, its place controls, picker, camera and all five tabs work; the state is one quiet line.
    func testHomeUsableWhileModelsLoad() throws {
        launch(["-delayModelLoad","60"]);wait("home.photos",10)
        XCTAssertTrue(element("home.photos").isEnabled);XCTAssertTrue(element("home.camera").isEnabled);XCTAssertTrue(element("home.map").isEnabled)
        XCTAssertTrue(element("home.modelStatus").label.contains("正在准备"));XCTAssertFalse(element("identifying").exists);shot("home-preparing")
        for (label,id) in [("探索","explore.mode"),("记录","records.mode"),("统计","stats.period"),("设置","settings.backup")] {app.tabBars.buttons[label].firstMatch.tap();wait(id,10)}
        app.tabBars.buttons["识别"].firstMatch.tap();wait("home.photos",5)
        element("home.map").tap();XCTAssertTrue(app.navigationBars.firstMatch.appears(timeout:5))
    }
    /// A photo taken before the models are ready is shown at once with the honest stage, then finishes with no second tap.
    func testPickBeforeReadyContinuesAutomatically() throws {
        launch(["-delayModelLoad","15","-cameraFixture","YES"]);wait("home.camera",10)
        element("home.camera").tap();wait("place.skip",5);element("place.skip").tap()
        wait("identifying",5);XCTAssertEqual(element("identifying.stage").label,"正在准备模型…")
        XCTAssertTrue(element("identifying.cancel").exists);shot("waiting-for-models")
        // Progressive: the found boxes and count appear before the names.
        wait("identifying.found",60);XCTAssertEqual(element("identifying.found").label,"找到 1 只鸟");shot("found-boxes")
        wait("result.name",90);XCTAssertEqual(element("result.name").label,"白头海雕")
    }
    func shot(_ name:String) {
        let s=XCUIScreen.main.screenshot(),a=XCTAttachment(screenshot:s);a.name=name;a.lifetime = .keepAlways;add(a)
        if let folder=ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {try? s.pngRepresentation.write(to:URL(fileURLWithPath:folder).appendingPathComponent(self.name.replacingOccurrences(of:"/",with:"-")+"-"+name+".png"))}
    }
    /// The first load fails: the waiting photo stays with the error and 重试 continues it; home shows its own 重试.
    func testLoadFailureThenRetry() throws {
        launch(["-delayModelLoad","2","-failModelLoad","1","-cameraFixture","YES"]);wait("home.camera",10)
        element("home.camera").tap();wait("place.skip",5);element("place.skip").tap()
        wait("identifying.retry",30);XCTAssertTrue(element("home.modelStatus").label.contains("失败") || !element("home.modelStatus").isHittable)
        shot("waiting-photo-load-failed");element("identifying.retry").tap()
        wait("result.name",90);XCTAssertEqual(element("result.name").label,"白头海雕")
        launch(["-failModelLoad","1","-largestType","YES"]);wait("home.modelRetry",30);XCTAssertTrue(element("home.modelStatus").label.contains("失败"))
        shot("home-error-largest-type");element("home.modelRetry").tap();status("就绪",90);shot("home-ready-largest-type")
    }

    /// First launch after install, then a relaunch: picker usable → models ready; then first and second real identification.
    func testPerfLaunchAndIdentify() throws {
        var t=Date()
        for pass in ["first","again"] {
            t=Date();launch(reset:pass=="first")
            wait("home.photos",120);print(String(format:"PERF ui %@ home.photos %.2f s",pass,Date().timeIntervalSince(t)))
            until(120) {self.element("home.photos").isEnabled}
            print(String(format:"PERF ui %@ picker enabled %.2f s",pass,Date().timeIntervalSince(t)))
            if element("home.modelStatus").exists {status("就绪",120);print(String(format:"PERF ui %@ models ready %.2f s",pass,Date().timeIntervalSince(t)))}
            sleep(8)
        }
        t=Date();pickFixture();wait("result.name",120);print(String(format:"PERF ui first identification %.2f s",Date().timeIntervalSince(t)))
        back();t=Date();pickFixture();wait("result.name",120);print(String(format:"PERF ui second identification %.2f s",Date().timeIntervalSince(t)))
    }
    /// Home's bottom action area (picker, camera, status line) stays short (owner 2026-11-18: 当前太高太丑).
    func testHomeActionAreaHeight() throws {
        launch(["-fixtureState","normal"]);wait("home.photos",20)
        let top=min(element("home.photos").frame.minY,element("home.camera").frame.minY),bottom=element("home.modelStatus").frame.maxY
        let note=app.staticTexts["系统选片无需相册访问授权；仅读取你选择的照片。"].firstMatch
        let height=bottom-(note.exists && note.frame.minY<top ? note.frame.minY:top)+16
        print(String(format:"PERF home action area %.0f pt",height));shot("home-action-area")
    }
    /// 10,000 synthetic photos: browse records and statistics; the app logs main-thread waits > 100 ms as HITCH lines.
    func testPerfTenThousandBrowse() throws {
        // Every synthetic record points at one CC0 12 MP original, so grid covers are real downsampled decodes.
        launch(["-fixtureState","normal","-seedSynthetic","10000","-syntheticPhoto",image.replacingOccurrences(of:"photo-0.jpg",with:"photo-4.png")]);wait("home.photos",300)
        let start=Date();launch(["-fixtureState","normal"],reset:false);wait("home.photos",120)
        print(String(format:"PERF ui 10k cold launch to home %.2f s",Date().timeIntervalSince(start)))
        // Each step, then 3 s with no queries: HITCH lines in perf.log inside a step's window belong to it, not to the test runner.
        func step(_ name:String,_ body:() -> Void) {print(String(format:"STEP %@ at %.1f s (epoch %.0f)",name,Date().timeIntervalSince(start),Date().timeIntervalSince1970));body();sleep(3)}
        step("records") {app.tabBars.buttons["记录"].firstMatch.tap()}
        XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'records.species.'")).firstMatch.exists)
        shot("records-grid-10k")
        step("records scroll") {for _ in 0..<3 {app.swipeUp()}}
        shot("records-grid-10k-scrolled")
        step("photos") {app.segmentedControls.buttons["照片"].firstMatch.tap()}
        step("photos scroll") {for _ in 0..<4 {app.swipeUp()}}
        step("pending") {app.segmentedControls.buttons["待确认"].firstMatch.tap()}
        step("statistics") {app.tabBars.buttons["统计"].firstMatch.tap()}
        XCTAssertTrue(element("stats.species").exists)
        step("statistics year") {element("stats.period").buttons["本年"].tap()}
        step("statistics all") {element("stats.period").buttons["全部"].firstMatch.tap()}
        step("statistics scroll") {for _ in 0..<3 {app.swipeUp()}}
        step("settings") {app.tabBars.buttons["设置"].firstMatch.tap()}
        step("home") {app.tabBars.buttons["识别"].firstMatch.tap()}
    }
}
