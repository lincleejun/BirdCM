import XCTest

/// 物种参考 on the species page opened from 探索, with the network answered by the engine's recorded fixtures
/// (-referenceFixtures, Debug only: an unknown URL is an error, the image is drawn in the app).
final class ReferenceFlows: FlowCase {
    var fixtures: String { Bundle(for: FlowCase.self).resourceURL!.appendingPathComponent("Fixtures/online").path }
    func testSpeciesReferenceFromExplore() throws {
        launch(extra: ["-referenceOnline", "YES", "-referenceDisclosed", "NO", "-referenceFixtures", fixtures])
        tab("tab.explore", "探索"); segment("全部物种"); search("House Sparrow"); app.typeText("\n")
        outcome("explore.row.Passer domesticus"); element("explore.row.Passer domesticus").tap(); outcome("species.name")
        _ = reveal("reference.disclosed")
        XCTAssertTrue(element("reference.image").appears(timeout: 15), "the drawn rendition for the Commons fixture")
        XCTAssertTrue(element("reference.summary").appears(timeout: 15))
        try shot("species-reference-disclosure")
        reveal("reference.disclosed").tap()
        _ = reveal("reference.image")
        try shot("species-reference")
        for text in ["Diliff", "CC BY-SA 3.0", "Wikimedia Commons 文件页", "CC BY-SA 4.0", "原文「家麻雀」"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch.exists, text)
        }
        _ = reveal("reference.summaryCredit")
        try shot("species-reference-summary")
    }
}
