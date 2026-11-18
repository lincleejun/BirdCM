import XCTest

/// UI fixtures exercise presentation; real inference and cached re-ranking have separate engine checks.
final class Flows:XCTestCase {
    let app=XCUIApplication()
    var env:[String:String] {ProcessInfo.processInfo.environment}
    var image:String {Bundle(for:Flows.self).resourceURL!.appendingPathComponent("Fixtures/photo-0.jpg").path}
    override func setUp(){continueAfterFailure=false}
    func element(_ id:String)->XCUIElement {
        let matches=app.descendants(matching:.any).matching(identifier:id)
        return matches.allElementsBoundByIndex.first(where:{$0.isHittable}) ?? matches.firstMatch
    }
    func dismissTypingTip() {
        let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        for root in [app,spring] {
            for label in ["Continue","继续","Not Now","以后","好"] {
                let button=root.buttons[label]
                if button.exists && button.isHittable {button.tap();return}
            }
        }
    }
    func launch(_ state:String="normal",extra:[String]=[],reset:Bool=true) {
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory",reset ? "YES":"NO","-fixtureImage",state=="multiple" ? image.replacingOccurrences(of:"photo-0.jpg",with:"photo-1.jpg"):image,"-fixtureState",state]+extra;app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:20))
    }
    func reveal(_ id:String)->XCUIElement {
        let e=element(id)
        for _ in 0..<6 {
            if e.exists && e.isHittable {return e}
            app.coordinate(withNormalizedOffset:CGVector(dx:0.94,dy:0.72)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.94,dy:0.25)))
        }
        XCTFail("Missing or unreachable: \(id)");return e
    }
    func shot(_ name:String) throws {
        dismissTypingTip()
        let s=XCUIScreen.main.screenshot(),a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)
        if let folder=env["SCREENSHOT_DIR"] {
            let dir=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try s.pngRepresentation.write(to:dir.appendingPathComponent(self.name.replacingOccurrences(of:"/",with:"-")+"-"+name+".png"))
        }
    }
    func fixture() {
        reveal("home.more").tap();XCTAssertTrue(element("home.diagnostics").waitForExistence(timeout:5));element("home.diagnostics").tap()
        XCTAssertTrue(element("diagnostics.fixture").waitForExistence(timeout:5));element("diagnostics.fixture").tap()
    }
    func outcome(_ id:String="result.name") {XCTAssertTrue(element(id).waitForExistence(timeout:10))}
    func pick(){fixture();outcome()}
    func back(){
        let buttons=app.navigationBars.buttons.allElementsBoundByIndex
        guard let button=buttons.first(where:{$0.isHittable && $0.identifier != "home.more" && $0.label != "结果操作"}) else {XCTFail("No visible back button");return}
        button.tap()
    }
    func testPlaceMapSearchPinAndRecents() throws {
        launch();try shot("home-empty")
        element("home.map").tap();outcome("place.mapCanvas")
        element("place.mapSearch").tap();element("place.mapSearch").typeText("Bolsa Chica");dismissTypingTip()
        element("place.mapFind").tap()
        // Search depends on Apple connectivity; offline region search is covered independently.
        XCTAssertTrue(element("place.mapResult.0").waitForExistence(timeout:30));element("place.mapResult.0").tap()
        element("place.mapCanvas").coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.45)).tap();try shot("map-pin-radius")
        element("place.usePin").tap();XCTAssertTrue(element("home.place").waitForExistence(timeout:5))
        element("home.place").tap();reveal("place.search").tap();element("place.search").typeText("Alaska");dismissTypingTip()
        reveal("place.region.US-AK").tap();try shot("home-alaska")
        launch(reset:false);XCTAssertTrue(element("home.place").label.contains("阿拉斯加"))
    }
    func testDeviceLocationAllowAndDenyFallback() throws {
        for status in ["allowed","denied"] {
            launch(extra:["-locationFixture",status]);element("home.locate").tap()
            if status=="denied" {outcome("place.mapCanvas");try shot("denied-map");element("place.usePin").tap()}
            else {
                expectation(for:NSPredicate(format:"label CONTAINS %@","Bolsa Chica"),evaluatedWith:element("home.place"));waitForExpectations(timeout:10)
                try shot("located")
            }
        }
    }
    func testSystemLocationPermission() throws {
        app.resetAuthorizationStatus(for:.location)
        for allow in [false,true] {
            app.resetAuthorizationStatus(for:.location)
            let monitor=addUIInterruptionMonitor(withDescription:"Location") {alert in alert.buttons.element(boundBy:allow ? 1:0).tap();return true}
            launch();element("home.locate").tap();app.tap()
            let finished=NSPredicate {_,_ in self.element("place.mapCanvas").exists || self.element("home.locate").isEnabled}
            expectation(for:finished,evaluatedWith:nil);waitForExpectations(timeout:25)
            try shot(allow ? "system-allow":"system-deny");removeUIInterruptionMonitor(monitor)
        }
    }
    func testGPSHomeAndNoPlace() throws {
        launch("photo-gps");pick();XCTAssertTrue(element("result.prior").exists);try shot("photo-gps")
        XCTAssertTrue(app.staticTexts["用了照片自带的位置"].firstMatch.exists)
        launch("home-place",extra:["-locationFixture","allowed"]);element("home.locate").tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","Bolsa Chica"),evaluatedWith:element("home.place"));waitForExpectations(timeout:10)
        pick();try shot("home-place")
        launch("no-location");fixture();outcome("place.skip");try shot("missing-gps-sheet");element("place.skip").tap();outcome();try shot("without-place")
    }
    func testChangePlaceChangesAnswer() throws {
        launch("location-rerank");pick();XCTAssertEqual(element("result.name").label,"不确定")
        reveal("result.bottomPlace").tap();reveal("place.search").tap();element("place.search").typeText("California");dismissTypingTip()
        reveal("place.region.US-CA").tap()
        XCTAssertTrue(app.staticTexts["红翅黑鹂"].firstMatch.waitForExistence(timeout:10));try shot("local-blackbird")
        back();app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch.tap()
        outcome();XCTAssertEqual(element("result.name").label,"红翅黑鹂")
    }
    func resultState(_ state:String) throws {
        launch(state);pick();try shot(state)
        if state=="multiple" {
            reveal("result.subject.1").tap()
            expectation(for:NSPredicate(format:"label CONTAINS %@","褐鹈鹕"),evaluatedWith:element("result.name"));waitForExpectations(timeout:5)
            XCTAssertTrue(element("result.subject.1").isSelected)
            element("result.original").tap();try shot("multiple-original")
            let original=element("result.photo")
            original.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.45)).tap()
            XCTAssertTrue(element("result.crop.1").waitForExistence(timeout:5))
        }
        reveal("result.marks").tap();try shot(state+"-no-marks")
        reveal("result.candidate.1").tap();outcome("candidate.details");try shot(state+"-candidate");element("candidate.done").tap()
    }
    func testResultNormal() throws {try resultState("normal")}
    func testResultSeveralBirds() throws {try resultState("multiple")}
    func testResultUncertain() throws {try resultState("uncertain")}
    func testResultGenus() throws {try resultState("genus")}
    func testResultRare() throws {try resultState("rare")}
    func testResultUnknownPrior() throws {try resultState("unknown-prior")}
    func testCropBackgroundSaveAndShare() throws {
        launch();pick();outcome("result.crop.0")
        element("result.background").tap()
        let done=NSPredicate{_,_ in self.element("result.noMask").exists || self.element("result.background").isEnabled}
        expectation(for:done,evaluatedWith:nil);waitForExpectations(timeout:15)
        if element("result.noMask").exists {XCTAssertFalse(element("result.background").exists)}
        try shot("background-outcome")
        app.resetAuthorizationStatus(for:.photos)
        element("result.save").tap()
        let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        XCTAssertTrue(spring.alerts.firstMatch.waitForExistence(timeout:5))
        spring.alerts.firstMatch.buttons.element(boundBy:spring.alerts.firstMatch.buttons.count-1).tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","已保存"),evaluatedWith:element("result.save"));waitForExpectations(timeout:10)
        element("result.share").tap();XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout:5) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists || app.buttons["AirDrop"].exists);try shot("share")
    }
    func realInference(_ number:Int,name:String) throws {
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory","YES","-fixtureImage",image.replacingOccurrences(of:"photo-0.jpg",with:"photo-\(number).jpg")];app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:45))
        // Readiness includes the bundled engine, not merely existence of the disabled picker.
        expectation(for:NSPredicate(format:"enabled == YES"),evaluatedWith:element("home.photos"));waitForExpectations(timeout:5)
        fixture();XCTAssertTrue(element("result.name").waitForExistence(timeout:45));XCTAssertEqual(element("result.name").label,name)
        try shot(number==0 ? "real-inference-eagle":"real-inference-egret")
    }
    func testRealInferenceEagle() throws {try realInference(0,name:"白头海雕")}
    func testRealInferenceEgret() throws {try realInference(3,name:"雪鹭")}
    func testNoBirdManualBox() throws {
        launch("no-bird");fixture();outcome("result.draw");try shot("no-bird")
        reveal("result.draw").tap()
        for _ in 0..<4 {app.swipeDown()}
        let photo=element("result.photo")
        photo.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.2)).press(forDuration:0.1,thenDragTo:photo.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.7)))
        outcome();outcome("result.crop.0");XCTAssertTrue(element("result.original").exists);try shot("manual-box")
    }
    func testHistorySearchSortDeleteClear() throws {
        launch(extra:["-historyFixtureCount","8"]);pick();back()
        let search=reveal("history.search");search.tap();search.typeText("Bald");dismissTypingTip();try shot("history-search")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch.tap();outcome();back()
        search.tap();search.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:4));app.swipeDown()
        reveal("history.sort").tap();try shot("history-sorted")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch.tap();outcome();element("result.delete").tap()
        element("home.more").tap();element("history.clear").tap();element("history.confirmClear").tap();try shot("history-cleared")
    }
    func testAboutLicencesAndDiagnostics() throws {
        launch();element("home.more").tap();element("home.about").tap();try shot("about")
        reveal("about.licences").tap();try shot("licences");element("resource.back").tap()
        XCTAssertTrue(element("sheet.done").waitForExistence(timeout:5));element("sheet.done").tap()
        reveal("home.more").tap();XCTAssertTrue(element("home.diagnostics").waitForExistence(timeout:5));element("home.diagnostics").tap();try shot("diagnostics");element("sheet.done").tap()
    }
    func testDarkLargestAndLoading() throws {
        for extra in [["-darkMode","YES"],["-largestType","YES"],["-darkMode","YES","-largestType","YES"]] {
            launch(extra:extra);try shot("home-"+extra.joined());pick();try shot("result-"+extra.joined())
            reveal("result.bottomPlace").tap();try shot("place-"+extra.joined())
        }
        launch("loading");fixture();outcome("identifying");try shot("loading-preview")
    }
}
