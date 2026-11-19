import XCTest

/// The result page for every fixture state: pager, marks, candidates, rarity, manual box, background and save/share.
final class ResultFlows: FlowCase {
    func resultState(_ state:String) throws {
        launch(state);pick();try shot(state)
        if state=="multiple" {
            reveal("result.subject.1").tap()
            label(element("result.name"),contains:"褐鹈鹕",5)
            XCTAssertTrue(element("result.subject.1").isSelected)
            element("result.original").tap();try shot("multiple-original")
            let original=element("result.photo")
            original.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.45)).tap()
            XCTAssertTrue(element("result.crop.1").appears(timeout:5))
        }
        reveal("result.marks").tap();try shot(state+"-no-marks")
        // Candidates are collapsed for a settled answer and open for 不确定 (owner rule); capture both states.
        if state=="uncertain" {XCTAssertTrue(reveal("result.candidate.1").exists,"不确定 opens the candidates by default")}
        let toggle=reveal("result.candidates.toggle")
        if state=="normal" {XCTAssertTrue(element("result.candidates").exists);XCTAssertFalse(element("result.candidate.1").exists);XCTAssertTrue(toggle.label.contains("个候选"))}
        if element("result.candidate.1").exists {try shot(state+"-candidates-open");toggle.tap();try shot(state+"-candidates-collapsed");toggle.tap()}
        else {try shot(state+"-candidates-collapsed");toggle.tap();try shot(state+"-candidates-open")}
        XCTAssertEqual(element("result.candidate.1").exists,true)
        // Candidate details open and dismiss twice with a stable sheet state.
        for n in 0..<2 {reveal("result.candidate.1").tap();outcome("candidate.details");if n==0 {try shot(state+"-candidate")};element("candidate.done").tap()}
    }
    /// Also covers the old testResultNormalCandidatesCollapsed (collapsed by default, “n 个候选” on the toggle).
    func testResultNormal() throws {try resultState("normal")}
    func testResultSeveralBirds() throws {try resultState("multiple")}
    /// 不确定 opens the candidates by default (checked inside resultState, no second launch).
    func testResultUncertain() throws {try resultState("uncertain")}
    func testResultGenus() throws {try resultState("genus")}
    /// Geo-prior warning (model `rare`) and GBIF tier (bundled table, US-CA in November) are independent facts.
    func testResultRare() throws {
        try resultState("rare")
        XCTAssertTrue(reveal("result.priorWarning").exists)
        XCTAssertEqual(element("result.localRarity").value as? String,"不常见")
    }
    func testResultUnknownPrior() throws {try resultState("unknown-prior")}
}

/// The result page beyond the fixture states: GBIF tier without a prior warning, range warning, background, save/share, manual box.
final class ResultExtraFlows: FlowCase {
    func testResultGBIFRareWithoutPriorWarning() throws {
        launch("gbif-rare");pick();try shot("gbif-rare")
        XCTAssertEqual(element("result.localRarity").value as? String,"少见");XCTAssertFalse(element("result.priorWarning").exists)
    }
    func testResultUncertainWithRangeWarning() throws {
        launch("uncertain-geo");pick();try shot("uncertain-geo")
        XCTAssertTrue(reveal("result.priorWarning").exists);XCTAssertFalse(element("result.localRarity").exists)
    }
    func testCropBackgroundSaveAndShare() throws {
        // Revoking a privacy grant terminates a running app (TCC exit, seen in the full suite); reset before launching.
        app.resetAuthorizationStatus(for:.photos)
        launch();pick();outcome("result.crop.0")
        // The simulator does not run Vision foreground segmentation: an explicit unsupported state, rectangle still usable.
        element("result.background").tap();outcome("result.maskUnsupported")
        XCTAssertFalse(element("result.background").exists);XCTAssertTrue(element("result.save").exists)
        try shot("background-unsupported")
        element("result.save").tap()
        let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        XCTAssertTrue(spring.alerts.firstMatch.appears(timeout:5))
        spring.alerts.firstMatch.buttons.element(boundBy:spring.alerts.firstMatch.buttons.count-1).tap()
        label(element("result.save"),contains:"已保存")
        element("result.share").tap();XCTAssertTrue(app.otherElements["ActivityListView"].appears(timeout:5) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists || app.buttons["AirDrop"].exists);try shot("share")
    }
    func testBackgroundMaskFixtures() throws {
        launch(extra:["-maskFixture","success"]);pick();element("result.background").tap();outcome("result.maskFixture");try shot("mask-fixture-success")
        launch(extra:["-maskFixture","none"]);pick();element("result.background").tap();outcome("result.noMask");try shot("mask-none")
        element("result.maskRetry").tap();outcome("result.noMask");XCTAssertFalse(element("result.maskRetry").exists)
    }
    func testNoBirdManualBox() throws {
        launch("no-bird");fixture();outcome("result.draw");try shot("no-bird")
        reveal("result.draw").tap()
        for _ in 0..<4 {app.swipeDown()}
        let photo=element("result.photo")
        photo.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.2)).press(forDuration:0.1,thenDragTo:photo.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.7)))
        outcome();outcome("result.crop.0");XCTAssertTrue(element("result.original").exists);try shot("manual-box")
    }
}
