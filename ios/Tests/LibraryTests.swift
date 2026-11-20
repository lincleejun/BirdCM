import XCTest
import SwiftUI
import SQLite3
@testable import BirdCM

/// docs/design-lifelist.md §10 with synthetic sightings only (invented dates/places; bytes are labels or CC0 fixtures).
final class LibraryTests: XCTestCase {
    let P = Place(lat: 10.123, lon: 20.123, label: "P", source: "map"), Q = Place(lat: 10.145, lon: 20.145, label: "Q", source: "map")
    let pst = TimeZone(secondsFromGMT: -8 * 3600)!
    func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    func bird(_ sci: String, _ level: String = "species", clear: Bool = true) -> Identification {
        Identification(top5: [Candidate(scientific: sci, english: "", chinese: "", p: 0.99)], level: level, name: level == "uncertain" ? nil : sci, clear: clear)
    }
    func shooting(_ wall: String?, _ offset: String? = nil) -> Shooting { var s = Shooting(data: Data()); s.takenAt = wall; s.timeOffset = offset; return s }
    func record(_ birds: [Identification?], _ wall: String?, _ offset: String?, _ place: Place?) -> Record {
        var r = Record(boxes: birds.indices.map { [0.1 + 0.4 * Double($0), 0.1, 0.4 + 0.4 * Double($0), 0.5] }, selected: 0, result: birds.first ?? nil, shooting: shooting(wall, offset), place: place)
        for (i, b) in birds.enumerated() { if let b { r.results[String(i)] = b } }
        return r
    }
    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    func ledger(_ lib: Library) throws -> Ledger { Ledger(items: try lib.items(), edits: try lib.groupEdits()) }
    func check(_ l: Ledger, _ p: Period, _ obs: Int, _ est: Int, _ species: Int, file: StaticString = #filePath, line: UInt = #line) {
        let s = l.summary(p.range)
        XCTAssertEqual([s.observations, s.estimate, s.species], [obs, est, species], p.title, file: file, line: line)
    }

    /// 最近查看: last opened first, never opened by identification time, then capture time; device-local, not exported,
    /// no revision bump, statistics unchanged.
    func testRecentlyViewedOrder() throws {
        let dir = tmp(), lib = try Library(dir: dir), A = "Sterna hirundo"
        func add(_ wall: String, _ identified: String, _ n: Int) throws -> UUID {
            var r = record([bird(A)], wall, "-08:00", P); r.date = date(identified)
            return try lib.save(r, data: Data("frame \(n)".utf8), zone: pst, now: date(identified)).id
        }
        let old = try add("2026-01-01T08:00:00", "2026-03-01T00:00:00Z", 1)        // identified earliest
        let mid = try add("2026-02-01T08:00:00", "2026-03-02T00:00:00Z", 2)
        let new = try add("2026-03-01T08:00:00", "2026-03-03T00:00:00Z", 3)
        let tieA = try add("2026-01-05T08:00:00", "2026-03-04T00:00:00Z", 4), tieB = try add("2026-01-06T08:00:00", "2026-03-04T00:00:00Z", 5)
        XCTAssertEqual(Library.recentFirst(try lib.items()).map(\.id), [tieB, tieA, new, mid, old], "identification time, then capture time")
        let before = try lib.snapshot(), stats = try ledger(lib).summary(nil)
        try lib.markViewed(old, now: date("2026-04-01T00:00:00Z")); try lib.markViewed(mid, now: date("2026-04-02T00:00:00Z"))
        XCTAssertEqual(Library.recentFirst(try lib.items()).map(\.id), [mid, old, tieB, tieA, new])
        XCTAssertEqual(try lib.snapshot(), before, "no revision, record or subject change")
        XCTAssertEqual(try ledger(lib).summary(nil).observations, stats.observations)
        let archive = dir.appendingPathComponent("x.birdcm"); try lib.export(to: archive)
        XCTAssertTrue(try SQL(archive.path, readOnly: true).rows("SELECT 1 FROM sqlite_master WHERE name='ll_view'").isEmpty, "not exported")
        XCTAssertEqual(try Library(dir: dir).items().first { $0.id == mid }?.viewed, "2026-04-02T00:00:00.000Z", "survives reopening")
    }
    /// Readable place names: town · park/district from Apple's answer, never a street; cached per cell, never exported.
    func testPlaceNameComposeAndCache() throws {
        XCTAssertEqual(PlaceNames.compose(locality: "Cupertino", county: "Santa Clara County", state: "CA", area: "Stevens Creek County Park", district: "Monta Vista", water: nil, country: "United States"), "Cupertino · Stevens Creek County Park")
        XCTAssertEqual(PlaceNames.compose(locality: nil, county: "Santa Clara County", state: "CA", area: nil, district: "Cupertino", water: nil, country: "United States"), "Santa Clara County · Cupertino")
        XCTAssertEqual(PlaceNames.compose(locality: "Huntington Beach", county: nil, state: nil, area: nil, district: "Huntington Beach", water: nil, country: nil), "Huntington Beach")
        XCTAssertEqual(PlaceNames.compose(locality: nil, county: nil, state: nil, area: nil, district: nil, water: nil, country: "United States"), "United States")
        let dir = tmp(), lib = try Library(dir: dir)
        try lib.setPlaceName("p:3732:-12203", "Cupertino · Stevens Creek County Park")
        XCTAssertEqual(try Library(dir: dir).placeNames(), ["p:3732:-12203": "Cupertino · Stevens Creek County Park"])
        let archive = dir.appendingPathComponent("x.birdcm"); try lib.export(to: archive)
        XCTAssertTrue(try SQL(archive.path, readOnly: true).rows("SELECT 1 FROM sqlite_master WHERE name='ll_place_name'").isEmpty, "not exported")
    }
    /// 鸟种 default 最近识别: the species whose photo was identified (or corrected / opened) last comes first, even when
    /// that photo was taken long ago; 最近见到 still orders by capture date.
    @MainActor func testSpeciesRecentlyIdentifiedOrder() throws {
        let lib = try Library(dir: tmp()), A = "Sterna hirundo", B = "Ardea alba"
        func add(_ sci: String, _ wall: String, _ identified: String, _ n: Int) throws -> UUID {
            var r = record([bird(sci)], wall, "-08:00", P); r.date = date(identified)
            return try lib.save(r, data: Data("frame \(n)".utf8), zone: pst, now: date(identified)).id
        }
        _ = try add(A, "2026-06-01T08:00:00", "2026-06-01T20:00:00Z", 1)
        let old = try add(B, "2024-01-01T08:00:00", "2026-07-01T20:00:00Z", 2)     // an old photo identified later
        func order() throws -> [String] { RecordsView.recentlyIdentified(Array(try ledger(lib).allTime.values), items: try lib.items()).map(\.id) }
        XCTAssertEqual(try order(), [B, A], "identified last, although taken first")
        _ = try add(A, "2023-05-01T08:00:00", "2026-08-01T20:00:00Z", 3)
        XCTAssertEqual(try order(), [A, B])
        try lib.markViewed(old, now: date("2026-09-01T00:00:00Z"))     // opened, or corrected (edit() marks it)
        XCTAssertEqual(try order(), [B, A])
    }
    func testDeterministicFixture() throws {
        let lib = try Library(dir: tmp()), A = "Sterna hirundo", B = "Ardea alba"
        var n = 0
        @discardableResult func add(_ birds: [Identification?], _ wall: String?, _ offset: String?, _ place: Place? = nil, now: Date = Date(), bytes: String? = nil) throws -> Record {
            n += 1
            var r = record(birds, wall, offset, place ?? P); r.date = now     // Record.date is the identification instant
            return try lib.save(r, data: Data((bytes ?? "frame \(n)").utf8), zone: pst, now: now)
        }
        try add([bird(A), bird(A)], "2025-12-31T23:58:00", "-08:00")
        for _ in 0..<300 { try add([bird(A)], "2026-01-01T00:02:00", "-08:00") }
        try add([bird(B)], "2026-01-01T00:30:00", "+14:00")
        try add([bird(A)], "2026-01-31T23:59:00", "-08:00", Q)
        try add([bird(B)], "2026-02-01T00:01:00", "+14:00")
        try add([bird(A), nil], nil, nil, now: date("2026-11-18T17:00:00Z"), bytes: "no exif")
        try add([bird("Ardea", "genus")], "2026-01-01T09:00:00", "-08:00")
        try add([bird("x", "uncertain")], "2026-01-01T09:00:00", "-08:00")
        try add([], "2026-11-18T12:00:00", "-08:00")
        // Re-identifying the no-EXIF photo on Nov 19 keeps its frozen Nov 18 fallback day.
        try add([bird(A), nil], nil, nil, now: date("2026-11-19T17:00:00Z"), bytes: "no exif")
        let l = try ledger(lib)
        check(l, .month(2025, 12), 1, 2, 1); check(l, .month(2026, 1), 3, 3, 2); check(l, .month(2026, 2), 1, 1, 1)
        check(l, .month(2026, 11), 1, 1, 1); check(l, .year(2026), 5, 5, 2); check(l, .all, 6, 7, 2)
        let all = l.summary(nil)
        XCTAssertEqual(all.activeDays, 5); XCTAssertEqual(all.pending, 3); XCTAssertEqual(all.noBird, 1); XCTAssertEqual(all.photos, 308)
        XCTAssertEqual(l.allTime[A]?.first, "2025-12-31"); XCTAssertEqual(l.allTime[B]?.first, "2026-01-01")
        XCTAssertEqual(l.summary(Period.month(2026, 1).range).newSpecies, 1); XCTAssertEqual(l.summary(Period.month(2026, 11).range).newSpecies, 0)
        XCTAssertEqual(l.summary(Period.month(2025, 12).range).newSpecies, 1)
        XCTAssertEqual(l.summary(Period.month(2026, 1).range).list.map(\.id).sorted(), [B, A].sorted())
        XCTAssertEqual(l.summary(Period.month(2026, 2).range).list.map(\.id), [B])
        XCTAssertEqual(l.summary(Period.month(2026, 11).range).list.map(\.id), [A])
        XCTAssertEqual(l.allTime[A]?.photos.count, 303); XCTAssertEqual(l.allTime[B]?.photos.count, 2)
        let fallback = try XCTUnwrap(l.items.first { $0.subjects.count == 2 && $0.dateSource != "photo" })
        XCTAssertEqual([fallback.day, fallback.dateSource, fallback.wall], ["2026-11-18", "identified", "2026-11-18T09:00:00"])
    }
    func testTimeAndPlaceBuckets() throws {
        XCTAssertEqual(Library.placeKey(lat: 10.123, lon: 20.123, region: nil), "p:1012:2012")
        XCTAssertEqual(Library.placeKey(lat: -0.001, lon: -0.001, region: nil), "p:-1:-1")
        XCTAssertEqual(Library.placeKey(lat: 90, lon: 180, region: nil), "p:8999:-18000")
        XCTAssertEqual(Library.placeKey(lat: -90, lon: -180, region: nil), "p:-9000:-18000")
        XCTAssertEqual(Library.placeKey(lat: nil, lon: nil, region: "US-CA"), "r:US-CA")
        XCTAssertEqual(Library.placeKey(lat: nil, lon: nil, region: nil), "none")
        XCTAssertEqual(Library.groupKey("Sterna hirundo", "2026-01-01", "p:1:2"), #"["obs-v1","Sterna hirundo","2026-01-01","p:1:2"]"#)
        XCTAssertEqual(Library.validWall("2028-02-29T10:00:00"), "2028-02-29T10:00:00"); XCTAssertNil(Library.validWall("2026-02-29T10:00:00"))
        XCTAssertNil(Library.validWall("0000-00-00T00:00:00")); XCTAssertEqual(Library.validWall("2026-03-01"), "2026-03-01")
        XCTAssertEqual(Library.offsetMinutes("+05:45"), 345); XCTAssertNil(Library.offsetMinutes("+15:00"))
        let lib = try Library(dir: tmp())
        // DST fold: the same wall clock twice, different offsets, same local day; no offset keeps UTC empty.
        try lib.save(record([bird("Sterna hirundo")], "2026-11-01T01:30:00", "-07:00", P), data: Data("fold a".utf8))
        try lib.save(record([bird("Sterna hirundo")], "2026-11-01T01:30:00", "-08:00", P), data: Data("fold b".utf8))
        try lib.save(record([bird("Sterna hirundo")], "2026-11-01T23:30:00", nil, P), data: Data("no offset".utf8))
        var invalid = record([bird("Sterna hirundo")], "2026-02-29T10:00:00", nil, P); invalid.date = date("2026-03-02T20:00:00Z")
        try lib.save(invalid, data: Data("invalid".utf8), zone: pst)
        let region = Place(lat: 37, lon: -119, label: "美国 · 加利福尼亚州", source: "region", regionCode: "US-CA")
        try lib.save(record([bird("Sterna hirundo")], "2026-11-01T08:00:00", nil, region), data: Data("region".utf8))
        try lib.save(record([bird("Sterna hirundo")], "2026-11-01T09:00:00", nil, nil), data: Data("none".utf8))
        let l = try ledger(lib)
        XCTAssertEqual(Set(l.observations.map(\.id)), [Library.groupKey("Sterna hirundo", "2026-11-01", "p:1012:2012"), Library.groupKey("Sterna hirundo", "2026-03-02", "p:1012:2012"),
                                                        Library.groupKey("Sterna hirundo", "2026-11-01", "r:US-CA"), Library.groupKey("Sterna hirundo", "2026-11-01", "none")])
        XCTAssertEqual(l.items.first { $0.region == "US-CA" }?.lat, nil)
        XCTAssertEqual(try lib.query("SELECT count(*) FROM ll_record WHERE capture_utc IS NULL AND capture_wall IS NOT NULL")[0].n(0), 3)
    }
    func testMutationsNeverDoubleCount() throws {
        let lib = try Library(dir: tmp()), A = "Sterna hirundo", B = "Ardea alba"
        let f1 = try lib.save(record([bird(A)], "2026-01-01T08:00:00", "+08:00", P), data: Data("f1".utf8))
        let f2 = try lib.save(record([bird(A), bird(A)], "2026-01-01T09:00:00", "+08:00", P), data: Data("f2".utf8))
        func state() throws -> [Int] { let s = try ledger(lib).summary(nil); return [s.observations, s.estimate, s.species, s.photos, s.pending] }
        XCTAssertEqual(try state(), [1, 2, 1, 2, 0])
        let ids = f2.subjects!.map(\.id)
        let again = try lib.save(record([bird(A), bird(A)], "2026-01-01T09:00:00", "+08:00", P), data: Data("f2".utf8))
        XCTAssertEqual(again.id, f2.id); XCTAssertEqual(again.subjects!.map(\.id), ids); XCTAssertEqual(try state(), [1, 2, 1, 2, 0])
        try lib.correct(ids[1], state: "species", key: B)
        XCTAssertEqual(try state(), [2, 2, 2, 2, 0])
        _ = try lib.save(record([bird(A), bird(A)], "2026-01-01T09:00:00", "+08:00", P), data: Data("f2".utf8))   // re-identify: correction survives
        XCTAssertEqual(try lib.record(f2.id)?.subjects?[1].key, B)
        try lib.correct(ids[1], state: "uncertain"); XCTAssertEqual(try state(), [1, 1, 1, 2, 1])
        try lib.correct(ids[1], state: "none"); XCTAssertEqual(try state(), [1, 2, 1, 2, 0])
        try lib.setCount(f1.subjects![0].id, 5); XCTAssertEqual(try state()[1], 5)
        try lib.setCount(f1.subjects![0].id, nil); XCTAssertEqual(try state()[1], 2)
        XCTAssertThrowsError(try lib.setCount(f1.subjects![0].id, 0))
        let key = try ledger(lib).observations[0].id
        try lib.setGroupCount(key, 9); XCTAssertEqual(try state()[1], 9)
        try lib.setGroupCount(key, nil); XCTAssertEqual(try state()[1], 2)
        try lib.exclude(ids[0], true); XCTAssertEqual(try state(), [1, 1, 1, 2, 0])
        try lib.exclude(ids[0], false)
        var moved = try XCTUnwrap(lib.record(f2.id)); moved.place = Q; try lib.save(moved); XCTAssertEqual(try state()[0], 2)
        moved.place = P; try lib.save(moved); XCTAssertEqual(try state()[0], 1)
        try lib.setDate(f2.id, wall: "2026-01-02T09:00:00", offset: 480); XCTAssertEqual(try state()[0], 2)
        try lib.setDate(f2.id, wall: nil, offset: nil); XCTAssertEqual(try state()[0], 1)
        try lib.delete(f2.id); XCTAssertEqual(try state(), [1, 1, 1, 1, 0])
        try lib.delete(f1.id); XCTAssertEqual(try state(), [0, 0, 0, 0, 0])
        try lib.save(record([bird(A)], "2026-01-01T08:00:00", "+08:00", P), data: Data("f1".utf8))
        XCTAssertEqual(try state(), [1, 1, 1, 1, 0])
        // An older photo moves first-seen backward.
        try lib.save(record([bird(A)], "2025-06-01T08:00:00", "+08:00", P), data: Data("older".utf8))
        XCTAssertEqual(try ledger(lib).allTime[A]?.first, "2025-06-01")
        // A hand-drawn replacement of the selected box keeps its subject ID and correction.
        _ = try lib.save(record([bird(A), bird(A)], "2026-01-01T09:00:00", "+08:00", P), data: Data("f2".utf8))   // restores the tombstone
        var r = try XCTUnwrap(lib.record(f2.id)); XCTAssertEqual(r.boxes.count, 2)
        try lib.correct(r.subjects![0].id, state: "species", key: B)
        r = try XCTUnwrap(lib.record(f2.id)); r.boxes[0] = [0.05, 0.05, 0.3, 0.3]; try lib.save(r)
        XCTAssertEqual(try lib.record(f2.id)?.subjects?[0], SubjectEdit(id: r.subjects![0].id, state: "species", key: B))
        // Model species with unclear features or unknown key never counts; human correction does.
        let unclear = try lib.save(record([bird(A, clear: false), bird("Nonexistent bird")], "2026-05-01T08:00:00", nil, P), data: Data("unclear".utf8))
        let l = Ledger(items: try lib.items(), edits: [:], known: Catalogue.shared.contains)
        XCTAssertEqual(l.pending.filter { $0.item.id == unclear.id }.count, 2)
        try lib.correct(unclear.subjects![0].id, state: "species", key: A)
        XCTAssertEqual(Ledger(items: try lib.items(), edits: [:], known: Catalogue.shared.contains).pending.filter { $0.item.id == unclear.id }.count, 1)
    }

    /// Old History folder → library: every record, byte and recovery item survives.
    func makeLegacyStore(_ dir: URL) throws -> [Record] {
        let old = try HistoryStore(dir: dir), photo = try Data(contentsOf: fixtures.appendingPathComponent("photo-0.jpg"))
        var single = record([bird("Sterna hirundo"), nil], "2026-01-01T10:00:00", "+08:00", P); single.results = [:]; single.date = date("2026-01-02T00:00:00Z")
        var perBird = record([bird("Sterna hirundo"), bird("Ardea alba")], nil, nil, nil); perBird.selected = 1; perBird.result = bird("Ardea alba"); perBird.date = date("2026-02-03T04:00:00Z")
        var older = record([bird("Ardea alba")], "2026-03-01T08:00:00", nil, P); older.date = date("2026-03-01T00:00:00Z")
        var newer = older; newer.id = UUID(); newer.date = date("2026-03-05T00:00:00Z"); newer.results = ["0": bird("Sterna hirundo")]; newer.result = bird("Sterna hirundo")
        var noBird = record([], "2026-03-02T08:00:00", nil, P); noBird.date = date("2026-03-02T00:00:00Z")
        var missing = record([bird("Ardea alba")], "2026-04-01T08:00:00", nil, P); missing.date = date("2026-04-01T00:00:00Z")
        let region = Place(lat: 37.2, lon: -119.5, label: "美国 · 加利福尼亚州", source: "region")
        var regional = record([bird("Ardea alba")], "2026-04-02T08:00:00", nil, region); regional.date = date("2026-04-02T00:00:00Z")
        try old.save(single, data: photo); try old.save(perBird, data: photo + Data([1])); try old.save(older, data: photo + Data([2])); try old.save(newer, data: photo + Data([2]))
        try old.save(noBird, data: photo + Data([3])); try old.save(missing, data: photo + Data([4])); try old.save(regional, data: photo + Data([5]))
        try FileManager.default.removeItem(at: old.image(missing))
        try Data("{\"id\": corrupt".utf8).write(to: dir.appendingPathComponent("\(UUID()).json"))
        return [single, perBird, older, newer, noBird, missing, regional]
    }
    func testMigrationKeepsEveryOldRecord() throws {
        let dir = tmp(), old = try makeLegacyStore(dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        let raw = Dictionary(uniqueKeysWithValues: try files.map { ($0, try Data(contentsOf: dir.appendingPathComponent($0))) })
        let lib = try Library(dir: dir); XCTAssertTrue(lib.needsMigration)
        try lib.migrate(zone: pst)
        // Retry after an interruption (user_version still 0) imports nothing twice.
        try lib.query("PRAGMA user_version=0"); try lib.migrate(zone: pst)
        let reopened = try Library(dir: dir); XCTAssertFalse(reopened.needsMigration)
        XCTAssertEqual(try reopened.query("SELECT count(*) FROM ll_record")[0].n(0), 7)
        for r in old {
            let back = try XCTUnwrap(reopened.record(r.id))
            XCTAssertEqual(back.boxes, r.boxes); XCTAssertEqual(back.shooting.takenAt, r.shooting.takenAt); XCTAssertEqual(back.place, r.place)
            XCTAssertEqual(back.results["0"]?.name, (r.results["0"] ?? (r.selected == 0 ? r.result : nil))?.name)
            let legacy = try reopened.query("SELECT legacy_json,relative_path FROM ll_record JOIN ll_asset ON hash=asset_hash WHERE id=?", [r.id.uuidString.lowercased()])[0]
            XCTAssertEqual(legacy.s(0).map { Data($0.utf8) }, raw["\(r.id).json"])
            // Verbatim (uppercase) legacy name; byte-identical aliases point at the canonical's existing file.
            if r.id != old[5].id { XCTAssertEqual(legacy.s(1), "\(r.id == old[2].id ? old[3].id : r.id).photo") }
        }
        XCTAssertEqual(try reopened.record(old[1].id)?.results["1"]?.name, "Ardea alba")
        XCTAssertEqual(Set(try reopened.record(old[0].id)!.subjects!.map(\.id)), [Library.subjectID(old[0].id, 0), Library.subjectID(old[0].id, 1)])
        XCTAssertEqual(reopened.aliases(old[3].id), 1)
        let items = try reopened.items()
        XCTAssertEqual(items.count, 6); XCTAssertFalse(items.contains { $0.id == old[2].id }); XCTAssertTrue(items.contains { $0.id == old[3].id })
        XCTAssertEqual(try reopened.query("SELECT first_identified_utc FROM ll_record WHERE id=?", [old[3].id.uuidString.lowercased()])[0].s(0), Library.utc(old[2].date))
        let lost = try XCTUnwrap(items.first { $0.id == old[5].id }); XCTAssertTrue(lost.missing); XCTAssertEqual(lost.subjects.count, 1)
        XCTAssertEqual(items.first { $0.id == old[6].id }?.region, "US-CA")
        let issue = try reopened.query("SELECT filename,raw_json FROM ll_legacy_issue")
        XCTAssertEqual(issue.count, 1); XCTAssertEqual(issue[0][1] as? Data, raw[issue[0].s(0)!])
        let l = try ledger(reopened).summary(nil)
        XCTAssertEqual([l.photos, l.noBird, l.pending], [6, 1, 1])
        XCTAssertEqual(items.first { $0.id == old[1].id }?.dateSource, "identified_legacy_zone")
        // Old JSON sidecars remain as read-only recovery files.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.count, 8)
    }
    func testCleanupRemovesOnlyJSONCopiesAlreadyInTheLibrary() throws {
        let dir = tmp(), old = try makeLegacyStore(dir)
        let lib = try Library(dir: dir); XCTAssertTrue(lib.redundantLegacyFiles().isEmpty)     // not before a verified migration
        try lib.migrate(zone: pst)
        let files = lib.redundantLegacyFiles()
        XCTAssertEqual(files.count, 8)                                                           // 7 records + the corrupt file kept as a recovery item
        try Data("changed".utf8).write(to: dir.appendingPathComponent("\(old[0].id).json"))       // a file that differs is never offered
        XCTAssertEqual(lib.redundantLegacyFiles().count, 7)
        for u in lib.redundantLegacyFiles() { try FileManager.default.removeItem(at: u) }
        let reopened = try Library(dir: dir); XCTAssertFalse(reopened.needsMigration)
        for r in old { XCTAssertNotNil(try reopened.record(r.id)); if r.id != old[5].id { XCTAssertNotNil(reopened.url(r.id)) } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(old[0].id).photo").path))
    }
    /// polish.md name block: Chinese title with English beside the Latin; without Chinese, English is the title and the Latin
    /// stands alone; VoiceOver reads every name.
    @MainActor func testSpeciesNameLines() {
        let zh = Catalogue.Species(sci: "Haliaeetus leucocephalus", en: "Bald Eagle", zh: "白头海雕", genus: "", family: "")
        XCTAssertEqual([zh.name, zh.alt], ["白头海雕", "Bald Eagle"])
        let en = Catalogue.Species(sci: "Aus bus", en: "Some Bird", zh: "", genus: "", family: "")
        XCTAssertEqual([en.name, en.alt], ["Some Bird", ""])
        let bare = Catalogue.Species(sci: "Aus cus", en: "", zh: "", genus: "", family: "")
        XCTAssertEqual([bare.name, bare.alt], ["Aus cus", ""])
        XCTAssertEqual(SpeciesName(title: zh.name, alt: zh.alt, sci: zh.sci, size: .row).label, "白头海雕，Bald Eagle，Haliaeetus leucocephalus")
        XCTAssertEqual(SpeciesName(title: en.name, alt: en.alt, sci: en.sci, size: .card).label, "Some Bird，Aus bus")
    }
    /// Narrow widths: a hero / row block stays two lines (same height as when everything fits); PNGs go to SCREENSHOT_DIR
    /// to check the order by eye (common name gives way, then goes with its dot; the Latin last).
    @MainActor func testSpeciesNameNarrowWidths() throws {
        let long = SpeciesName(title: "北美黑啄木鸟", alt: "Northern Red-shafted Flicker", sci: "Colaptes auratus cafer", size: .row)
        var heights = [CGFloat]()
        for (size, w) in [(SpeciesName.Size.row, 380.0), (.row, 240), (.row, 150), (.hero, 380), (.hero, 260)] {
            let v = SpeciesName(title: long.title, alt: long.alt, sci: long.sci, size: size).frame(width: w, alignment: .leading).padding(4).background(Color.white)
            let r = ImageRenderer(content: v); r.scale = 2
            let image = try XCTUnwrap(r.uiImage)
            if size == .row { heights.append(image.size.height) }
            if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("species-name-\(size)-\(Int(w)).png"))
            }
        }
        XCTAssertEqual(Set(heights).count, 1, "row block height changes with width: \(heights)")
    }
    func testPinyinFullAndInitials() async throws {
        let c = Catalogue.shared; await c.preparePinyin()
        XCTAssertEqual(Catalogue.pinyinOf("白头海雕").0, "baitouhaidiao"); XCTAssertEqual(Catalogue.pinyinOf("白头海雕").1, "bthd")
        XCTAssertTrue(c.search("baitouhaidiao").prefix(3).contains { $0.sci == "Haliaeetus leucocephalus" })
        XCTAssertTrue(c.search("bthd").prefix(5).contains { $0.sci == "Haliaeetus leucocephalus" })
        XCTAssertEqual(c.search("Bald Eagle").first?.sci, "Haliaeetus leucocephalus")
    }
    /// An unreadable original is an I/O failure, not a corrupt record: migration stops unverified and the next attempt imports it.
    func testUnreadablePhotoRetriesInsteadOfQuarantining() throws {
        let dir = tmp(), old = try makeLegacyStore(dir)
        let photo = dir.appendingPathComponent("\(old[0].id).photo")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: photo.path)
        let lib = try Library(dir: dir)
        XCTAssertThrowsError(try lib.migrate(zone: pst)); XCTAssertTrue(try Library(dir: dir).needsMigration)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: photo.path)
        try lib.migrate(zone: pst)
        XCTAssertNotNil(try lib.record(old[0].id)); XCTAssertEqual(try lib.query("SELECT count(*) FROM ll_legacy_issue WHERE raw_json IS NOT NULL")[0].n(0), 1)
    }
    func testPortableArchiveRoundTripAndRejection() throws {
        let dir = tmp(); _ = try makeLegacyStore(dir)
        let lib = try Library(dir: dir); try lib.migrate(zone: pst)
        let extra = try lib.save(record([bird("Sterna hirundo"), bird("Ardea alba")], "2026-05-01T08:00:00", "-08:00", Q), data: Data("new".utf8))
        try lib.correct(extra.subjects![1].id, state: "uncertain"); try lib.setCount(extra.subjects![0].id, 4)
        try lib.setGroupCount(Library.groupKey("Sterna hirundo", "2026-05-01", "p:1014:2014"), 7)
        try lib.delete(try lib.items().first { $0.subjects.isEmpty }!.id)
        let archive = tmp().appendingPathExtension("birdcm")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lib.export(to: archive)
        let before = try lib.snapshot(), metrics = try ledger(lib).summary(nil)
        let fresh = try Library(dir: tmp())
        XCTAssertEqual(try fresh.importArchive(archive), 8)
        XCTAssertEqual(try fresh.snapshot(), before)
        XCTAssertEqual(try ledger(fresh).summary(nil).estimate, metrics.estimate); XCTAssertEqual(try ledger(fresh).summary(nil).observations, metrics.observations)
        for item in try fresh.items() where !item.missing { XCTAssertEqual(try Models.digest(fresh.url(item.id)!), item.hash) }
        XCTAssertEqual(try fresh.importArchive(archive), 0); XCTAssertEqual(try fresh.snapshot(), before)
        XCTAssertEqual(try lib.importArchive(archive, restore: true), 8); XCTAssertEqual(try lib.snapshot(), before)
        // Corrupt blob, unknown schema object and future version are rejected without touching the library.
        for damage in ["UPDATE archive_blob SET original=zeroblob(length(original)) WHERE rowid=1", "CREATE TABLE extra(x)", "PRAGMA user_version=2", "CREATE TRIGGER t AFTER INSERT ON ll_asset BEGIN SELECT 1; END"] {
            let bad = archive.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: archive, to: bad)
            try SQL(bad.path).exec(damage)
            XCTAssertThrowsError(try fresh.importArchive(bad), damage); XCTAssertEqual(try fresh.snapshot(), before)
        }
    }
}

/// Cross-platform contract: docs/fixtures/lifelist (desktop golden files), and the shared archive conventions.
final class CrossPlatformTests: XCTestCase {
    let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/fixtures/lifelist")
    func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    func desktopLibrary() throws -> Library {
        let lib = try Library(dir: tmp())
        XCTAssertEqual(try lib.importArchive(shared.appendingPathComponent("fixture-v1.birdcm")), 308)
        return lib
    }
    func testDesktopArchiveGivesExpectedNumbers() throws {
        struct Scope: Decodable { let name: String; let from: String?; let to: String?; let species, observations, estimated_count, new_species, active_days, photos, pending_subjects, no_bird_photos: Int; let species_keys: [String] }
        struct Expected: Decodable { let scopes: [Scope]; let first_seen: [String: String] }
        struct Fixture: Decodable { let expected: Expected }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: shared.appendingPathComponent("fixture-v1.json")))
        let lib = try desktopLibrary()
        let ledger = Ledger(items: try lib.items(), edits: try lib.groupEdits(), known: Catalogue.shared.contains)
        for e in fixture.expected.scopes {
            let s = ledger.summary(e.from.map { ($0, e.to!) })
            XCTAssertEqual([s.species, s.observations, s.estimate, s.newSpecies, s.activeDays, s.photos, s.pending, s.noBird],
                           [e.species, e.observations, e.estimated_count, e.new_species, e.active_days, e.photos, e.pending_subjects, e.no_bird_photos], e.name)
            XCTAssertEqual(s.list.map(\.id).sorted(), e.species_keys, e.name)
        }
        for (k, v) in fixture.expected.first_seen { XCTAssertEqual(ledger.allTime[k]?.first, v) }
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("fixture-v1.json"))) as! [String: Any]
        let groups = (raw["expected"] as! [String: Any])["groups"] as! [[Any]]
        XCTAssertEqual(ledger.observations.count, groups.count)
        for g in groups {
            let key = Library.groupKey(g[1] as! String, g[2] as! String, g[3] as! String)
            let o = try XCTUnwrap(ledger.observations.first { $0.id == key }, key)
            XCTAssertEqual([o.estimate, o.frames.count], [g[4] as! Int, g[5] as! Int], key)
        }
        // Vectors shared with the desktop.
        let vectors = raw["vectors"] as! [String: Any]
        for v in vectors["place_key"] as! [[Any]] { XCTAssertEqual(Library.placeKey(lat: v[0] as? Double, lon: v[1] as? Double, region: v[2] as? String), v[3] as? String) }
    }
    func testEBirdBytesMatchDesktopGolden() throws {
        let lib = try desktopLibrary()
        let ledger = Ledger(items: try lib.items(), edits: try lib.groupEdits(), known: Catalogue.shared.contains)
        let csv = try EBird.csv(EBird.checklists(ledger, nil, rarity: Catalogue.shared.rarity), fallback: .include, estimates: false)
        if Data(csv.utf8) != (try Data(contentsOf: shared.appendingPathComponent("ebird-v1.csv"))) { print("EBIRD-OUT\n" + csv) }
        XCTAssertEqual(Data(csv.utf8), try Data(contentsOf: shared.appendingPathComponent("ebird-v1.csv")))
        XCTAssertEqual(EBird.clean(" a,\"b\"\n c ", 4000), "a b c"); XCTAssertEqual(EBird.clean("abcdef", 3), "abc")
        XCTAssertEqual(try EBird.csv(EBird.checklists(ledger, nil, rarity: Catalogue.shared.rarity), fallback: .exclude, estimates: true).split(separator: "\n").count, 5)
    }
    /// The pre-E006 EBird.checklists / pointCodes, kept verbatim as the reference for the current implementation.
    static func referenceChecklists(_ ledger: Ledger, _ range: (String, String)?, rarity: Rarity?) -> [EBird.Checklist] {
        func pointCodes(_ lat: Double, _ lon: Double, _ rarity: Rarity?, bucket: String) -> (String, String, String) {
            guard let rarity else { return ("", "", "") }
            let r = rarity.regionAt(lat: lat, lon: lon, bucket: bucket)
            guard let country = r.country else { return ("", "", "") }
            if let div = r.division {
                let en = rarity.rows("SELECT name_en FROM regions WHERE code=?", [div]).first?.first ?? div
                return ("\(en) \(country)", String(div.split(separator: "-", maxSplits: 1).last ?? ""), country)
            }
            return (Place.countries.first { $0["code"] == country }?["en"] ?? rarity.rows("SELECT name_en FROM regions WHERE code=?", [country]).first?.first ?? country, "", country)
        }
        let groups = Dictionary(grouping: ledger.observations.filter { Ledger.inRange($0.day, range) }) { $0.day + "|" + $0.place }
        return groups.keys.sorted { a, b in let x = a.split(separator: "|", maxSplits: 1), y = b.split(separator: "|", maxSplits: 1); return (x[0], x[1]) < (y[0], y[1]) }.map { key in
            let list = groups[key]!, day = list[0].day, pk = list[0].place
            var rows = [(item: PhotoItem, sub: SubjectItem)]()
            for o in list { for item in ledger.evidence(o) { for sub in item.subjects where Ledger.eligible(sub, ledger.known) && sub.key == o.species { rows.append((item, sub)) } } }
            rows.sort { ($0.item.capture ?? "", $0.item.hash, $0.sub.id) < ($1.item.capture ?? "", $1.item.hash, $1.sub.id) }
            let first = rows[0].item
            var lat: Double?, lon: Double?, name = "", state = "", country = ""
            if let a = first.lat, let o = first.lon {
                lat = min(89.99999, max(-89.99999, a)); lon = o
                (name, state, country) = pointCodes(lat!, lon!, rarity, bucket: first.placeKey)
                name = "\(name) \(String(format: "%.4f", lat!)) \(String(format: "%.4f", lon!))".trimmingCharacters(in: .whitespaces)
            } else if let code = first.region {
                let en = rarity?.rows("SELECT name_en FROM regions WHERE code=?", [code]).first?.first ?? code
                name = en + (code.contains("-") ? " " + code.prefix(2) : ""); state = code.contains("-") ? String(code.split(separator: "-", maxSplits: 1)[1]) : ""; country = String(code.prefix(2))
            }
            let timed = rows.filter { ["photo", "user"].contains($0.item.dateSource) && ($0.item.capture?.count ?? 0) >= 16 }.map { $0.item.capture! }
            let p = day.split(separator: "-")
            return EBird.Checklist(day: day, placeKey: pk, date: "\(p[1])/\(p[2])/\(p[0])", start: timed.min().map { String($0.dropFirst(11).prefix(5)) } ?? "", name: name.isEmpty ? "BirdCM location" : name,
                                   lat: lat, lon: lon, state: state, country: country, fallback: rows.contains { $0.item.dateSource.hasPrefix("identified") }, sightings: list.sorted { $0.species < $1.species })
        }
    }
    /// EBird.checklists equals the reference field by field (order, every Checklist field, sightings order and content):
    /// a synthetic library of another size and species set, and the desktop fixture (region-only rows), with and without rarity, all time and a range.
    func testEBirdChecklistsMatchReference() throws {
        let dir = tmp()
        try Library(dir: dir).seedSynthetic(4_000, species: Array(Catalogue.shared.all.dropFirst(300).prefix(250).map(\.sci)))
        let synthetic = Ledger(items: try Library(dir: dir).items(), edits: [:], known: Catalogue.shared.contains)
        let lib = try desktopLibrary()
        let desktop = Ledger(items: try lib.items(), edits: try lib.groupEdits(), known: Catalogue.shared.contains)
        func row(_ c: EBird.Checklist) -> String {
            ([c.day, c.placeKey, c.date, c.start, c.name, c.lat.map { "\($0.bitPattern)" } ?? "nil", c.lon.map { "\($0.bitPattern)" } ?? "nil", c.state, c.country, "\(c.fallback)"]
             + c.sightings.map { "\($0.id)/\($0.species)/\($0.day)/\($0.place)/\($0.frames.sorted { $0.key < $1.key })/\(String(describing: $0.override))" }).joined(separator: "\u{1}")
        }
        for (label, ledger) in [("synthetic", synthetic), ("desktop", desktop)] {
            for rarity in [Catalogue.shared.rarity, nil] {
                for range in [nil, ("2024-01-01", "2024-06-30")] as [(String, String)?] {
                    let new = EBird.checklists(ledger, range, rarity: rarity).map(row), old = Self.referenceChecklists(ledger, range, rarity: rarity).map(row)
                    XCTAssertEqual(new.count, old.count, label)
                    XCTAssertEqual(new, old, "\(label) rarity \(rarity != nil) range \(range != nil)")
                    if range == nil { XCTAssertGreaterThan(new.count, label == "synthetic" ? 1000 : 3, label) }
                }
            }
        }
    }
    /// Region names are cached by the code's bytes, as SQLite compares them: precomposed and decomposed "US-é" stay two lookups.
    func testEBirdRegionNameCacheKeysOnBytes() throws {
        let path = tmp().appendingPathExtension("sqlite"); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE regions(code TEXT, name_en TEXT); INSERT INTO regions VALUES('US-\u{00E9}', 'Precomposed');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let rarity = try Rarity(path: path)
        let items = ["US-\u{00E9}", "US-e\u{0301}"].enumerated().map { i, code in
            PhotoItem(id: UUID(), hash: "h\(i)", path: nil, missing: false, day: "2024-01-0\(i + 1)", wall: "2024-01-0\(i + 1)T08:00:00", dateSource: "photo", offset: nil, capture: "2024-01-0\(i + 1)T08:00:00",
                      lat: nil, lon: nil, region: code, placeLabel: nil, placeSource: "region",
                      subjects: [SubjectItem(id: "s\(i)", ordinal: 0, box: [0.1, 0.1, 0.5, 0.5], crop: nil, level: "species", modelKey: "Ardea alba", state: "", corrected: nil, count: nil, excluded: false)])
        }
        let ledger = Ledger(items: items)
        let new = EBird.checklists(ledger, nil, rarity: rarity), old = Self.referenceChecklists(ledger, nil, rarity: rarity)
        XCTAssertEqual(new.count, 2)
        XCTAssertEqual(new.map { [$0.day, $0.name, $0.state, $0.country] }, old.map { [$0.day, $0.name, $0.state, $0.country] })
        XCTAssertEqual(old.map(\.name), ["Precomposed US", "US-e\u{0301} US"])
    }
    func testSharedUUIDAndArchiveConventions() throws {
        XCTAssertEqual(Library.stableUUID("abc"), "ba7816bf-8f01-5fea-8141-40de5dae2223")
        let zero = String(repeating: "0", count: 64)
        XCTAssertEqual(Library.stableUUID("desktop subject/\(zero)/" + [0.1, 0.1, 0.3, 0.3].map { String(format: "%.6f", $0) }.joined(separator: ",")), "8f37fa25-b453-5c52-8061-5ac2f8eb434f")
        XCTAssertEqual(Library.stableUUID("desktop native record/\(zero)"), "915ada0c-7c17-5a17-b77e-913d2508c95f")
        // An iOS archive has exactly the desktop's object names, no path authority and the shared header.
        let lib = try desktopLibrary()
        var r = Record(boxes: [[0.1, 0.1, 0.5, 0.5]], selected: 0, result: Identification(top5: [Candidate(scientific: "Ardea alba", english: "", chinese: "", p: 0.99)], level: "species", name: "Ardea alba", clear: true), shooting: Shooting(data: Data()), place: nil)
        r.shooting.takenAt = "2026-03-01T08:00:00"
        try lib.save(r, data: Data("ios photo".utf8))
        let out = tmp().appendingPathExtension("birdcm"); try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lib.export(to: out)
        let a = try SQL(out.path, readOnly: true), d = try SQL(shared.appendingPathComponent("fixture-v1.birdcm").path, readOnly: true)
        let names = "SELECT type||':'||name FROM sqlite_master ORDER BY name"
        XCTAssertEqual(try a.rows(names).map { $0.s(0)! }, try d.rows(names).map { $0.s(0)! })
        XCTAssertEqual(try a.rows("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name").map { $0.s(0)! }, try d.rows("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name").map { $0.s(0)! })
        XCTAssertEqual(try a.rows("PRAGMA application_id")[0].n(0), 1112101441); XCTAssertEqual(try a.rows("PRAGMA journal_mode")[0].s(0), "delete")
        XCTAssertEqual(try a.rows("SELECT count(*) FROM ll_asset WHERE relative_path IS NOT NULL")[0].n(0), 0)
        XCTAssertEqual(try a.rows("SELECT value FROM archive_meta WHERE key='producer'")[0].s(0), "ios")
        XCTAssertEqual(try a.rows("SELECT count(*) FROM ll_subject WHERE count_edit=1")[0].n(0), 0)
        XCTAssertEqual(try Library(dir: tmp()).importArchive(out), 309)
        // Leave a copy for the desktop reader check (ios/build is git-ignored).
        let copy = shared.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ios/build/ios-export-fixture.birdcm")
        try? FileManager.default.removeItem(at: copy); try? FileManager.default.copyItem(at: out, to: copy)
    }
    /// Synthetic 10,000 photos / 30,000 subjects (no original bytes): timings of the browsing paths, simulator numbers.
    func testTenThousandPhotoTimings() throws {
        let dir = tmp()
        try Library(dir: dir).seedSynthetic(10_000, species: Array(Catalogue.shared.all.prefix(800).map(\.sci)))
        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let t = Date(); let v = try body(); print(String(format: "PERF %@ %.1f ms", label, Date().timeIntervalSince(t) * 1000)); return v
        }
        let lib = try time("open library") { try Library(dir: dir) }
        let items = try time("items (10k photos, 30k subjects)") { try lib.items() }
        XCTAssertEqual(items.count, 10_000)
        let ledger = time("ledger build") { Ledger(items: items, edits: [:], known: Catalogue.shared.contains) }
        let all = time("summary all") { ledger.summary(nil) }
        _ = time("summary month") { ledger.summary(Period.month(2024, 3).range) }
        _ = time("calendar month days") { ledger.days(Period.month(2024, 3).range) }
        _ = time("photos list filter 'tern'") { items.filter { i in i.subjects.contains { Catalogue.shared.name($0.key).contains("燕鸥") } } }
        _ = time("catalogue search 'tern'") { Catalogue.shared.search("tern") }
        _ = time("species page photos") { ledger.photos(of: all.list[0].id) }
        _ = time("rarity book (30k observations)") { RarityBook.compute(ledger, nil) }
        _ = time("evidence for every observation (map / eBird)") { ledger.observations.reduce(0) { $0 + ledger.evidence($1).count } }
        _ = time("eBird checklists all time") { EBird.checklists(ledger, nil, rarity: Catalogue.shared.rarity) }
        print("PERF observations \(ledger.observations.count) species \(all.species)")
        XCTAssertGreaterThan(all.observations, 1000)
    }
    /// regionAt equals the reference copy point by point: a global grid (sea, coast, borders) plus the synthetic library's points, on two databases.
    func testRegionAtMatchesReference() throws {
        var points = [(Double, Double)]()
        for lat in stride(from: -88.9, through: 88.9, by: 3.7) { for lon in stride(from: -179.3, through: 179.9, by: 3.7) { points.append((lat, lon)) } }
        points += (0..<920).map { i -> (Double, Double) in (20 + Double(i % 40) * 0.37, 100 + Double(i % 23) * 0.53) }
        for (path, minimum) in [(Models.rarityURL, 2000), (fixtures.appendingPathComponent("rarity-global-test.sqlite"), 1000)] {
            let db = try Rarity(path: path)
            var found = 0
            for (lat, lon) in points {
                let a = db.regionAt(lat: lat, lon: lon), b = referenceRegionAt(db, lat: lat, lon: lon)
                XCTAssertEqual(a.division, b.division, "\(path.lastPathComponent) \(lat),\(lon)"); XCTAssertEqual(a.country, b.country, "\(path.lastPathComponent) \(lat),\(lon)")
                if b.country != nil { found += 1 }
            }
            XCTAssertGreaterThan(found, minimum, path.lastPathComponent)
        }
    }
    /// A TEXT box value compares greater than any number in SQL (minx never <=, maxx always >=); regionAt agrees with the original SQL.
    func testRegionAtTextBoxMatchesReference() throws {
        let square = "X'00000000000000000000803F000000000000803F0000803F000000000000803F'"   // float32 ring (0,0) (1,0) (1,1) (0,1)
        for (box, expected) in [("'bad',0,1,1", nil), ("0,0,'bad',1", "XX")] as [(String, String?)] {   // minx,miny,maxx,maxy
            let path = tmp().appendingPathExtension("sqlite"); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE regions(id INTEGER PRIMARY KEY, code TEXT UNIQUE, country TEXT, level INTEGER, name_en TEXT, name_zh TEXT); CREATE TABLE shapes(region_id INTEGER, minx REAL, miny REAL, maxx REAL, maxy REAL, pts BLOB); INSERT INTO regions VALUES(1,'XX','XX',0,'X','X'); INSERT INTO shapes VALUES(1,\(box),\(square));", nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            let rarity = try Rarity(path: path)
            let a = rarity.regionAt(lat: 0.5, lon: 0.5), b = referenceRegionAt(rarity, lat: 0.5, lon: 0.5)
            XCTAssertEqual(b.country, expected, box)
            XCTAssertEqual(a.country, b.country, box); XCTAssertEqual(a.division, b.division, box)
            var s: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(rarity.db, "SELECT 9e999", -1, &s, nil), SQLITE_OK)   // the +Inf the box read relies on
            XCTAssertEqual(sqlite3_step(s), SQLITE_ROW); XCTAssertEqual(sqlite3_column_double(s, 0), .infinity); sqlite3_finalize(s)
        }
    }
}

/// Reference copy of Rarity.regionAt as of 45f524e (original SQL with the correlated area subquery), for equivalence checks.
func referenceRegionAt(_ db: Rarity, lat: Double, lon: Double) -> (division: String?, country: String?) {
    let sql = "SELECT r.code,r.level,s.pts,(SELECT sum((maxx-minx)*(maxy-miny)) FROM shapes t WHERE t.region_id=s.region_id) FROM shapes s JOIN regions r ON r.id=s.region_id WHERE minx<=? AND maxx>=? AND miny<=? AND maxy>=?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.db, sql, -1, &stmt, nil) == SQLITE_OK else { return (nil, nil) }
    defer { sqlite3_finalize(stmt) }
    for (i, v) in [lon + 0.25, lon - 0.25, lat + 0.25, lat - 0.25].enumerated() { sqlite3_bind_double(stmt, Int32(i + 1), v) }
    var rings = [String: [[Double]]](), areas = [String: Double](), levels = [String: Int]()
    while sqlite3_step(stmt) == SQLITE_ROW {
        let code = String(cString: sqlite3_column_text(stmt, 0)), n = Int(sqlite3_column_bytes(stmt, 2)) / 4
        guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
        let data = Data(bytes: blob, count: n * 4)
        let ring = data.withUnsafeBytes { raw in (0..<n).map { Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))) } }
        rings[code, default: []].append(ring); areas[code] = sqlite3_column_double(stmt, 3); levels[code] = Int(sqlite3_column_int(stmt, 1))
    }
    var hit = [Int: String](), nearest: (Double, String)?
    for code in rings.keys.sorted(by: { areas[$0]! > areas[$1]! }) {
        var inside = false
        for ring in rings[code]! { if Boundaries.inside(lon, lat, ring) { inside.toggle() } }
        if inside { hit[levels[code]!] = code }
        for ring in rings[code]! { for i in stride(from: 0, to: ring.count, by: 2) {
            let d = pow(ring[i] - lon, 2) + pow(ring[i + 1] - lat, 2)
            if d <= 0.0625 && (nearest == nil || d < nearest!.0 || (d == nearest!.0 && code < nearest!.1)) { nearest = (d, code) }
        }}
    }
    if hit.isEmpty, let nearest { hit[levels[nearest.1]!] = nearest.1 }
    if hit[1] != nil && hit[0] == nil { hit[0] = String(hit[1]!.prefix(2)) }
    return (hit[1], hit[0])
}

/// Reference copy of RarityBook.compute as of cd08823, with the Rarity.monthCounts and per-species Rarity.iucn it called inlined verbatim.
func referenceRarityBook(_ ledger: Ledger, _ range: (String, String)?) -> RarityBook {
    func monthCounts(_ db: Rarity, _ place: Place, month: Int) -> (counts: [String: (n: Int, tier: Int)], total: Int, coverage: String?)? {
        let s = db.source(place, month: month)
        guard let src = s.source else { return nil }
        var out = [String: (Int, Int)](), total = 0
        for r in db.rows("SELECT sp.scientific,c.n,c.tier FROM counts c JOIN species sp ON sp.id=c.species_id WHERE c.region_id=? AND c.month=?", [src, String(month)]) {
            let n = Int(r[1]) ?? 0; out[r[0]] = (n, Int(r[2]) ?? 0); total += n
        }
        return (out, total, s.coverage)
    }
    func iucn(_ db: Rarity, _ sci: String) -> String? {
        UserDefaults.standard.bool(forKey:"hideIUCN") ? nil : db.rows("SELECT iucn FROM species WHERE scientific=?",[sci]).first.flatMap{$0[0].isEmpty ? nil:$0[0]}
    }
    var book = RarityBook()
    guard let db = try? Rarity(path: Models.rarityURL) else { book.unavailable = Set(ledger.observations.map(\.id)); return book }
    var months = [String: [String: (n: Int, tier: Int)]?]()
    let inTable = Set(db.rows("SELECT scientific FROM species", []).map { $0[0] })
    for o in ledger.observations where Ledger.inRange(o.day, range) {
        guard let month = Int(o.day.dropFirst(5).prefix(2)), inTable.contains(o.species) else { book.unavailable.insert(o.id); continue }
        var known = [Int]()
        for item in ledger.evidence(o) {
            let r = item.lat.map { db.regionAt(lat: $0, lon: item.lon!, bucket: item.placeKey) }
            guard let code = item.region ?? r?.division ?? r?.country else { continue }
            let key = "\(code)|\(month)"
            if months[key] == nil { months[key] = .some(monthCounts(db, Place(lat: 0, lon: 0, label: "", source: "region", regionCode: code), month: month)?.counts) }
            if let table = months[key] ?? nil { known.append(table[o.species]?.tier ?? 0) }
        }
        if known.isEmpty { book.unavailable.insert(o.id) } else { book.tiers[o.id] = known }
    }
    if !UserDefaults.standard.bool(forKey: "hideIUCN") {
        for k in Set(ledger.observations.filter { Ledger.inRange($0.day, range) }.map(\.species)) { if let c = iucn(db, k) { book.iucn[k] = c } }
    }
    return book
}

extension CrossPlatformTests {
    /// Sets a UserDefaults key for this test only; the previous value (or its absence) comes back at teardown.
    func setDefault(_ key: String, _ value: Any?) {
        let old = UserDefaults.standard.object(forKey: key)
        addTeardownBlock { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    func photo(_ hash: String, _ day: String, _ species: String, lat: Double? = nil, lon: Double? = nil, region: String? = nil) -> PhotoItem {
        PhotoItem(id: UUID(), hash: hash, path: nil, missing: false, day: day, wall: day + "T08:00:00", dateSource: "photo", offset: nil, capture: day + "T08:00:00",
                  lat: lat, lon: lon, region: region, placeLabel: nil, placeSource: lat == nil ? "region" : "photo",
                  subjects: [SubjectItem(id: "s" + hash, ordinal: 0, box: [0.1, 0.1, 0.5, 0.5], crop: nil, level: "species", modelKey: species, state: "", corrected: nil, count: nil, excluded: false)])
    }
    func assertBook(_ ledger: Ledger, _ range: (String, String)?, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> RarityBook {
        let new = RarityBook.compute(ledger, range), old = referenceRarityBook(ledger, range)
        XCTAssertEqual(new.tiers, old.tiers, label, file: file, line: line)
        XCTAssertEqual(new.unavailable, old.unavailable, label, file: file, line: line)
        XCTAssertEqual(new.iucn, old.iucn, label, file: file, line: line)
        return old
    }
    /// RarityBook.compute equals the reference copy on every output (tiers in evidence order, unavailable, iucn), IUCN shown and hidden:
    /// a synthetic library of another size and species set, the desktop fixture, and hand-made observations (several evidence photos, unknown species, bad month).
    func testRarityBookMatchesReference() throws {
        let dir = tmp()
        try Library(dir: dir).seedSynthetic(4_000, species: Array(Catalogue.shared.all.dropFirst(300).prefix(250).map(\.sci)))
        let synthetic = Ledger(items: try Library(dir: dir).items(), edits: [:], known: Catalogue.shared.contains)
        let lib = try desktopLibrary()
        let desktop = Ledger(items: try lib.items(), edits: try lib.groupEdits(), known: Catalogue.shared.contains)
        // One observation with five photos at one point: explicit regions CN-SX (1), US-AK (2), the point itself (CN-BJ, 4), AS (no source: skipped), BE (3).
        let made = Ledger(items: [
            photo("h1", "2024-05-10", "Ardea alba", lat: 40.0, lon: 116.4, region: "CN-SX"), photo("h2", "2024-05-10", "Ardea alba", lat: 40.0, lon: 116.4, region: "US-AK"),
            photo("h3", "2024-05-10", "Ardea alba", lat: 40.0, lon: 116.4), photo("h4", "2024-05-10", "Ardea alba", lat: 40.0, lon: 116.4, region: "AS"),
            photo("h5", "2024-05-10", "Ardea alba", lat: 40.0, lon: 116.4, region: "BE"),
            photo("h6", "2024-05-11", "Ardea alba", region: "AS"),                        // every photo without a source: unavailable
            photo("h7", "2024-05-11", "Nonexistus fakeus", region: "CN-BJ"),               // not in the species table: unavailable
            photo("h8", "2024-05-11", "Aptenodytes forsteri", region: "CN-BJ"),            // in the table, not in this month's counts: 0
            photo("h9", "2024-xx-11", "Ardea alba", region: "CN-BJ"),                      // month not a number: unavailable
            photo("h10", "2024-05-12", "Ardea alba", region: "ZZ-QQ"),                     // unknown region, fallback to ZZ finds nothing: unavailable
            photo("h11", "2024-05-12", "Ardea alba"),                                      // no place at all: unavailable
        ])
        for hide in [false, true] {
            setDefault("hideIUCN", hide)
            for (label, ledger) in [("synthetic", synthetic), ("desktop", desktop), ("made", made)] {
                for range in [nil, ("2024-01-01", "2024-06-30")] as [(String, String)?] {
                    let old = assertBook(ledger, range, "\(label) hide \(hide) range \(range != nil)")
                    if label == "synthetic" && range == nil { XCTAssertGreaterThan(old.tiers.count, 5000); XCTAssertEqual(old.iucn.isEmpty, hide) }
                    if label == "desktop" && range == nil { XCTAssertGreaterThan(old.tiers.count, 3) }
                }
            }
            let old = referenceRarityBook(made, nil)
            XCTAssertEqual(made.observations.first { $0.day == "2024-05-10" }.flatMap { old.tiers[$0.id] }, [1, 2, 4, 3])
            XCTAssertEqual(made.observations.filter { old.unavailable.contains($0.id) }.count, 5)
            XCTAssertEqual(made.observations.first { $0.species == "Aptenodytes forsteri" }.flatMap { old.tiers[$0.id] }, [0])
        }
    }
    /// Small hand-made rarity databases (rarityPath override): a scientific name stored twice in Unicode-equivalent forms, a decomposed name looked up
    /// precomposed, a name stored as BLOB (in the table, never matches `scientific=?`), tiers stored as REAL / TEXT / out of range, NULL and empty IUCN, a counts row for a missing species, a NULL and an empty source, fallback to the country; and an unopenable path.
    func testRarityBookEdgeDatabasesMatchReference() throws {
        let pre = "Ardea \u{00E9}x", dec = "Ardea e\u{0301}x"
        let schema = "CREATE TABLE regions(id INTEGER PRIMARY KEY, code TEXT UNIQUE, country TEXT, level INTEGER, name_en TEXT, name_zh TEXT); CREATE TABLE species(id INTEGER PRIMARY KEY, scientific TEXT UNIQUE, iucn TEXT); CREATE TABLE months(region_id INTEGER, month INTEGER, records INTEGER, n_species INTEGER, source_id INTEGER, coverage TEXT, PRIMARY KEY(region_id, month)) WITHOUT ROWID; CREATE TABLE counts(region_id INTEGER, month INTEGER, species_id INTEGER, n INTEGER, tier INTEGER, PRIMARY KEY(region_id, month, species_id)) WITHOUT ROWID; INSERT INTO regions VALUES(1,'XX','XX',0,'X','X'),(2,'YY','YY',0,'Y','Y'),(3,'WW','WW',0,'W','W'); INSERT INTO months VALUES(1,5,10,5,1,'ok'),(2,5,0,0,'','none'),(3,5,0,0,NULL,'none');"
        let databases = [
            // Same name twice (Swift-equal, different bytes): only id 1 has counts, so last-wins by name would give 0, the old table gives 2; IUCN by bytes gives id 2's.
            ("duplicate", "INSERT INTO species VALUES(1,'\(dec)','LC'),(2,'\(pre)','EN'); INSERT INTO counts VALUES(1,5,1,3,2);"),
            ("duplicate mirrored", "INSERT INTO species VALUES(1,'\(dec)','LC'),(2,'\(pre)','EN'); INSERT INTO counts VALUES(1,5,2,3,2);"),   // only id 2: first-wins by name would give 0
            ("types", "INSERT INTO species VALUES(1,'\(dec)','VU'),(2,'Real tier','LC'),(3,'Text tier',NULL),(4,'Big tier',''),(5,'Plain','NT'),(6,CAST('Blob name' AS BLOB),'CR'); INSERT INTO counts VALUES(1,5,1,3,2),(1,5,2,3,3.5),(1,5,3,3,'x'),(1,5,4,3,7),(1,5,6,3,1),(1,5,99,3,1);"),
        ]
        for (label, rows) in databases {
            let path = tmp().appendingPathExtension("sqlite"); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, schema + rows, nil, nil, nil), SQLITE_OK, label)
            sqlite3_close(db)
            setDefault("rarityPath", path.path)
            var items = [PhotoItem]()
            for (i, sp) in [pre, dec, "Real tier", "Text tier", "Big tier", "Plain", "Blob name", "Absent"].enumerated() {
                for (j, region) in ["XX", "XX-A", "YY", "YY-B", "WW"].enumerated() { items.append(photo("e\(i)-\(j)", "2024-05-0\(j + 1)", sp, region: region)) }
            }
            items.append(photo("m1", "2024-05-01", "Plain", region: "XX")); items.append(photo("m2", "2024-05-01", "Plain", region: "XX-A"))   // two photos, one observation per place
            let ledger = Ledger(items: items)
            for hide in [false, true] {
                setDefault("hideIUCN", hide)
                let old = assertBook(ledger, nil, "\(label) hide \(hide)")
                XCTAssertGreaterThanOrEqual(old.tiers.count, label.hasPrefix("duplicate") ? 2 : 13, label)
            }
            setDefault("hideIUCN", false)
            let old = referenceRarityBook(ledger, nil)
            let tier = { (sp: String) in ledger.observations.first { $0.species == sp && $0.place == "r:XX" }.flatMap { old.tiers[$0.id] } }
            // The ledger itself groups the two spellings into one observation (Swift-equal keys), so XX has two photos.
            if label.hasPrefix("duplicate") { XCTAssertEqual(tier(pre), [2, 2]); XCTAssertEqual(old.iucn[pre], "EN") }
            else { XCTAssertEqual([tier(pre), tier("Real tier"), tier("Text tier"), tier("Big tier"), tier("Plain")], [[2, 2], [0], [0], [7], [0, 0]]); XCTAssertNil(old.iucn[pre]); XCTAssertEqual(old.iucn["Plain"], "NT"); XCTAssertNil(old.iucn["Text tier"]); XCTAssertNil(old.iucn["Big tier"]); XCTAssertEqual(tier("Blob name"), [1]); XCTAssertNil(old.iucn["Blob name"]) }
        }
        // species as a view whose second row's iucn fails (abs overflow): a scan reading iucn stops part way, the old scientific-only
        // reads and point lookups of other rows do not, so the whole call must take the old path.
        do {
            let path = tmp().appendingPathExtension("sqlite"); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
            let view = schema.replacingOccurrences(of: "CREATE TABLE species(id INTEGER PRIMARY KEY, scientific TEXT UNIQUE, iucn TEXT);", with: "CREATE TABLE sp0(id INTEGER PRIMARY KEY, scientific TEXT UNIQUE, iucn TEXT, bad INTEGER); CREATE VIEW species AS SELECT id, scientific, CASE WHEN bad THEN abs(-9223372036854775808) ELSE iucn END AS iucn FROM sp0;")
            XCTAssertNotEqual(view, schema)
            XCTAssertEqual(sqlite3_exec(db, view + "INSERT INTO sp0 VALUES(1,'First','LC',0),(2,'Second','NT',1),(3,'Third','VU',0); INSERT INTO counts VALUES(1,5,1,3,4),(1,5,2,3,1),(1,5,3,3,2);", nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            setDefault("rarityPath", path.path)
            let ledger = Ledger(items: ["First", "Second", "Third"].enumerated().map { photo("v\($0)", "2024-05-01", $1, region: "XX") })
            for hide in [false, true] { setDefault("hideIUCN", hide); _ = assertBook(ledger, nil, "view hide \(hide)") }
            setDefault("hideIUCN", false)
            let old = referenceRarityBook(ledger, nil)
            XCTAssertEqual(ledger.observations.sorted { $0.species < $1.species }.map { old.tiers[$0.id] }, [[4], [1], [2]])
            XCTAssertEqual(old.iucn, ["First": "LC", "Third": "VU"])
        }
        setDefault("rarityPath", tmp().appendingPathComponent("missing.sqlite").path)
        let ledger = Ledger(items: [photo("u1", "2024-05-01", "Plain", region: "XX")])
        let old = assertBook(ledger, nil, "unopenable")
        XCTAssertEqual(old.unavailable.count, 1)
    }
}
