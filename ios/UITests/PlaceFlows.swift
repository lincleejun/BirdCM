import XCTest

/// Home place: map search and pin, offline regions and recents, device location (fixture and system prompt), photo GPS.
final class PlaceFlows: FlowCase {
    func testPlaceMapSearchPinAndRecents() throws {
        launch();try shot("home-empty")
        element("home.map").tap();outcome("place.mapCanvas")
        element("place.mapSearch").tap();element("place.mapSearch").typeText("Bolsa Chica");dismissTypingTip()
        element("place.mapFind").tap()
        // Search depends on Apple connectivity; offline region search is covered independently.
        XCTAssertTrue(element("place.mapResult.0").appears(timeout:30));element("place.mapResult.0").tap()
        element("place.mapCanvas").coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.45)).tap();try shot("map-pin-radius")
        element("place.usePin").tap();XCTAssertTrue(element("home.place").appears(timeout:5))
        element("home.place").tap();search("Alaska");try shot("alaska-search")
        let alaska=element("place.region.US-AK");XCTAssertTrue(alaska.appears(timeout:5));XCTAssertTrue(alaska.isHittable);alaska.tap();try shot("home-alaska")
        launch(reset:false);XCTAssertTrue(element("home.place").label.contains("阿拉斯加"))
    }
    func testDeviceLocationAllowAndDenyFallback() throws {
        for status in ["allowed","denied"] {
            launch(extra:["-locationFixture",status]);element("home.locate").tap()
            if status=="denied" {outcome("place.mapCanvas");try shot("denied-map");element("place.usePin").tap()}
            else {label(element("home.place"),contains:"Bolsa Chica");try shot("located")}
        }
    }
    func testSystemLocationPermission() throws {
        app.resetAuthorizationStatus(for:.location)
        for allow in [false,true] {
            app.resetAuthorizationStatus(for:.location)
            let monitor=addUIInterruptionMonitor(withDescription:"Location") {alert in alert.buttons.element(boundBy:allow ? 1:0).tap();return true}
            launch();element("home.locate").tap();app.tap()
            until("location prompt answered",25) {self.element("place.mapCanvas").exists || self.element("home.locate").isEnabled}
            try shot(allow ? "system-allow":"system-deny");removeUIInterruptionMonitor(monitor)
        }
    }
    func testGPSHomeAndNoPlace() throws {
        launch("photo-gps");pick();XCTAssertTrue(element("result.prior").exists);try shot("photo-gps")
        XCTAssertTrue(app.staticTexts["用了照片自带的位置"].firstMatch.exists)
        launch("home-place",extra:["-locationFixture","allowed"]);element("home.locate").tap()
        label(element("home.place"),contains:"Bolsa Chica")
        pick();try shot("home-place")
        launch("no-location");fixture();outcome("place.skip");try shot("missing-gps-sheet");element("place.skip").tap();outcome();try shot("without-place")
    }
    func testChangePlaceChangesAnswer() throws {
        launch("location-rerank");pick();XCTAssertEqual(element("result.name").label,"不确定")
        reveal("result.bottomPlace").tap();search("California")
        let ca=element("place.region.US-CA");XCTAssertTrue(ca.appears(timeout:5));XCTAssertTrue(ca.isHittable);ca.tap()
        XCTAssertTrue(app.staticTexts["红翅黑鹂"].firstMatch.appears(timeout:10));try shot("local-blackbird")
        back();app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch.tap()
        outcome();XCTAssertEqual(element("result.name").label,"红翅黑鹂")
    }
}
