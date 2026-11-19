import XCTest

/// 记录 and settings: photo search/sort/delete/clear, correction and count, pending, migration, backup, about.
final class RecordFlows: FlowCase {
    func openPhotos() {back();tab("tab.records","记录");segment("照片");outcome("history.sort")}
    var firstRow:XCUIElement {app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch}
    /// The species card shown first (top row, leftmost): grid elements keep their creation order in the query, not the screen's.
    var firstSpecies:String {
        app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'records.species.'")).allElementsBoundByIndex
            .filter{$0.exists && $0.frame.height>0}.min{a,b in abs(a.frame.minY-b.frame.minY)<40 ? a.frame.minX<b.frame.minX:a.frame.minY<b.frame.minY}?.identifier ?? ""   // cards in one row differ in height
    }
    /// Owner 2026-11-18 (我最近识别了某只鸟，它就要排到第一位): the photo identified last is first in 照片 and 最近记录 and its
    /// species first in 鸟种; opening an older photo or correcting it does the same — all without relaunching.
    func testJustIdentifiedComesFirst() throws {
        launch("normal");pick();back()                                  // A: Bald Eagle
        launch("multiple",reset:false);pick();back()                    // B: Brown Pelican, identified later
        until("B first in 最近记录") {self.firstRow.label.contains("褐鹈鹕")};try shot("first-home-after-B")
        tab("tab.records","记录");segment("鸟种")
        until("B's species first") {self.firstSpecies == "records.species.Pelecanus occidentalis"};try shot("first-species-after-B")
        segment("照片");until("B first in 照片") {self.firstRow.label.contains("褐鹈鹕")}
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.' AND label CONTAINS '白头海雕'")).firstMatch.tap();outcome();back()
        until("opened A first in 照片") {self.firstRow.label.contains("白头海雕")};try shot("first-photo-after-opening-A")
        segment("鸟种");until("A's species first") {self.firstSpecies == "records.species.Haliaeetus leucocephalus"}
        // A correction counts as identifying now: B corrected to Elegant Tern puts the tern first.
        segment("照片");app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.' AND label CONTAINS '褐鹈鹕'")).firstMatch.tap();outcome()
        reveal("result.correctSpecies").tap();search("Elegant Tern");outcome("correction.row.Thalasseus elegans")
        element("correction.row.Thalasseus elegans").tap();outcome("correction.review");element("correction.save").tap();outcome("result.corrected");back()
        segment("鸟种");until("the corrected photo's species lead (tern and the second pelican tie: same photo)") {["records.species.Thalasseus elegans","records.species.Pelecanus occidentalis"].contains(self.firstSpecies)};XCTAssertTrue(element("records.species.Thalasseus elegans").exists);try shot("first-species-after-correction")
        tab("tab.identify","识别");until("corrected photo first in 最近记录") {!self.firstRow.label.contains("白头海雕")}
    }
    /// history.sort is reachable at 0, 1, 7 and 8 records and while filtered, under 记录, and actually reorders.
    func testHistorySearchSortDeleteClear() throws {
        launch();tab("tab.records","记录");segment("照片");outcome("history.search");outcome("history.sort");try shot("photos-empty")
        for n in [1,7] {launch(extra:["-historyFixtureCount","\(n)"]);pick();openPhotos();XCTAssertTrue(element("history.search").isHittable)}
        launch(extra:["-historyFixtureCount","8"]);pick();openPhotos()
        let before=rows;sortPhotos("鸟种名称")
        until("rows reorder",5) {self.rows != before}
        let after=rows;XCTAssertNotEqual(before,after);try shot("history-sorted")
        sortPhotos("最近查看")
        let search=element("history.search");search.tap();search.typeText("Bald");dismissTypingTip()
        XCTAssertTrue(element("history.sort").isHittable);try shot("history-search")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'history.item.'")).firstMatch.tap();outcome();back()
        search.tap();search.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:4))
        let doomed=rows[0];element(doomed).tap();outcome()
        reveal("result.delete").tap();element("result.confirmDelete").tap();XCTAssertTrue(element("history.sort").appears(timeout:5))
        XCTAssertTrue(app.buttons[doomed].waitForNonExistence(timeout:5))
        tab("tab.settings","设置");reveal("history.clear").tap();element("history.confirmClear").tap();tab("tab.records","记录")
        XCTAssertTrue(element("history.sort").appears(timeout:5));until("rows cleared",5) {self.rows.isEmpty};try shot("history-cleared")
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
        until("name 不确定",5) {self.element("result.name").label=="不确定"}
        reveal("result.correctSpecies").tap();element("correction.reset").tap()
        until("name 白头海雕",5) {self.element("result.name").label=="白头海雕"}
        reveal("result.count").tap();let field=element("count.field");field.tap();field.typeText(XCUIKeyboardKey.delete.rawValue+"3");element("count.save").tap()
        label(element("result.count"),contains:"数量 3",5)
        reveal("result.exclude").tap();outcome("result.excluded");try shot("excluded");element("result.exclude").tap()
    }
    func testPendingListOpensSubject() throws {
        launch("uncertain");pick();back();tab("tab.records","记录");segment("待确认")
        let item=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'pending.item.'")).firstMatch
        XCTAssertTrue(item.appears(timeout:5));try shot("pending");item.tap();outcome("result.correctSpecies")
    }
    func testMigrationFromOldStore() throws {
        launch(extra:["-legacyFixture","3"]);tab("tab.records","记录");outcome("records.species.Haliaeetus leucocephalus");try shot("migrated-species")
        segment("照片");XCTAssertEqual(rows.count,3)
        settings();element("settings.backup").tap();XCTAssertTrue(reveal("backup.issues").label.contains("1"));try shot("migration-recovery")
    }
    func testBackupExportPreviewMerge() throws {
        launch(extra:["-historyFixtureCount","3"]);pick();back()
        settings();try shot("settings");element("settings.backup").tap();try shot("backup")
        reveal("backup.selfTest").tap();let merge=element("backup.merge")
        for _ in 0..<20 where !(merge.appears(timeout:1) && merge.isHittable) {app.swipeUp()};try shot("backup-preview")
        merge.tap();let message=element("backup.message")
        for _ in 0..<12 where !message.appears(timeout:1) {app.swipeDown()}
        label(message,contains:"新增 0",20)
    }
    func testAboutLicencesAndDiagnostics() throws {
        launch();tab("tab.settings","设置");element("home.about").tap();try shot("about")
        reveal("about.licences").tap();try shot("licences");element("resource.back").tap()
        XCTAssertTrue(element("sheet.done").appears(timeout:5));element("sheet.done").tap()
        XCTAssertTrue(element("home.diagnostics").appears(timeout:5));element("home.diagnostics").tap();try shot("diagnostics")
        // 性能自测 (the simulator runs the CPU setting only) fills its table from the bundled CC0 photos.
        reveal("diagnostics.selfTest").tap();element("selfTest.start").tap()
        XCTAssertTrue(element("selfTest.table").appears(timeout:120));try shot("diagnostics-self-test")
        app.navigationBars.buttons.firstMatch.tap();element("sheet.done").tap()
    }
    /// history.sort is a menu: 最近查看 (default) / 拍摄日期 / 鸟种名称.
    func sortPhotos(_ label:String) {element("history.sort").tap();let b=app.buttons[label].firstMatch;XCTAssertTrue(b.waitForExistence(timeout:5));b.tap()}
    /// 最近查看 is the default: the photo opened last comes first in 照片 and in the home 最近记录.
    func testPhotosRecentlyViewedFirst() throws {
        launch(extra:["-historyFixtureCount","8"]);pick();openPhotos()
        let opened=try XCTUnwrap(rows.last);XCTAssertNotEqual(rows.first,opened)
        element(opened).tap();outcome();back()
        expectation(for:NSPredicate{_,_ in self.rows.first == opened},evaluatedWith:nil);waitForExpectations(timeout:5);try shot("photos-recently-viewed")
        tab("tab.identify","识别");expectation(for:NSPredicate{_,_ in self.rows.first == opened},evaluatedWith:nil);waitForExpectations(timeout:5);try shot("home-recently-viewed")
    }
}
