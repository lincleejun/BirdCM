import XCTest
import SwiftUI
@testable import BirdCM

/// The appearance matrix, rendered in the test host from the preview fixtures instead of relaunching the app per
/// appearance: light, dark and dark + largest type. PNGs go to SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR) under the
/// names the old UI matrix used, e.g. `-[Flows testDarkLargestAndLoading]-result-light.png`.
/// Largest type alone is still shot in the running app (`LargestTypeFlows`), which also checks reachability,
/// scrolling and the bars. Sheets and pushed pages that only private view state opens are rendered on their own.
class SnapshotCase: XCTestCase {
    struct Mode { let suffix: String; let dark: Bool; let largest: Bool }
    static let light = Mode(suffix: "-light", dark: false, largest: false)
    static let dark = Mode(suffix: "--darkModeYES", dark: true, largest: false)
    static let darkLargest = Mode(suffix: "--darkModeYES-largestTypeYES", dark: true, largest: true)
    static let keys = ["darkMode", "largestType", "fixtureImage", "fixtureState", "historyFixtureCount", "exploreQuery", "backupFolderFixture"]
    var dirs = [URL]()

    override func tearDown() async throws {
        await MainActor.run { FolderBackup.shared.stop() }
        for k in SnapshotCase.keys { UserDefaults.standard.removeObject(forKey: k) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }
    @MainActor func model(_ state: String?) -> AppModel {
        let name = "Snapshot-\(UUID().uuidString)"
        dirs.append(Models.support.appendingPathComponent(name))
        return state.map { AppModel(previewState: $0, history: name) } ?? AppModel(history: name)
    }
    @MainActor func until(_ seconds: Double = 10, _ done: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    /// Shows `view` in its own window, waits until two renders 250 ms apart are identical (tasks done, spinners gone;
    /// at most `wait` s), then writes the PNG.
    @MainActor func shot(_ name: String, _ mode: Mode?, test: String = "testDarkLargestAndLoading", wait: Double = 10, _ view: some View) async throws {
        let d = UserDefaults.standard
        d.set(mode?.dark ?? false, forKey: "darkMode"); d.set(mode?.largest ?? false, forKey: "largestType")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let w = UIWindow(windowScene: scene)
        w.overrideUserInterfaceStyle = mode?.dark == true ? .dark : .light
        w.rootViewController = UIHostingController(rootView: view.debugAppearance())
        w.isHidden = false
        defer { w.isHidden = true; w.rootViewController = nil }
        func render() -> UIImage { UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) } }
        try await Task.sleep(for: .milliseconds(300))
        var image = render(), last: Data?
        let end = Date().addingTimeInterval(wait)
        while Date() < end {
            let bytes = image.cgImage?.dataProvider?.data as Data?
            if bytes != nil && bytes == last { break }
            last = bytes
            try await Task.sleep(for: .milliseconds(250))
            image = render()
        }
        let png = try XCTUnwrap(image.pngData())
        XCTAssertEqual(image.size, w.bounds.size, name)
        XCTAssertLessThan(Self.systemBlue(image), 200, "\(name): system blue in the tab bar (the app tint is missing)")
        XCTAssertGreaterThan(png.count, 20_000, "\(name) looks blank")
        let file = "-[Flows \(test)]-\(name)\(mode?.suffix ?? "").png"
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = file; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let dir = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent(file))
        }
    }
    /// Pixels of iOS system blue as the glass tab bar renders it (about #3070E0 light, #40A0F0 dark) in the bottom 120 pt.
    /// The app's accent is green; thousands of these mean the tint fell off the root (sky in photos is far darker).
    static func systemBlue(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, band = min(cg.height, Int(120 * image.scale))
        var px = [UInt8](repeating: 0, count: w * band * 4)
        guard let ctx = CGContext(data: &px, width: w, height: band, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: cg.height))   // the image's bottom rows land in this band
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] < 90 && (100...185).contains(px[i + 1]) && px[i + 2] > 210 && Int(px[i + 2]) - Int(px[i]) > 140 { n += 1 }
        return n
    }
    func sheet(_ m: AppModel, _ content: some View) -> some View {
        // The app's window carries the tint for sheets presented above RootView; this host has no such window.
        RootView().environment(m).sheet(isPresented: .constant(true)) { content.environment(m).tint(Palette.green).debugAppearance() }
    }

}

/// The old `testDarkLargestAndLoading` matrix.
final class AppearanceSnapshots: SnapshotCase {
    /// Result, its correction and place sheets, then every tab root, the species page, settings and backup.
    @MainActor func testDarkLargestAndLoading() async throws {
        for mode in [SnapshotCase.light, SnapshotCase.dark, SnapshotCase.darkLargest] {
            let m = model("normal"), r = try XCTUnwrap(m.current)
            await until { !m.items.isEmpty }
            try await shot("result", mode, RootView().environment(m))
            try await shot("correction", mode, sheet(m, CorrectionSheet(record: r, index: r.selected)))
            try await shot("place", mode, sheet(m, PlacePicker()))
            m.showing = false
            try await shot("identify", mode, RootView().environment(m))
            m.tab = .records; m.recordsMode = "species"
            try await shot("records-species", mode, RootView().environment(m))
            m.paths[.records] = [.species("Haliaeetus leucocephalus")]
            try await shot("species-page", mode, RootView().environment(m))
            m.paths[.records] = []
            m.recordsMode = "photos"
            try await shot("records-photos", mode, RootView().environment(m))
            m.recordsMode = "pending"
            try await shot("records-pending", mode, RootView().environment(m))
            m.recordsMode = "species"; m.tab = .stats
            try await shot("stats", mode, RootView().environment(m))
            m.tab = .settings
            try await shot("settings", mode, RootView().environment(m))
            try await shot("backup", mode, sheet(m, NavigationStack { BackupView() }))
            m.tab = .explore
            try await shot("explore", mode, RootView().environment(m))
            UserDefaults.standard.set("tern", forKey: "exploreQuery")
            try await shot("explore-search", mode, RootView().environment(m))
            UserDefaults.standard.removeObject(forKey: "exploreQuery")
        }
        // The spinner never settles: a fixed short wait.
        // A photo being identified opens its result page at once (no overlay card).
        let loading = model("loading"); loading.paths[.identify] = [.identifying]
        try await shot("loading-preview", nil, wait: 0.5, RootView().environment(loading))
    }

}

/// The old `testStep4Screens` matrix (its own class so parallel testing runs it beside the other).
final class Step4Snapshots: SnapshotCase {
    /// Step 4 surfaces (photo calendar month/day/year, map, observation editor, eBird, 这里这个月, folder backup) with
    /// three photos and a device place, in light and dark.
    @MainActor func testStep4Screens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BirdCMBackupFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let d = UserDefaults.standard, now = Period.current(), day = "2026-11-14"
        guard case let .month(year, _) = now else { return }
        for mode in [SnapshotCase.light, SnapshotCase.dark] {
            func shot(_ name: String, wait: Double = 10, _ view: some View) async throws { try await self.shot(name, mode, test: "testStep4Screens", wait: wait, view) }
            d.set(fixtures.appendingPathComponent("photo-0.jpg").path, forKey: "fixtureImage"); d.set("photo-gps", forKey: "fixtureState"); d.set(3, forKey: "historyFixtureCount")
            let m = model(nil)
            m.homePlace = Place(lat: 33.7, lon: -118.06, label: "Bolsa Chica", source: "device")
            await m.pickFixture(); m.showing = false
            await until { m.items.count == 3 }
            let o = try XCTUnwrap(m.ledger.observations.first { $0.species == "Haliaeetus leucocephalus" && $0.day == day })
            m.tab = .stats
            try await shot("stats", RootView().environment(m))
            let calendar = { (p: Period) in NavigationStack { ScrollView { PhotoCalendar(period: .constant(p), open: { _ in }).padding(16) }.background(Palette.paper).navigationTitle("统计") }.environment(m) }
            try await shot("calendar-month", calendar(now))
            try await shot("calendar-day", NavigationStack { SightingList(title: day, range: (day, day), day: day) }.environment(m))
            try await shot("calendar-year", calendar(.year(year)))
            // Map tiles keep streaming in: a bounded wait.
            try await shot("map", wait: 3, NavigationStack { SightingMap(range: now.range) }.environment(m))
            try await shot("observation-editor", NavigationStack { SightingList(title: now.title, range: now.range, day: nil) }.environment(m)
                .sheet(isPresented: .constant(true)) { SightingSheet(sighting: o).environment(m).tint(Palette.green).debugAppearance() })
            try await shot("ebird", sheet(m, EBirdSheet(title: now.title, range: now.range)))
            m.tab = .explore
            try await shot("explore-local", wait: 20, RootView().environment(m))
            d.set(folder.path, forKey: "backupFolderFixture")
            await FolderBackup.shared.runIfDue(m.library, force: true)
            XCTAssertNil(FolderBackup.shared.lastError); XCTAssertNotNil(FolderBackup.shared.lastSuccess)
            try await shot("backup-folder-ok", sheet(m, NavigationStack { BackupView() }))
            FolderBackup.shared.stop()
            for k in SnapshotCase.keys { d.removeObject(forKey: k) }
        }
        let m = model(nil)
        d.set("/nonexistent/birdcm", forKey: "backupFolderFixture")
        await FolderBackup.shared.runIfDue(m.library, force: true)
        XCTAssertNotNil(FolderBackup.shared.lastError)
        try await shot("backup-folder-error", nil, test: "testStep4Screens", sheet(m, NavigationStack { BackupView() }))
        FolderBackup.shared.stop()
        try await shot("backup-folder-off", nil, test: "testStep4Screens", sheet(m, NavigationStack { BackupView() }))
    }
}
