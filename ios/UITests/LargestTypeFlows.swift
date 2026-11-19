import XCTest

/// The running app at the largest text size: every screen of the old appearance matrix is reached, scrolled to and
/// used for real here. Light, dark and dark + largest pixels of the same screens come from the in-process renders
/// (BirdCMTests/AppearanceSnapshots), so the app is not relaunched per appearance.
final class LargestTypeFlows: FlowCase {
    let mode="--largestTypeYES"
    /// Step 4: photo calendar (month, day, year), map, observations with the group-count editor, eBird export,
    /// “这里这个月” and folder backup.
    func testStep4Screens() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("BirdCMBackupFixture").path
        try? FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
        launch("photo-gps",extra:["-largestType","YES","-historyFixtureCount","3","-locationFixture","allowed","-backupFolderFixture",folder])
        reveal("home.locate").tap()
        label(element("home.place"),contains:"Bolsa Chica")
        pick();back()
        tab("tab.stats","统计");outcome("stats.species");try shot("stats"+mode)
        let day=app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'calendar.day.'")).firstMatch
        _=reveal("stats.calendar");try shot("calendar-month"+mode)
        XCTAssertTrue(day.appears(timeout:5));reveal(day.identifier).tap();outcome("obs.row.Haliaeetus leucocephalus.2026-11-14");try shot("calendar-day"+mode);back()
        element("stats.period").buttons["本年"].tap();_=reveal("calendar.month.11");try shot("calendar-year"+mode)
        element("calendar.month.11").tap();outcome("stats.range")
        // Map tiles have no accessibility signal; a short settle for the picture.
        reveal("stats.map").tap();_=reveal("map.noPlace");sleep(1);try shot("map"+mode);back()
        reveal("stats.observationList").tap();let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'obs.row.'")).firstMatch
        XCTAssertTrue(row.appears(timeout:5));row.tap();let field=reveal("obs.count");try shot("observation-editor"+mode)
        field.tap();field.typeText(XCUIKeyboardKey.delete.rawValue+"5");reveal("obs.save").tap()
        label(row,contains:"估计 5",5);back()
        reveal("stats.ebird").tap();_=reveal("ebird.export");try shot("ebird"+mode)
        reveal("ebird.export").tap();XCTAssertTrue(reveal("ebird.message").exists);element("ebird.close").tap()
        tab("tab.explore","探索");outcome("explore.mode")
        let likely=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'explore.row.'")).firstMatch
        for _ in 0..<40 where !likely.appears(timeout:1) {app.swipeUp()}
        XCTAssertTrue(likely.appears(timeout:30));try shot("explore-local"+mode)
        reveal("home.more").tap();reveal("settings.backup").tap()
        let now=element("backup.now");for _ in 0..<30 where !(now.exists && now.isHittable) {app.swipeUp()}
        now.tap();let ok=element("backup.folderOK")
        for _ in 0..<10 where !ok.appears(timeout:1) {app.swipeDown()}
        XCTAssertTrue(ok.appears(timeout:20));try shot("backup-folder-ok"+mode)
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
    func testDarkLargestAndLoading() throws {
        launch(extra:["-largestType","YES"]);pick();try shot("result"+mode)
        reveal("result.correctSpecies").tap();outcome("correction.uncertain");try shot("correction"+mode);element("correction.cancel").tap()
        reveal("result.bottomPlace").tap();try shot("place"+mode);element("sheet.done").tap()
        back();try tour(mode)
    }
}

/// Bars never cover content: the last rows of the scrolling roots and the result footer, the Alaska row at the largest type.
final class LayoutFlows: FlowCase {
    /// The last sentence scrolls fully above both the action bar and the tab bar.
    func testResultFooterAboveBars() throws {
        for extra in [[String](),["-largestType","YES"]] {
            launch(extra:extra);pick()
            // reveal() fails unless the footer ends up hittable and fully above the action and tab bars.
            let footer=reveal("result.footer")
            XCTAssertTrue(footer.isHittable)
            let bar=element("result.photos").frame
            XCTAssertLessThanOrEqual(footer.frame.maxY,bar.minY+1);try shot("footer"+extra.joined())
        }
    }
    /// The last row of each scrolling root can be brought fully above the floating tab bar.
    func testLastRowsClearTabBar() throws {
        launch(extra:["-historyFixtureCount","8"]);pick();back()
        tab("tab.explore","探索");segment("全部物种")
        let more=element("explore.more");for _ in 0..<40 where !(more.exists && more.isHittable && clear(more,"explore.more")) {app.swipeUp()}
        XCTAssertTrue(more.isHittable && clear(more,"explore.more"));try shot("explore-last-row")
        tab("tab.records","记录");segment("照片");let rows=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'"))
        XCTAssertTrue(rows.firstMatch.appears(timeout:5));for _ in 0..<6 {app.swipeUp()}
        let last=rows.allElementsBoundByIndex.last!;XCTAssertTrue(clear(last,last.identifier));try shot("photos-last-row")
        tab("tab.stats","统计");XCTAssertTrue(reveal("stats.row.Haliaeetus leucocephalus").exists);try shot("stats-last-row")
    }
    func testAlaskaRowAtLargestType() throws {
        launch(extra:["-largestType","YES"]);reveal("home.place").tap();XCTAssertTrue(app.searchFields.firstMatch.appears(timeout:5));try shot("alaska-sheet-largest");search("Alaska")
        let row=element("place.region.US-AK");XCTAssertTrue(row.appears(timeout:5));XCTAssertTrue(row.isHittable);try shot("alaska-largest");row.tap()
        label(element("home.place"),contains:"阿拉斯加",5)
    }
}
