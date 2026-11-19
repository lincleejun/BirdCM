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
    /// Hittable is not enough: an element under the action/tab bar still reports hittable, so require its frame to clear them.
    func clear(_ e:XCUIElement,_ id:String) -> Bool {
        if ["result.photos","result.bottomPlace","result.delete","home.photos","home.camera"].contains(id) {return true}
        let bars=["result.photos","home.photos"].filter{$0 != id}.map{element($0)}+[app.tabBars.firstMatch]
        let limit=bars.filter{$0.exists && $0.isHittable && $0.frame.height>0}.map{$0.frame.minY}.min() ?? .infinity
        return e.frame.maxY <= limit+0.5 && e.frame.minY >= 0
    }
    func reveal(_ id:String)->XCUIElement {
        let e=element(id)
        for i in 0..<60 {
            if e.exists && e.isHittable && clear(e,id) {return e}
            // Short slow drags with a hold (no momentum overshoot); alternate start points so neither the bottom bar nor the pager swallows every attempt.
            let y=[0.62,0.45,0.7,0.35][i%4], x=i%8<4 ? 0.94:0.06, up = !(e.exists && e.frame.maxY < 90)
            // Every third try a fast system swipe: slow drags that start on a control inside a sheet may not scroll.
            // Only while the row is not built yet; once it exists, slow drags place it without overshooting.
            if i%3==2 && !e.exists {app.swipeUp();continue}
            app.coordinate(withNormalizedOffset:CGVector(dx:x,dy:up ? y:y-0.25)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:x,dy:up ? y-0.25:y)),withVelocity:.slow,thenHoldForDuration:0.1)
        }
        try? shot("unreachable-"+id);XCTFail("Missing or unreachable: \(id)");return e
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
        reveal("home.more").tap();XCTAssertTrue(element("settings.done").waitForExistence(timeout:5));reveal("home.diagnostics").tap()
        XCTAssertTrue(element("diagnostics.fixture").waitForExistence(timeout:5));element("diagnostics.fixture").tap()
    }
    func outcome(_ id:String="result.name",file:StaticString=#filePath,line:UInt=#line) {XCTAssertTrue(element(id).waitForExistence(timeout:10),"missing \(id)",file:file,line:line)}
    func tab(_ id:String,_ label:String) {
        let byID=app.buttons[id]
        if byID.exists && byID.isHittable {byID.tap()} else {app.tabBars.buttons[label].firstMatch.tap()}
    }
    func endSearch() {for label in ["取消","Cancel"] {let b=app.navigationBars.buttons[label].firstMatch;if b.exists && b.isHittable {b.tap();return}}}
    func segment(_ label:String) {app.segmentedControls.buttons[label].firstMatch.tap()}
    func search(_ text:String) {let f=app.searchFields.firstMatch;XCTAssertTrue(f.waitForExistence(timeout:5));f.tap();f.typeText(text);dismissTypingTip()}
    var rows:[String] {app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).allElementsBoundByIndex.filter{$0.isHittable}.map(\.identifier)}
    func pick(){fixture();outcome()}
    func back(){
        let buttons=app.navigationBars.buttons.allElementsBoundByIndex
        guard let button=buttons.first(where:{$0.isHittable && $0.identifier != "home.more" && $0.label != "结果操作"}) else {XCTFail("No visible back button");return}
        button.tap()
    }
    /// Step 4 surfaces in light, dark and largest type: photo calendar (month, day, year), map, observations with the
    /// group-count editor, eBird export, “这里这个月” and folder backup.
    func testStep4Screens() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("BirdCMBackupFixture").path
        try? FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
        for extra in [[String](),["-darkMode","YES"],["-largestType","YES"]] {
            let mode="-"+(extra.isEmpty ? "light":extra.joined())
            launch("photo-gps",extra:extra+["-historyFixtureCount","3","-locationFixture","allowed","-backupFolderFixture",folder])
            reveal("home.locate").tap()
            expectation(for:NSPredicate(format:"label CONTAINS %@","Bolsa Chica"),evaluatedWith:element("home.place"));waitForExpectations(timeout:10)
            pick();back()
            tab("tab.stats","统计");outcome("stats.species");try shot("stats"+mode)
            let day=app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'calendar.day.'")).firstMatch
            reveal("stats.calendar");try shot("calendar-month"+mode)
            XCTAssertTrue(day.waitForExistence(timeout:5));reveal(day.identifier).tap();outcome("obs.row.Haliaeetus leucocephalus.2026-11-14");try shot("calendar-day"+mode);back()
            element("stats.period").buttons["本年"].tap();reveal("calendar.month.11");try shot("calendar-year"+mode)
            element("calendar.month.11").tap();outcome("stats.range")
            reveal("stats.map").tap();_=reveal("map.noPlace");sleep(2);try shot("map"+mode);back()
            reveal("stats.observationList").tap();let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'obs.row.'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout:5));row.tap();let field=reveal("obs.count");try shot("observation-editor"+mode)
            field.tap();field.typeText(XCUIKeyboardKey.delete.rawValue+"5");reveal("obs.save").tap()
            expectation(for:NSPredicate(format:"label CONTAINS '估计 5'"),evaluatedWith:row);waitForExpectations(timeout:5);back()
            reveal("stats.ebird").tap();sleep(1);try shot("ebird"+mode);_=reveal("ebird.export")
            reveal("ebird.export").tap();XCTAssertTrue(reveal("ebird.message").exists);element("ebird.close").tap()
            tab("tab.explore","探索");outcome("explore.mode")
            let likely=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'explore.row.'")).firstMatch
            for _ in 0..<40 where !likely.exists {app.swipeUp();sleep(1)}
            XCTAssertTrue(likely.waitForExistence(timeout:30));try shot("explore-local"+mode)
            reveal("home.more").tap();reveal("settings.backup").tap()
            let now=element("backup.now");for _ in 0..<30 where !(now.exists && now.isHittable) {app.swipeUp()}
            now.tap();let ok=element("backup.folderOK")
            for _ in 0..<10 where !ok.exists {app.swipeDown();sleep(1)}
            XCTAssertTrue(ok.waitForExistence(timeout:20));try shot("backup-folder-ok"+mode)
        }
        launch(extra:["-backupFolderFixture","/nonexistent/birdcm"]);reveal("home.more").tap();reveal("settings.backup").tap();reveal("backup.now").tap()
        XCTAssertTrue(element("backup.folderError").waitForExistence(timeout:20));try shot("backup-folder-error")
        launch();reveal("home.more").tap();reveal("settings.backup").tap();reveal("backup.chooseFolder");try shot("backup-folder-off")
    }
    /// The last row of each scrolling root can be brought fully above the floating tab bar.
    func testLastRowsClearTabBar() throws {
        launch(extra:["-historyFixtureCount","8"]);pick();back()
        tab("tab.explore","探索");segment("全部物种")
        let more=element("explore.more");for _ in 0..<40 where !(more.exists && more.isHittable && clear(more,"explore.more")) {app.swipeUp()}
        XCTAssertTrue(more.isHittable && clear(more,"explore.more"));try shot("explore-last-row")
        tab("tab.records","记录");segment("照片");let rows=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout:5));for _ in 0..<6 {app.swipeUp()}
        let last=rows.allElementsBoundByIndex.last!;XCTAssertTrue(clear(last,last.identifier));try shot("photos-last-row")
        tab("tab.stats","统计");XCTAssertTrue(reveal("stats.row.Haliaeetus leucocephalus").exists);try shot("stats-last-row")
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
        launch();XCUIDevice.shared.press(.home);sleep(1);try shot("springboard-first")
        let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard"),icon=spring.icons.matching(NSPredicate(format:"label CONTAINS '观羽' OR identifier CONTAINS '观羽'")).firstMatch
        for _ in 0..<6 where !(icon.exists && icon.isHittable) {spring.swipeLeft();sleep(1)}
        XCTAssertTrue(icon.isHittable);try shot("springboard-icon")
    }
    func testAlaskaRowAtLargestType() throws {
        launch(extra:["-largestType","YES"]);reveal("home.place").tap();sleep(1);try shot("alaska-sheet-largest");search("Alaska")
        let row=element("place.region.US-AK");XCTAssertTrue(row.waitForExistence(timeout:5));XCTAssertTrue(row.isHittable);try shot("alaska-largest");row.tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","阿拉斯加"),evaluatedWith:element("home.place"));waitForExpectations(timeout:5)
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
        element("home.place").tap();search("Alaska");try shot("alaska-search")
        let alaska=element("place.region.US-AK");XCTAssertTrue(alaska.waitForExistence(timeout:5));XCTAssertTrue(alaska.isHittable);alaska.tap();try shot("home-alaska")
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
        reveal("result.bottomPlace").tap();search("California")
        let ca=element("place.region.US-CA");XCTAssertTrue(ca.waitForExistence(timeout:5));XCTAssertTrue(ca.isHittable);ca.tap()
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
        // Candidates are collapsed for a settled answer and open for 不确定 (owner rule); capture both states.
        let toggle=reveal("result.candidates.toggle")
        if element("result.candidate.1").exists {try shot(state+"-candidates-open");toggle.tap();try shot(state+"-candidates-collapsed");toggle.tap()}
        else {try shot(state+"-candidates-collapsed");toggle.tap();try shot(state+"-candidates-open")}
        XCTAssertEqual(element("result.candidate.1").exists,true)
        // Candidate details open and dismiss twice with a stable sheet state.
        for n in 0..<2 {reveal("result.candidate.1").tap();outcome("candidate.details");if n==0 {try shot(state+"-candidate")};element("candidate.done").tap()}
    }
    func testResultNormal() throws {try resultState("normal")}
    func testResultSeveralBirds() throws {try resultState("multiple")}
    func testResultUncertain() throws {
        launch("uncertain");pick();XCTAssertTrue(reveal("result.candidate.1").exists,"不确定 opens the candidates by default")
        try resultState("uncertain")
    }
    func testResultNormalCandidatesCollapsed() throws {
        launch();pick();_=reveal("result.candidates.toggle");XCTAssertTrue(element("result.candidates").exists);XCTAssertFalse(element("result.candidate.1").exists);XCTAssertTrue(element("result.candidates.toggle").label.contains("个候选"))
    }
    func testResultGenus() throws {try resultState("genus")}
    /// Geo-prior warning (model `rare`) and GBIF tier (bundled table, US-CA in November) are independent facts.
    func testResultRare() throws {
        try resultState("rare")
        XCTAssertTrue(reveal("result.priorWarning").exists)
        XCTAssertEqual(element("result.localRarity").value as? String,"不常见")
    }
    func testResultGBIFRareWithoutPriorWarning() throws {
        launch("gbif-rare");pick();try shot("gbif-rare")
        XCTAssertEqual(element("result.localRarity").value as? String,"少见");XCTAssertFalse(element("result.priorWarning").exists)
    }
    func testResultUncertainWithRangeWarning() throws {
        launch("uncertain-geo");pick();try shot("uncertain-geo")
        XCTAssertTrue(reveal("result.priorWarning").exists);XCTAssertFalse(element("result.localRarity").exists)
    }
    /// The last sentence scrolls fully above both the action bar and the tab bar.
    func testResultFooterAboveBars() throws {
        for extra in [[String](),["-largestType","YES"]] {
            launch(extra:extra);pick()
            let footer=element("result.footer"),page=element("result.scroll")
            for _ in 0..<30 where !(footer.isHittable && clear(footer,"result.footer")) {page.swipeUp(velocity:.slow)}
            XCTAssertTrue(footer.isHittable)
            let bar=element("result.photos").frame
            XCTAssertLessThanOrEqual(footer.frame.maxY,bar.minY+1);try shot("footer"+extra.joined())
        }
    }
    func testResultUnknownPrior() throws {try resultState("unknown-prior")}
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
        XCTAssertTrue(spring.alerts.firstMatch.waitForExistence(timeout:5))
        spring.alerts.firstMatch.buttons.element(boundBy:spring.alerts.firstMatch.buttons.count-1).tap()
        expectation(for:NSPredicate(format:"label CONTAINS %@","已保存"),evaluatedWith:element("result.save"));waitForExpectations(timeout:10)
        element("result.share").tap();XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout:5) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists || app.buttons["AirDrop"].exists);try shot("share")
    }
    func testBackgroundMaskFixtures() throws {
        launch(extra:["-maskFixture","success"]);pick();element("result.background").tap();outcome("result.maskFixture");try shot("mask-fixture-success")
        launch(extra:["-maskFixture","none"]);pick();element("result.background").tap();outcome("result.noMask");try shot("mask-none")
        element("result.maskRetry").tap();outcome("result.noMask");XCTAssertFalse(element("result.maskRetry").exists)
    }
    func testCameraUnavailableAndInjectedCapture() throws {
        launch();element("home.camera").tap();outcome("camera.unavailable");try shot("camera-unavailable")
        XCTAssertTrue(element("home.photos").isEnabled)
        // Injected capture bytes go through the real receive path and the bundled engine (no fixture state).
        app.terminate();app.launchArguments=["-uiTesting","YES","-resetHistory","YES","-fixtureImage",image,"-cameraFixture","YES"];app.launch()
        XCTAssertTrue(element("home.photos").waitForExistence(timeout:45))
        expectation(for:NSPredicate(format:"enabled == YES"),evaluatedWith:element("home.photos"));waitForExpectations(timeout:45)
        element("home.camera").tap()
        // An in-app capture claims no GPS: without a home place it asks for one, exactly like a picked photo.
        outcome("place.skip");element("place.skip").tap()
        XCTAssertTrue(element("result.name").waitForExistence(timeout:45));XCTAssertEqual(element("result.name").label,"白头海雕");try shot("camera-fixture")
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
    func openPhotos() {back();tab("tab.records","记录");segment("照片");outcome("history.sort")}
    /// history.sort is reachable at 0, 1, 7 and 8 records and while filtered, under 记录, and actually reorders.
    func testHistorySearchSortDeleteClear() throws {
        launch();tab("tab.records","记录");segment("照片");outcome("history.search");outcome("history.sort");try shot("photos-empty")
        for n in [1,7] {launch(extra:["-historyFixtureCount","\(n)"]);pick();openPhotos();XCTAssertTrue(element("history.search").isHittable)}
        launch(extra:["-historyFixtureCount","8"]);pick();openPhotos()
        let before=rows;element("history.sort").tap()
        expectation(for:NSPredicate{_,_ in self.rows != before},evaluatedWith:nil);waitForExpectations(timeout:5)
        let after=rows;XCTAssertNotEqual(before,after);try shot("history-sorted")
        element("history.sort").tap()
        let search=element("history.search");search.tap();search.typeText("Bald");dismissTypingTip()
        XCTAssertTrue(element("history.sort").isHittable);try shot("history-search")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch.tap();outcome();back()
        search.tap();search.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:4))
        let doomed=rows[0];element(doomed).tap();outcome()
        reveal("result.delete").tap();element("result.confirmDelete").tap();XCTAssertTrue(element("history.sort").waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons[doomed].exists)
        element("home.more").tap();element("history.clear").tap();element("history.confirmClear").tap();element("settings.done").tap()
        XCTAssertTrue(element("history.sort").waitForExistence(timeout:5));XCTAssertEqual(rows.count,0);try shot("history-cleared")
    }
    /// Correction: Royal and Elegant Tern independently searchable; save, uncertain, reset; count edit.
    func testCorrectSpeciesCountAndReset() throws {
        launch();pick()
        reveal("result.correctSpecies").tap();outcome("correction.uncertain");try shot("correction-sheet")
        element("correction.cancel").tap();XCTAssertEqual(element("result.name").label,"白头海雕")
        reveal("result.correctSpecies").tap();search("Elegant Tern");outcome("correction.row.Thalasseus elegans")
        app.searchFields.firstMatch.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:12)+"Royal Tern")
        element("correction.row.Thalasseus maximus").tap()
        outcome("correction.review");try shot("correction-review");element("correction.save").tap()
        outcome("result.corrected");XCTAssertNotEqual(element("result.name").label,"白头海雕");try shot("corrected")
        reveal("result.correctSpecies").tap();element("correction.uncertain").tap()
        expectation(for:NSPredicate(format:"label == '不确定'"),evaluatedWith:element("result.name"));waitForExpectations(timeout:5)
        reveal("result.correctSpecies").tap();element("correction.reset").tap()
        expectation(for:NSPredicate(format:"label == '白头海雕'"),evaluatedWith:element("result.name"));waitForExpectations(timeout:5)
        reveal("result.count").tap();let field=element("count.field");field.tap();field.typeText(XCUIKeyboardKey.delete.rawValue+"3");element("count.save").tap()
        expectation(for:NSPredicate(format:"label CONTAINS '数量 3'"),evaluatedWith:element("result.count"));waitForExpectations(timeout:5)
        reveal("result.exclude").tap();outcome("result.excluded");try shot("excluded");element("result.exclude").tap()
    }
    func testPendingListOpensSubject() throws {
        launch("uncertain");pick();back();tab("tab.records","记录");segment("待确认")
        let item=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'pending.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout:5));try shot("pending");item.tap();outcome("result.correctSpecies")
    }
    func testMigrationFromOldStore() throws {
        launch(extra:["-legacyFixture","3"]);tab("tab.records","记录");outcome("records.species.Haliaeetus leucocephalus");try shot("migrated-species")
        segment("照片");XCTAssertEqual(rows.count,3)
        element("home.more").tap();element("settings.backup").tap();XCTAssertTrue(reveal("backup.issues").label.contains("1"));try shot("migration-recovery")
    }
    func testBackupExportPreviewMerge() throws {
        launch(extra:["-historyFixtureCount","3"]);pick();back()
        element("home.more").tap();try shot("settings");element("settings.backup").tap();try shot("backup")
        reveal("backup.selfTest").tap();let merge=element("backup.merge")
        for _ in 0..<20 where !(merge.exists && merge.isHittable) {app.swipeUp()};try shot("backup-preview")
        merge.tap();let message=element("backup.message")
        for _ in 0..<12 where !message.exists {app.swipeDown();sleep(1)}
        expectation(for:NSPredicate(format:"label CONTAINS '新增 0'"),evaluatedWith:message);waitForExpectations(timeout:20)
    }
    /// Every tab root, species page, pending list, correction sheet and settings.
    func tour(_ mode:String) throws {
        try shot("identify"+mode)
        tab("tab.records","记录");outcome("records.species.Haliaeetus leucocephalus");try shot("records-species"+mode)
        element("records.species.Haliaeetus leucocephalus").tap();outcome("species.name");try shot("species-page"+mode);back()
        segment("照片");outcome("history.sort");try shot("records-photos"+mode)
        segment("待确认");try shot("records-pending"+mode);segment("鸟种")
        tab("tab.stats","统计");outcome("stats.species");try shot("stats"+mode)
        element("home.more").tap();outcome("settings.backup");try shot("settings"+mode);element("settings.backup").tap();try shot("backup"+mode)
        app.navigationBars.buttons.element(boundBy:0).tap();element("settings.done").tap()
        tab("tab.explore","探索");outcome("explore.filter");try shot("explore"+mode)
        search("tern");try shot("explore-search"+mode)
    }
    func testAboutLicencesAndDiagnostics() throws {
        launch();element("home.more").tap();element("home.about").tap();try shot("about")
        reveal("about.licences").tap();try shot("licences");element("resource.back").tap()
        XCTAssertTrue(element("sheet.done").waitForExistence(timeout:5));element("sheet.done").tap()
        XCTAssertTrue(element("home.diagnostics").waitForExistence(timeout:5));element("home.diagnostics").tap();try shot("diagnostics");element("sheet.done").tap()
        element("settings.done").tap()
    }
    func testDarkLargestAndLoading() throws {
        for extra in [[],["-darkMode","YES"],["-largestType","YES"],["-darkMode","YES","-largestType","YES"]] {
            let mode="-"+(extra.isEmpty ? "light":extra.joined())
            launch(extra:extra);pick();try shot("result"+mode)
            reveal("result.correctSpecies").tap();outcome("correction.uncertain");try shot("correction"+mode);element("correction.cancel").tap()
            reveal("result.bottomPlace").tap();try shot("place"+mode);element("sheet.done").tap()
            back();try tour(mode)
        }
        launch("loading");fixture();outcome("identifying");try shot("loading-preview")
    }
}
