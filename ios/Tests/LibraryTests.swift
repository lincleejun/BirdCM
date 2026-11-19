import XCTest
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
}
