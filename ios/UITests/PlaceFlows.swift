import XCTest

/// Home place: map search and pin, offline regions and recents, device location (fixture and system prompt), photo GPS.
final class PlaceFlows: FlowCase {
    /// Points read as English place names (owner 2026-11-18), coordinates only as a caption: home place control, result
    /// place block, 记录 → 照片 rows; light and dark, with Apple's names (network) — offline region names otherwise.
    func testPlaceNamesInsteadOfCoordinates() throws {
        for extra in [[String](),["-darkMode","YES"]] {
            let mode=extra.isEmpty ? "-light":"-dark"
            launch("photo-gps",extra:extra+["-placeNamesOnline","YES","-historyFixtureCount","3"])
            element("home.map").tap();outcome("place.mapCanvas");element("place.usePin").tap()
            until("home place named",15) {let l=self.element("home.place").label;return !l.isEmpty && !l.contains("地图选点") && l.range(of:#"\d+\.\d+, -?\d+\.\d+"#,options:.regularExpression) == nil}
            sleep(2);try shot("place-name-home"+mode)
            pick();_=reveal("place.coordinates");sleep(3)
            XCTAssertNil(element("place.snapshot").label.range(of:#"\d+\.\d+, -?\d+\.\d+"#,options:.regularExpression),"map label is a name");try shot("place-name-result"+mode)
            back();tab("tab.records","记录");segment("照片");outcome("history.sort");sleep(3);try shot("place-name-photos"+mode)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:"label MATCHES %@",#"-?\d+\.\d+, -?\d+\.\d+"#)).firstMatch.exists,"no bare coordinates in the rows")
        }
    }
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
    /// Photo GPS shows as a map snapshot with the place under it (owner 2026-11-18), opens a full map; offline keeps the text.
    func testResultPlaceMap() throws {
        for extra in [[String](),["-darkMode","YES"]] {
            launch("photo-gps",extra:extra);pick();_=reveal("place.coordinates");outcome("place.snapshot");sleep(3)
            try shot("result-place-map"+(extra.isEmpty ? "":"-dark"))
            reveal("place.snapshot").tap();outcome("place.fullMap");sleep(2);try shot("result-place-fullmap"+(extra.isEmpty ? "":"-dark"));element("sheet.done").tap()
        }
        launch("photo-gps",extra:["-mapOffline","YES"]);pick();_=reveal("place.coordinates")
        XCTAssertFalse(element("place.snapshot").exists);try shot("result-place-offline")
    }
}
