import XCTest

/// The bundled engine for real (no fixture state), the 10,000-photo library and the home-screen icon. CPU-heavy:
/// PERF lines printed while other simulators run in parallel are not comparable with a serial run.
final class EngineFlows: FlowCase {
    func realInference(_ number:Int,name:String) throws {
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory","YES","-fixtureImage",image.replacingOccurrences(of:"photo-0.jpg",with:"photo-\(number).jpg")];app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:45))
        // Readiness includes the bundled engine, not merely existence of the disabled picker.
        until("picker enabled",45) {self.element("home.photos").isEnabled}
        fixture();XCTAssertTrue(element("result.name").waitForExistence(timeout:45));XCTAssertEqual(element("result.name").label,name)
        try shot(number==0 ? "real-inference-eagle":"real-inference-egret")
    }
    func testRealInferenceEagle() throws {try realInference(0,name:"白头海雕")}
    func testRealInferenceEgret() throws {try realInference(3,name:"雪鹭")}
    func testCameraUnavailableAndInjectedCapture() throws {
        launch();element("home.camera").tap();outcome("camera.unavailable");try shot("camera-unavailable")
        XCTAssertTrue(element("home.photos").isEnabled)
        // Injected capture bytes go through the real receive path and the bundled engine (no fixture state).
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory","YES","-fixtureImage",image,"-cameraFixture","YES"];app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:45))
        until("picker enabled",45) {self.element("home.photos").isEnabled}
        element("home.camera").tap()
        // An in-app capture claims no GPS: without a home place it asks for one, exactly like a picked photo.
        outcome("place.skip");element("place.skip").tap()
        XCTAssertTrue(element("result.name").waitForExistence(timeout:45));XCTAssertEqual(element("result.name").label,"白头海雕");try shot("camera-fixture")
    }
    /// 10,000 synthetic photos / 30,000 subjects: cold relaunch to a usable records grid, statistics and search (simulator timings).
    func testTenThousandColdStart() throws {
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory","YES","-fixtureImage",image,"-fixtureState","normal","-seedSynthetic","10000"];app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:120))
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory","NO","-fixtureImage",image,"-fixtureState","normal"]
        var t=Date();app.launch();XCTAssertTrue(element("home.photos").waitForExistence(timeout:60));print(String(format:"PERF cold launch to 识别 %.2f s",Date().timeIntervalSince(t)))
        t=Date();tab("tab.records","记录");XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'records.species.'")).firstMatch.waitForExistence(timeout:30));print(String(format:"PERF records species grid %.2f s",Date().timeIntervalSince(t)))
        t=Date();segment("照片");outcome("history.sort");print(String(format:"PERF records photos %.2f s",Date().timeIntervalSince(t)))
        t=Date();tab("tab.stats","统计");outcome("stats.species");print(String(format:"PERF statistics %.2f s",Date().timeIntervalSince(t)))
        t=Date();tab("tab.explore","探索");segment("全部物种");search("hawk");XCTAssertTrue(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'explore.row.'")).firstMatch.waitForExistence(timeout:30));print(String(format:"PERF explore search %.2f s (includes typing)",Date().timeIntervalSince(t)))
        try shot("tenk-explore")
    }
    /// The installed app shows the K1 icon on the home screen.
    func testHomeScreenIcon() throws {
        launch();XCUIDevice.shared.press(.home)
        let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard");XCTAssertTrue(spring.wait(for:.runningForeground,timeout:5));try shot("springboard-first")
        let icon=spring.icons.matching(NSPredicate(format:"label CONTAINS '观羽' OR identifier CONTAINS '观羽'")).firstMatch
        for _ in 0..<6 where !(icon.waitForExistence(timeout:1) && icon.isHittable) {spring.swipeLeft()}
        XCTAssertTrue(icon.isHittable);try shot("springboard-icon")
    }
}
