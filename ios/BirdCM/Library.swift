import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// docs/design-lifelist.md §5: one SQLite file next to the legacy History files; originals stay files.
struct StoreError: LocalizedError { let message: String; var errorDescription: String? { message } }
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQL {
    private(set) var handle: OpaquePointer?
    init(_ path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let m = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open"; sqlite3_close(handle); handle = nil
            throw StoreError(message: m)
        }
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { sqlite3_close(handle) }
    var failure: StoreError { StoreError(message: String(cString: sqlite3_errmsg(handle))) }
    func exec(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure } }
    func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure }
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, transient)
            case let x as Int: sqlite3_bind_int64(stmt, n, Int64(x))
            case let x as Bool: sqlite3_bind_int64(stmt, n, x ? 1 : 0)
            case let x as Double: sqlite3_bind_double(stmt, n, x)
            case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), transient) }
            default: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }
    @discardableResult func run(_ sql: String, _ v: [Any?] = []) throws -> Int {
        let stmt = try prepare(sql, v); defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw failure }
        return Int(sqlite3_changes(handle))
    }
    func rows(_ sql: String, _ v: [Any?] = []) throws -> [[Any?]] {
        let stmt = try prepare(sql, v); defer { sqlite3_finalize(stmt) }
        var out = [[Any?]]()
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw failure }
            out.append((0..<sqlite3_column_count(stmt)).map { i -> Any? in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB: return sqlite3_column_blob(stmt, i).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, i))) } ?? Data()
                default: return nil
                }
            })
        }
        return out
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let v = try body(); try exec("COMMIT"); return v } catch { try? exec("ROLLBACK"); throw error }
    }
    /// Incremental BLOB I/O, ≤1 MiB per step; originals never sit in memory whole.
    func streamBlob(db: String, table: String, column: String, row: Int64, write: Bool, chunk: (inout Data, Int) throws -> Void) throws {
        var blob: OpaquePointer?
        guard sqlite3_blob_open(handle, db, table, column, row, write ? 1 : 0, &blob) == SQLITE_OK else { throw failure }
        defer { sqlite3_blob_close(blob) }
        let total = Int(sqlite3_blob_bytes(blob)); var offset = 0
        while offset < total {
            let n = min(1 << 20, total - offset)
            var buffer = Data(count: n)
            if write { try chunk(&buffer, offset) }
            let rc = buffer.withUnsafeMutableBytes { p in write ? sqlite3_blob_write(blob, p.baseAddress, Int32(n), Int32(offset)) : sqlite3_blob_read(blob, p.baseAddress, Int32(n), Int32(offset)) }
            guard rc == SQLITE_OK else { throw failure }
            if !write { try chunk(&buffer, offset) }
            offset += n
        }
    }
}
extension Array where Element == Any? {
    func s(_ i: Int) -> String? { self[i] as? String }
    func n(_ i: Int) -> Int? { self[i] as? Int }
    func f(_ i: Int) -> Double? { (self[i] as? Double) ?? (self[i] as? Int).map(Double.init) }
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Light rows for lists and statistics; no model vectors.
struct SubjectItem: Equatable {
    let id: String, ordinal: Int, box: [Double], crop: [Double]?, level: String, modelKey: String?
    let state: String, corrected: String?, count: Int?, excluded: Bool
    /// Human correction outranks the model; uncertain removes the contribution.
    var key: String? { state == "species" ? corrected : state == "uncertain" ? nil : level == "species" ? modelKey : nil }
}
struct PhotoItem: Identifiable, Equatable {
    let id: UUID, hash: String, path: String?, missing: Bool
    let day: String, wall: String, dateSource: String, offset: Int?, capture: String?
    let lat: Double?, lon: Double?, region: String?, placeLabel: String?, placeSource: String
    var subjects: [SubjectItem]
    /// Last opened on this device (最近查看) and first identification instant, both UTC ISO strings.
    var viewed: String? = nil
    var identified: String = ""
    var placeKey: String { Library.placeKey(lat: lat, lon: lon, region: region) }
    var boxes: [[Double]] { subjects.map(\.box) }
    var crops: [[Double]]? { let c = subjects.compactMap(\.crop); return c.count == subjects.count ? c : nil }
}

final class Library {
    static let ddl = """
    CREATE TABLE ll_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE ll_asset(
     hash TEXT PRIMARY KEY CHECK(length(hash)=64), byte_count INTEGER NOT NULL,
     mime TEXT NOT NULL, relative_path TEXT, width INTEGER, height INTEGER,
     shooting_json TEXT NOT NULL, missing INTEGER NOT NULL DEFAULT 0 CHECK(missing IN(0,1))
    );
    CREATE TABLE ll_record(
     id TEXT PRIMARY KEY, asset_hash TEXT NOT NULL REFERENCES ll_asset(hash),
     canonical INTEGER NOT NULL CHECK(canonical IN(0,1)),
     first_identified_utc TEXT NOT NULL, identified_utc TEXT NOT NULL, updated_utc TEXT NOT NULL,
     deleted_utc TEXT, origin TEXT NOT NULL, legacy_json TEXT,
     capture_wall TEXT, capture_offset_min INTEGER, capture_utc TEXT,
     date_precision TEXT NOT NULL CHECK(date_precision IN('second','day')),
     fallback_wall TEXT NOT NULL, fallback_offset_min INTEGER NOT NULL,
     date_source TEXT NOT NULL CHECK(date_source IN('photo','identified','identified_legacy_zone','user')),
     local_day TEXT NOT NULL, date_edit_json TEXT,
     lat REAL, lon REAL, place_label TEXT, place_source TEXT NOT NULL,
     region_code TEXT, place_edit_json TEXT,
     payload_json TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
     CHECK((lat IS NULL AND lon IS NULL) OR
           (lat BETWEEN -90 AND 90 AND lon BETWEEN -180 AND 180))
    );
    CREATE UNIQUE INDEX ll_one_photo ON ll_record(asset_hash) WHERE canonical=1;
    CREATE INDEX ll_record_day ON ll_record(local_day,asset_hash) WHERE canonical=1 AND deleted_utc IS NULL;
    CREATE TABLE ll_subject(
     id TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES ll_record(id), ordinal INTEGER NOT NULL,
     x0 REAL NOT NULL,y0 REAL NOT NULL,x1 REAL NOT NULL,y1 REAL NOT NULL,
     crop_json TEXT, model_level TEXT NOT NULL, model_key TEXT, model_json TEXT,
     correction_state TEXT NOT NULL DEFAULT 'none'
       CHECK(correction_state IN('none','species','uncertain')),
     corrected_key TEXT, corrected_utc TEXT,
     count_edit INTEGER CHECK(count_edit BETWEEN 1 AND 999998),
     excluded INTEGER NOT NULL DEFAULT 0 CHECK(excluded IN(0,1)),
     retired INTEGER NOT NULL DEFAULT 0 CHECK(retired IN(0,1)),
     needs_match INTEGER NOT NULL DEFAULT 0 CHECK(needs_match IN(0,1)),
     updated_utc TEXT NOT NULL,
     CHECK(0<=x0 AND x0<x1 AND x1<=1 AND 0<=y0 AND y0<y1 AND y1<=1),
     CHECK((correction_state='species' AND corrected_key IS NOT NULL) OR
           (correction_state!='species' AND corrected_key IS NULL))
    );
    CREATE UNIQUE INDEX ll_subject_ordinal ON ll_subject(record_id,ordinal) WHERE retired=0;
    CREATE INDEX ll_subject_record ON ll_subject(record_id);
    CREATE INDEX ll_subject_species ON ll_subject(model_key,corrected_key) WHERE retired=0 AND excluded=0;
    CREATE TABLE ll_group_edit(
     group_key TEXT PRIMARY KEY, count_edit INTEGER NOT NULL CHECK(count_edit BETWEEN 1 AND 999998),
     updated_utc TEXT NOT NULL
    );
    CREATE TABLE ll_legacy_issue(
     filename TEXT PRIMARY KEY, raw_json BLOB, photo_path TEXT, error TEXT NOT NULL
    );
    """
    /// §8: the archive holds exactly the five ll_* fact tables (no ll_meta) plus archive_meta / archive_blob.
    static var coreDDL: String { ddl.replacingOccurrences(of: "CREATE TABLE ll_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);\n", with: "") }
    static let archiveDDL = """
    CREATE TABLE archive_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE archive_blob(
     hash TEXT PRIMARY KEY REFERENCES ll_asset(hash), original BLOB NOT NULL
    );
    """
    static let applicationID = 1112101441
    static let recordColumns = "id,asset_hash,canonical,first_identified_utc,identified_utc,updated_utc,deleted_utc,origin,legacy_json,capture_wall,capture_offset_min,capture_utc,date_precision,fallback_wall,fallback_offset_min,date_source,local_day,date_edit_json,lat,lon,place_label,place_source,region_code,place_edit_json,payload_json,revision"

    let dir: URL
    private let db: SQL
    private let lock = NSRecursiveLock()
    private(set) var needsMigration = false
    var file: URL { dir.appendingPathComponent("library.sqlite") }
    init(dir: URL) throws {
        self.dir = dir
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // The old store excluded irreplaceable originals from device backup; live data is no longer excluded.
        var u = dir, values = URLResourceValues(); values.isExcludedFromBackup = false; try? u.setResourceValues(values)
        for name in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("assets").path)) ?? [] where name.hasPrefix(".staging-") {
            try? fm.removeItem(at: dir.appendingPathComponent("assets/" + name))
        }
        db = try SQL(dir.appendingPathComponent("library.sqlite").path)
        try db.exec("PRAGMA journal_mode=WAL;PRAGMA foreign_keys=ON")
        let version = try db.rows("PRAGMA user_version")[0].n(0) ?? 0
        guard version <= 1 else { throw StoreError(message: "这份记录由更新版本的观羽创建。请安装新版，当前版本不会改动它。") }
        if try db.rows("SELECT 1 FROM sqlite_master WHERE name='ll_meta'").isEmpty {
            try db.transaction {
                try db.exec(Self.ddl)
                try db.run("INSERT INTO ll_meta VALUES('format','birdcm-local-ios'),('library_id',?)", [UUID().uuidString.lowercased()])
            }
        }
        guard try db.rows("SELECT value FROM ll_meta WHERE key='format'").first?.s(0) == "birdcm-local-ios" else { throw StoreError(message: "记录库格式无法识别，未做任何改动。") }
        // Device-local UI state (最近查看): outside the archive schema, never exported, no revision or statistics change.
        try db.exec("CREATE TABLE IF NOT EXISTS ll_view(record_id TEXT PRIMARY KEY, viewed_utc TEXT NOT NULL)")
        // Reverse-geocoded names per ~1 km cell: a device-local cache, never exported.
        try db.exec("CREATE TABLE IF NOT EXISTS ll_place_name(cell TEXT PRIMARY KEY, name TEXT NOT NULL)")
        if version == 0 {
            needsMigration = legacyNames().contains { $0.hasSuffix(".json") }
            if !needsMigration { try db.exec("PRAGMA user_version=1") }
        }
    }
    private func legacyNames() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    // MARK: time and place facts
    static func utc(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }
    static func wall(_ d: Date, zone: TimeZone) -> (String, Int) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return (f.string(from: d), zone.secondsFromGMT(for: d) / 60)
    }
    /// Strict camera wall clock: valid Gregorian "yyyy-MM-dd" or "yyyy-MM-ddTHH:mm:ss" (subseconds dropped).
    static func validWall(_ s: String?) -> String? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC"); f.isLenient = false
        if s.count == 10 { f.dateFormat = "yyyy-MM-dd"; return f.date(from: s) != nil ? s : nil }
        let head = String(s.prefix(19)); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let d = f.date(from: head), f.string(from: d) == head else { return nil }
        return head
    }
    static func offsetMinutes(_ s: String?) -> Int? {
        guard let s, s.count == 6, let sign = s.first, "+-".contains(sign), let h = Int(s.dropFirst().prefix(2)), let m = Int(s.suffix(2)), s.dropFirst(3).first == ":" else { return nil }
        let v = (sign == "-" ? -1 : 1) * (h * 60 + m)
        return (-840...840).contains(v) ? v : nil
    }
    static func captureUTC(_ wall: String?, _ offset: Int?) -> String? {
        guard let wall, wall.count == 19, let offset else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: wall).map { utc($0.addingTimeInterval(Double(-offset * 60))) }
    }
    /// §3.1 explicit bins: about 1 km cells, +180° → -180°, +90° → last cell; regions by ISO code; otherwise none.
    static func placeKey(lat: Double?, lon: Double?, region: String?) -> String {
        if let lat, let lon {
            let lo = lon >= 180 ? -180 : lon
            return "p:\(min(8999, Int(floor(lat * 100)))):\(Int(floor(lo * 100)))"
        }
        return region.map { "r:" + $0 } ?? "none"
    }
    static func groupKey(_ species: String, _ day: String, _ place: String) -> String {
        let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? e.encode(["obs-v1", species, day, place])) ?? Data(), as: UTF8.self)
    }
    static var regionCodes: [String: String] = {
        var out = [String: String]()
        for p in Place.choices(query: "", recent: []) where p.regionCode != nil { out[p.label] = p.regionCode }
        return out
    }()
    private static func placeColumns(_ p: Place?) -> (Double?, Double?, String?, String, String?) {
        guard let p else { return (nil, nil, nil, "none", nil) }
        if p.source == "region" { return (nil, nil, p.label, "region", p.regionCode ?? regionCodes[p.label]) }
        return p.valid ? (p.lat, p.lon, p.label, p.source, nil) : (nil, nil, p.label, "none", nil)
    }
    private static func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try JSONEncoder().encode(v), as: UTF8.self) }

    // MARK: writes
    private func storeOriginal(_ data: Data, hash: String) throws -> String {
        let rel = "assets/\(hash).photo", final = dir.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: final.path) { return rel }
        let staging = dir.appendingPathComponent("assets/.staging-\(UUID().uuidString)")
        try data.write(to: staging, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard try Models.digest(staging) == hash else { try? FileManager.default.removeItem(at: staging); throw StoreError(message: "写入原图校验失败") }
        try FileManager.default.moveItem(at: staging, to: final)
        return rel
    }
    private func insertAsset(_ hash: String, path: String?, missing: Bool, shooting: Shooting, file: URL?) throws {
        var mime = "application/octet-stream", w: Int?, h: Int?, bytes = 0
        if let file, let src = CGImageSourceCreateWithURL(file as CFURL, nil) {
            if let t = CGImageSourceGetType(src), let m = UTType(t as String)?.preferredMIMEType { mime = m }
            let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            w = p?[kCGImagePropertyPixelWidth] as? Int; h = p?[kCGImagePropertyPixelHeight] as? Int
        }
        if let file { bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0 }
        try db.run("INSERT OR IGNORE INTO ll_asset VALUES(?,?,?,?,?,?,?,?)", [hash, bytes, mime, path, w, h, try Self.json(shooting), missing])
    }
    /// Effective date projection: user edit, else valid photo time, else frozen first-identification fallback.
    private func dateColumns(_ shooting: Shooting, edit: String?, fallback: String, legacy: Bool) -> (String?, Int?, String?, String, String, String) {
        struct Edit: Decodable { var wall: String; var offset_min: Int? }
        let e = edit.flatMap { try? JSONDecoder().decode(Edit.self, from: Data($0.utf8)) }
        let wall = e.map { Self.validWall($0.wall) } ?? Self.validWall(shooting.takenAt)
        let offset = e != nil ? e?.offset_min : Self.offsetMinutes(shooting.timeOffset)
        let source = e != nil && wall != nil ? "user" : wall != nil ? "photo" : legacy ? "identified_legacy_zone" : "identified"
        let w = wall, o = wall == nil ? nil : offset
        return (w, o, Self.captureUTC(w, o), (w?.count ?? 19) == 10 ? "day" : "second", source, String((w ?? fallback).prefix(10)))
    }
    private func writeRecord(_ r: Record, hash: String, insert: Bool, origin: String = "ios", legacy: String? = nil, now: Date, zone: TimeZone) throws {
        let id = r.id.uuidString.lowercased()
        var payload = r; payload.results = [:]; payload.subjects = nil
        if r.boxes.indices.contains(r.selected) { payload.result = nil }
        let (lat, lon, label, source, region) = Self.placeColumns(r.place)
        let stamp = Self.utc(now)
        if insert {
            let identified = Self.utc(r.date), (fw, fo) = Self.wall(r.date, zone: zone)
            let d = dateColumns(r.shooting, edit: nil, fallback: fw, legacy: legacy != nil)
            try db.run("INSERT INTO ll_record(\(Self.recordColumns)) VALUES(?,?,?,?,?,?,NULL,?,?,?,?,?,?,?,?,?,?,NULL,?,?,?,?,?,NULL,?,1)",
                       [id, hash, legacy == nil, identified, identified, stamp, origin, legacy, d.0, d.1, d.2, d.3, fw, fo, d.4, d.5, lat, lon, label, source, region, try Self.json(payload)])
        } else {
            let row = try db.rows("SELECT date_edit_json,fallback_wall,legacy_json IS NOT NULL,payload_json,place_edit_json FROM ll_record WHERE id=?", [id])[0]
            let old = row.s(3).flatMap { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
            // An explicit place change is remembered; a later re-identification cannot silently replace it.
            var placeEdit = row.s(4)
            if old?.place != r.place { placeEdit = r.place != nil && r.place != r.shooting.photoPlace ? try Self.json(r.place) : nil }
            let d = dateColumns(r.shooting, edit: row.s(0), fallback: row.s(1)!, legacy: row.n(2) == 1)
            try db.run("UPDATE ll_record SET identified_utc=?,updated_utc=?,capture_wall=?,capture_offset_min=?,capture_utc=?,date_precision=?,date_source=?,local_day=?,lat=?,lon=?,place_label=?,place_source=?,region_code=?,place_edit_json=?,payload_json=?,revision=revision+1 WHERE id=?",
                       [Self.utc(r.date), stamp, d.0, d.1, d.2, d.3, d.4, d.5, lat, lon, label, source, region, placeEdit, try Self.json(payload), id])
        }
    }
    static func modelColumns(_ id: Identification?) -> (String, String?) {
        guard let id else { return ("unclassified", nil) }
        if id.level == "species" { return id.clear == false ? ("uncertain", nil) : ("species", id.name ?? id.top5.first?.scientific) }
        if id.level == "genus" { return ("genus", id.name) }
        return ("uncertain", nil)
    }
    /// Keep subject identity: carried ID first, then one-to-one IoU ≥ 0.5 (descending, ties old ID then new index).
    private func syncSubjects(_ r: Record, now: Date, issue: String? = nil) throws {
        let rid = r.id.uuidString.lowercased(), stamp = Self.utc(now)
        let old = try db.rows("SELECT id,x0,y0,x1,y1 FROM ll_subject WHERE record_id=? AND retired=0", [rid]).map { ($0.s(0)!, [$0.f(1)!, $0.f(2)!, $0.f(3)!, $0.f(4)!]) }
        var ids = [String?](repeating: nil, count: r.boxes.count), used = Set<String>()
        for i in r.boxes.indices { if let s = r.subjects?[safe: i]?.id, old.contains(where: { $0.0 == s }), !used.contains(s) { ids[i] = s; used.insert(s) } }
        var pairs = [(Double, String, Int)]()
        for i in r.boxes.indices where ids[i] == nil && r.boxes[i].count == 4 { for o in old where !used.contains(o.0) { let v = iou(o.1, r.boxes[i]); if v >= 0.5 { pairs.append((v, o.0, i)) } } }
        for p in pairs.sorted(by: { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }) where ids[p.2] == nil && !used.contains(p.1) { ids[p.2] = p.1; used.insert(p.1) }
        // ponytail: unmatched old subjects retire (row and edits kept, not counted); explicit re-attachment UI when a detector change makes this reachable.
        try db.run("UPDATE ll_subject SET retired=1,updated_utc=? WHERE record_id=? AND retired=0 AND id NOT IN (SELECT value FROM json_each(?))", [stamp, rid, try Self.json(Array(used))])
        try db.run("UPDATE ll_subject SET ordinal=-1-ordinal WHERE record_id=? AND retired=0", [rid])
        for (i, box) in r.boxes.enumerated() {
            guard box.count == 4, 0 <= box[0], box[0] < box[2], box[2] <= 1, 0 <= box[1], box[1] < box[3], box[3] <= 1 else {
                // Invalid legacy boxes stay in the raw payload and the recovery list; never clamped into evidence.
                try db.run("INSERT OR REPLACE INTO ll_legacy_issue VALUES(?,NULL,NULL,?)", ["\(issue ?? rid)#box\(i)", "无效框 \(box)"]); continue
            }
            let model = r.results[String(i)] ?? (i == r.selected ? r.result : nil)
            let (level, key) = Self.modelColumns(model)
            let crop = try r.displayCrops?[safe: i].map { try Self.json($0) }
            if let sid = ids[i] {
                try db.run("UPDATE ll_subject SET ordinal=?,x0=?,y0=?,x1=?,y1=?,crop_json=?,updated_utc=? WHERE id=?", [i, box[0], box[1], box[2], box[3], crop, stamp, sid])
                if let model { try db.run("UPDATE ll_subject SET model_level=?,model_key=?,model_json=? WHERE id=?", [level, key, try Self.json(model), sid]) }
            } else {
                let sid = issue != nil ? Self.subjectID(r.id, i) : UUID().uuidString.lowercased()
                try db.run("INSERT INTO ll_subject(id,record_id,ordinal,x0,y0,x1,y1,crop_json,model_level,model_key,model_json,updated_utc) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                           [sid, rid, i, box[0], box[1], box[2], box[3], crop, level, key, try model.map { try Self.json($0) }, stamp])
            }
        }
    }
    /// Shared with the desktop (docs/fixtures/lifelist/README.md): first 16 bytes of SHA-256(text), byte 6 = (b6 & 0x0F) | 0x50, byte 8 = (b8 & 0x3F) | 0x80.
    static func stableUUID(_ text: String) -> String {
        var b = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString.lowercased()
    }
    /// Deterministic legacy subject UUID: stable_uuid("legacy subject/<record id>/<index>").
    static func subjectID(_ record: UUID, _ index: Int) -> String { stableUUID("legacy subject/\(record.uuidString.lowercased())/\(index)") }

    /// Identification by whole-file SHA-256: the same bytes update the same logical photo, keeping its edits and fallback date.
    @discardableResult func save(_ value: Record, data: Data? = nil, zone: TimeZone = .current, now: Date = Date()) throws -> Record {
        try locked {
            var r = value
            try db.transaction {
                var exists = try !db.rows("SELECT 1 FROM ll_record WHERE id=?", [r.id.uuidString.lowercased()]).isEmpty
                var hash = try db.rows("SELECT asset_hash FROM ll_record WHERE id=?", [r.id.uuidString.lowercased()]).first?.s(0)
                if let data {
                    let h = sha256(data); hash = h
                    if let row = try db.rows("SELECT id,place_edit_json FROM ll_record WHERE asset_hash=? AND canonical=1", [h]).first {
                        r.id = UUID(uuidString: row.s(0)!)!; exists = true
                        if let p = row.s(1), let place = try? JSONDecoder().decode(Place.self, from: Data(p.utf8)) { r.place = place }
                        if value.subjects == nil { r.subjects = nil }
                        // ponytail: reselecting a deleted photo restores its tombstoned record without a separate confirmation.
                        try db.run("UPDATE ll_record SET deleted_utc=NULL WHERE asset_hash=?", [h])
                    } else {
                        let rel = try storeOriginal(data, hash: h)
                        try insertAsset(h, path: rel, missing: false, shooting: r.shooting, file: dir.appendingPathComponent(rel))
                    }
                }
                guard let hash else { throw StoreError(message: "缺少原图，无法保存这条记录") }
                // A record imported from the desktop keeps its own payload; only the column edits (species, count, exclusion, date) apply.
                if exists, data == nil, let p = try db.rows("SELECT payload_json FROM ll_record WHERE id=?", [r.id.uuidString.lowercased()]).first?.s(0),
                   (try? JSONDecoder().decode(Record.self, from: Data(p.utf8))) == nil {
                    throw StoreError(message: "这条记录来自电脑版，在手机上只能更正鸟种、数量、排除和日期")
                }
                try writeRecord(r, hash: hash, insert: !exists, now: now, zone: zone)
                try syncSubjects(r, now: now)
            }
            return try record(r.id) ?? r
        }
    }

    // MARK: migration (§5.1): per-file transactions, resumable by record ID; verified before user_version=1.
    /// Locks per record (not for the whole run) so the app can keep reading — browsing, thumbnails, settings — meanwhile.
    func migrate(zone: TimeZone = .current, progress: (Double) -> Void = { _ in }) throws {
        do {
            let names = legacyNames(), present = Set(names), jsons = names.filter { $0.hasSuffix(".json") }
            var done = try locked { Set(try db.rows("SELECT id FROM ll_record").compactMap { $0.s(0) }) }
            let issues = try locked { Set(try db.rows("SELECT filename FROM ll_legacy_issue").compactMap { $0.s(0) }) }
            for (n, name) in jsons.enumerated() {
                progress(Double(n) / Double(jsons.count))
                if issues.contains(name) { continue }
                let raw = try Data(contentsOf: dir.appendingPathComponent(name))
                let photo = String(name.dropLast(5)) + ".photo"
                // Only content problems become recovery items; I/O failures rethrow so user_version stays 0 and the next launch retries.
                let r: Record
                do { r = try JSONDecoder().decode(Record.self, from: raw) } catch {
                    try locked { _ = try db.run("INSERT OR REPLACE INTO ll_legacy_issue VALUES(?,?,?,?)", [name, raw, present.contains(photo) ? photo : nil, String(describing: error)]) }; continue
                }
                let id = r.id.uuidString.lowercased()
                if done.contains(id) { continue }
                let has = present.contains(photo)
                let hash = has ? try Models.digest(dir.appendingPathComponent(photo)) : sha256(Data("missing legacy photo/\(id)".utf8))
                do {
                    try locked { try db.transaction {
                        try insertAsset(hash, path: has ? photo : nil, missing: !has, shooting: r.shooting, file: has ? dir.appendingPathComponent(photo) : nil)
                        try writeRecord(r, hash: hash, insert: true, legacy: String(decoding: raw, as: UTF8.self), now: r.date, zone: zone)
                        try syncSubjects(r, now: r.date, issue: name)
                    } }
                    done.insert(id)
                } catch let e as StoreError where e.message.localizedCaseInsensitiveContains("constraint") {
                    try locked { _ = try db.run("INSERT OR REPLACE INTO ll_legacy_issue VALUES(?,?,?,?)", [name, raw, has ? photo : nil, e.message]) }
                }
            }
            try locked { try db.transaction {
                // Canonical = greatest (Record.date, id); fallback date frozen from the earliest identification of those bytes.
                try db.exec("""
                UPDATE ll_record SET canonical=0;
                UPDATE ll_record SET canonical=1 WHERE NOT EXISTS (SELECT 1 FROM ll_record o WHERE o.asset_hash=ll_record.asset_hash AND (o.identified_utc>ll_record.identified_utc OR (o.identified_utc=ll_record.identified_utc AND o.id>ll_record.id)));
                UPDATE ll_record SET (first_identified_utc,fallback_wall,fallback_offset_min)=(SELECT first_identified_utc,fallback_wall,fallback_offset_min FROM ll_record e WHERE e.asset_hash=ll_record.asset_hash ORDER BY e.first_identified_utc,e.id LIMIT 1);
                UPDATE ll_record SET local_day=substr(coalesce(capture_wall,fallback_wall),1,10);
                """)
                let lower = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
                for row in try db.rows("SELECT r.id,r.asset_hash FROM ll_record r JOIN ll_asset a ON a.hash=r.asset_hash WHERE r.canonical=1 AND a.missing=0") {
                    if let name = lower[row.s(0)! + ".photo"] { try db.run("UPDATE ll_asset SET relative_path=? WHERE hash=?", [name, row.s(1)!]) }
                }
                let migrated = try db.rows("SELECT count(*) FROM ll_record WHERE legacy_json IS NOT NULL")[0].n(0)!
                let broken = try db.rows("SELECT count(*) FROM ll_legacy_issue WHERE raw_json IS NOT NULL")[0].n(0)!
                guard migrated + broken == jsons.count else { throw StoreError(message: "旧记录核对不一致：\(jsons.count) 个文件，\(migrated) 条记录，\(broken) 个待修复") }
                guard try db.rows("PRAGMA integrity_check").first?.s(0) == "ok", try db.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError(message: "记录库完整性检查失败") }
                try db.run("INSERT OR REPLACE INTO ll_meta VALUES('migrated_utc',?)", [Self.utc(Date())])
                try db.exec("PRAGMA user_version=1")
            }; needsMigration = false }
            progress(1)
        }
    }

    // MARK: reads
    func items() throws -> [PhotoItem] {
        try locked {
            var out = [PhotoItem](), index = [String: Int]()
            for row in try db.rows("""
            SELECT r.id,r.asset_hash,a.relative_path,a.missing,r.local_day,coalesce(r.capture_wall,r.fallback_wall),r.date_source,coalesce(r.capture_offset_min,CASE WHEN r.capture_wall IS NULL THEN r.fallback_offset_min END),r.lat,r.lon,r.region_code,r.place_label,r.place_source,
             s.id,s.ordinal,s.x0,s.y0,s.x1,s.y1,s.crop_json,s.model_level,s.model_key,s.correction_state,s.corrected_key,s.count_edit,s.excluded,v.viewed_utc,r.first_identified_utc
            FROM ll_record r JOIN ll_asset a ON a.hash=r.asset_hash LEFT JOIN ll_subject s ON s.record_id=r.id AND s.retired=0 AND s.needs_match=0 LEFT JOIN ll_view v ON v.record_id=r.id
            WHERE r.canonical=1 AND r.deleted_utc IS NULL ORDER BY r.local_day DESC,coalesce(r.capture_wall,r.fallback_wall) DESC,r.asset_hash,s.ordinal
            """) {
                let id = row.s(0)!
                let capture = row.s(6) == "photo" || row.s(6) == "user" ? row.s(5) : nil
                if index[id] == nil {
                    index[id] = out.count
                    out.append(PhotoItem(id: UUID(uuidString: id)!, hash: row.s(1)!, path: row.s(2), missing: row.n(3) == 1, day: row.s(4)!, wall: row.s(5)!, dateSource: row.s(6)!, offset: row.n(7), capture: capture,
                                         lat: row.f(8), lon: row.f(9), region: row.s(10), placeLabel: row.s(11), placeSource: row.s(12)!, subjects: [], viewed: row.s(26), identified: row.s(27) ?? ""))
                }
                guard let sid = row.s(13) else { continue }
                let crop = row.s(19).flatMap { try? JSONDecoder().decode([Double].self, from: Data($0.utf8)) }
                out[index[id]!].subjects.append(SubjectItem(id: sid, ordinal: row.n(14)!, box: [row.f(15)!, row.f(16)!, row.f(17)!, row.f(18)!], crop: crop, level: row.s(20)!, modelKey: row.s(21),
                                                            state: row.s(22)!, corrected: row.s(23), count: row.n(24), excluded: row.n(25) == 1))
            }
            return out
        }
    }
    /// 最近查看 (owner 2026-11-18): last opened first; never opened → first identification; then capture time.
    static func recentFirst(_ items: [PhotoItem]) -> [PhotoItem] {
        items.sorted { a, b in
            let x = a.viewed ?? a.identified, y = b.viewed ?? b.identified
            return x != y ? x > y : a.wall > b.wall
        }
    }
    func placeNames() -> [String: String] {
        (try? locked { Dictionary(try db.rows("SELECT cell,name FROM ll_place_name").map { ($0.s(0)!, $0.s(1)!) }, uniquingKeysWith: { a, _ in a }) }) ?? [:]
    }
    func setPlaceName(_ cell: String, _ name: String) throws {
        _ = try locked { try db.run("INSERT OR REPLACE INTO ll_place_name VALUES(?,?)", [cell, name]) }
    }
    /// Opening or identifying a photo counts as viewing it. Returns the stored instant.
    @discardableResult func markViewed(_ id: UUID, now: Date = Date()) throws -> String {
        let stamp = Self.utc(now)
        _ = try locked { try db.run("INSERT OR REPLACE INTO ll_view VALUES(?,?)", [id.uuidString.lowercased(), stamp]) }
        return stamp
    }
    @discardableResult func query(_ sql: String, _ v: [Any?] = []) throws -> [[Any?]] { try locked { try db.rows(sql, v) } }
    func groupEdits() throws -> [String: Int] {
        try locked { Dictionary(uniqueKeysWithValues: try db.rows("SELECT group_key,count_edit FROM ll_group_edit").map { ($0.s(0)!, $0.n(1)!) }) }
    }
    /// Full compatibility Record: payload overlaid with authoritative subject rows (boxes, cached results, edits).
    func record(_ id: UUID) throws -> Record? {
        try locked {
            guard let row = try db.rows("SELECT payload_json,capture_wall,lat,lon,place_label,place_source,region_code,first_identified_utc FROM ll_record WHERE id=?", [id.uuidString.lowercased()]).first else { return nil }
            let subjects = try db.rows("SELECT id,x0,y0,x1,y1,crop_json,model_json,correction_state,corrected_key,count_edit,excluded,model_level,model_key FROM ll_subject WHERE record_id=? AND retired=0 AND needs_match=0 ORDER BY ordinal", [id.uuidString.lowercased()])
            var r: Record
            if let decoded = try? JSONDecoder().decode(Record.self, from: Data(row.s(0)!.utf8)) { r = decoded } else {
                // A record imported from the desktop keeps its own payload; view it through the authoritative columns.
                var shooting = Shooting(data: Data()); shooting.takenAt = row.s(1)
                let place = row.f(2).map { Place(lat: $0, lon: row.f(3)!, label: row.s(4) ?? "", source: row.s(5) ?? "map") }
                    ?? row.s(6).map { Place(lat: 0, lon: 0, label: row.s(4) ?? $0, source: "region", regionCode: $0) }
                r = Record(boxes: [], selected: 0, shooting: shooting, place: place)
                r.date = ISO8601DateFormatter().date(from: String(row.s(7)!.prefix(19)) + "Z") ?? Date()
                for (i, s) in subjects.enumerated() where s.s(6) != nil {
                    let level = s.s(11)!, key = s.s(12)
                    r.results[String(i)] = Identification(top5: key.map { [Candidate(scientific: $0, english: "", chinese: "", p: 0)] } ?? [], level: level == "unclassified" ? "uncertain" : level, name: key, clear: true)
                }
            }
            r.boxes = subjects.map { [$0.f(1)!, $0.f(2)!, $0.f(3)!, $0.f(4)!] }
            let crops = subjects.compactMap { $0.s(5).flatMap { try? JSONDecoder().decode([Double].self, from: Data($0.utf8)) } }
            r.displayCrops = crops.count == subjects.count && !crops.isEmpty ? crops : r.displayCrops.flatMap { $0.count == subjects.count ? $0 : nil }
            for (i, s) in subjects.enumerated() { if let m = s.s(6), let v = try? JSONDecoder().decode(Identification.self, from: Data(m.utf8)) { r.results[String(i)] = v } }
            if let selected = r.results[String(r.selected)] { r.result = selected } else if r.boxes.indices.contains(r.selected) { r.result = nil }
            r.subjects = subjects.map { SubjectEdit(id: $0.s(0)!, state: $0.s(7)!, key: $0.s(8), count: $0.n(9), excluded: $0.n(10) == 1) }
            return r
        }
    }
    func url(_ id: UUID) -> URL? {
        (try? locked { try db.rows("SELECT a.relative_path FROM ll_record r JOIN ll_asset a ON a.hash=r.asset_hash WHERE r.id=?", [id.uuidString.lowercased()]).first?.s(0) }).flatMap { $0 }.map { dir.appendingPathComponent($0) }
    }
    func aliases(_ id: UUID) -> Int {
        (try? locked { try db.rows("SELECT count(*)-1 FROM ll_record WHERE asset_hash=(SELECT asset_hash FROM ll_record WHERE id=?)", [id.uuidString.lowercased()]).first?.n(0) }).flatMap { $0 } ?? 0
    }
    func issues() -> [(String, String)] {
        (try? locked { try db.rows("SELECT filename,error FROM ll_legacy_issue ORDER BY filename").map { ($0.s(0)!, $0.s(1)!) } }) ?? []
    }
    /// Legacy JSON sidecars whose exact bytes are already inside the verified library (record legacy_json or recovery raw_json).
    /// Removing them never touches an original photo.
    /// Matched by record id (file name) or recovery file name, then compared byte for byte; call off the main actor.
    func redundantLegacyFiles() -> [URL] {
        guard (try? query("PRAGMA user_version").first?.n(0)) == 1 else { return [] }
        return legacyNames().filter { $0.hasSuffix(".json") }.compactMap { name -> URL? in
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let id = String(name.dropLast(5)).lowercased()
            let stored = (try? query("SELECT legacy_json FROM ll_record WHERE id=?", [id]).first?.s(0)).flatMap { $0 }.map { Data($0.utf8) }
                ?? (try? query("SELECT raw_json FROM ll_legacy_issue WHERE filename=?", [name]).first?[0] as? Data).flatMap { $0 }
            return stored == data ? url : nil
        }
    }
    func storageBytes() -> Int {
        let fm = FileManager.default
        return (fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)) ?? 0
    }

    // MARK: edits; each bumps the photo's revision.
    private func touch(subject: String, now: Date) throws {
        try db.run("UPDATE ll_record SET revision=revision+1,updated_utc=? WHERE id=(SELECT record_id FROM ll_subject WHERE id=?)", [Self.utc(now), subject])
    }
    private func editSubject(_ subject: String, _ sql: String, _ values: [Any?], now: Date) throws {
        try locked {
            try db.transaction {
                guard try db.run("UPDATE ll_subject SET \(sql),updated_utc=? WHERE id=? AND retired=0", values + [Self.utc(now), subject]) == 1 else { throw StoreError(message: "找不到这个主体，请重新打开记录") }
                try touch(subject: subject, now: now)
            }
        }
    }
    /// state: species (exact catalogue key) / uncertain / none (= restore the model's answer; never re-runs the model).
    func correct(_ subject: String, state: String, key: String? = nil, now: Date = Date()) throws {
        guard ["species", "uncertain", "none"].contains(state), (state == "species") == (key != nil) else { throw StoreError(message: "更正无效") }
        try editSubject(subject, "correction_state=?,corrected_key=?,corrected_utc=?", [state, key, state == "none" ? nil : Self.utc(now)], now: now)
    }
    func setCount(_ subject: String, _ n: Int?, now: Date = Date()) throws {
        guard n.map({ (1...999998).contains($0) }) ?? true else { throw StoreError(message: "数量须为 1–999998") }
        // 1 is the automatic estimate; stored as no edit (shared archive convention).
        try editSubject(subject, "count_edit=?", [n == 1 ? nil : n], now: now)
    }
    func exclude(_ subject: String, _ on: Bool, now: Date = Date()) throws { try editSubject(subject, "excluded=?", [on], now: now) }
    /// wall nil resets to photo metadata / the frozen fallback. Affects the whole logical photo.
    func setDate(_ id: UUID, wall: String?, offset: Int?, now: Date = Date()) throws {
        if let wall { guard Self.validWall(wall) == wall else { throw StoreError(message: "日期无效") } }
        guard offset.map({ (-840...840).contains($0) }) ?? true else { throw StoreError(message: "时区无效") }
        try locked {
            try db.transaction {
                let rid = id.uuidString.lowercased()
                guard let row = try db.rows("SELECT payload_json,fallback_wall,legacy_json IS NOT NULL FROM ll_record WHERE id=?", [rid]).first, let r = try? JSONDecoder().decode(Record.self, from: Data(row.s(0)!.utf8)) else { throw StoreError(message: "找不到记录") }
                let edit = try wall.map { w -> String in
                    struct E: Encodable { let wall: String; let offset_min: Int? }
                    return try Self.json(E(wall: w, offset_min: offset))
                }
                let d = dateColumns(r.shooting, edit: edit, fallback: row.s(1)!, legacy: row.n(2) == 1)
                try db.run("UPDATE ll_record SET date_edit_json=?,capture_wall=?,capture_offset_min=?,capture_utc=?,date_precision=?,date_source=?,local_day=?,revision=revision+1,updated_utc=? WHERE id=?",
                           [edit, d.0, d.1, d.2, d.3, d.4, d.5, Self.utc(now), rid])
            }
        }
    }
    func setGroupCount(_ key: String, _ n: Int?, now: Date = Date()) throws {
        guard n.map({ (1...999998).contains($0) }) ?? true else { throw StoreError(message: "数量须为 1–999998") }
        _ = try locked {
            if let n { try db.run("INSERT OR REPLACE INTO ll_group_edit VALUES(?,?,?)", [key, n, Self.utc(now)]) } else { try db.run("DELETE FROM ll_group_edit WHERE group_key=?", [key]) }
        }
    }
    /// Tombstones the photo and all byte-identical aliases; originals on disk/in Photos are untouched.
    func delete(_ id: UUID, now: Date = Date()) throws {
        _ = try locked {
            try db.run("UPDATE ll_record SET deleted_utc=?,revision=revision+1,updated_utc=? WHERE deleted_utc IS NULL AND asset_hash=(SELECT asset_hash FROM ll_record WHERE id=?)", [Self.utc(now), Self.utc(now), id.uuidString.lowercased()])
        }
    }
    func deleteAll(now: Date = Date()) throws {
        _ = try locked { try db.run("UPDATE ll_record SET deleted_utc=?,revision=revision+1,updated_utc=? WHERE deleted_utc IS NULL", [Self.utc(now), Self.utc(now)]) }
    }

    // MARK: portable archive (§8): SQLite file, exact tables, originals once per hash.
    static func expectedSchema() throws -> [String: String] {
        let m = try SQL(":memory:"); try m.exec(coreDDL + archiveDDL)
        return Dictionary(uniqueKeysWithValues: try m.rows("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL").map { ($0.s(0)!, $0.s(1)!) })
    }
    func export(to url: URL, now: Date = Date()) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        do {
            try SQL(url.path).exec("PRAGMA journal_mode=DELETE;PRAGMA application_id=\(Self.applicationID);PRAGMA user_version=1;" + Self.coreDDL + Self.archiveDDL)
            // A separate read connection: one consistent snapshot of the live WAL database, never a file copy.
            let reader = try SQL(file.path)
            try reader.run("ATTACH DATABASE ? AS a", [url.path])
            try reader.exec("BEGIN")
            try reader.exec("""
            INSERT INTO a.ll_asset SELECT hash,byte_count,mime,NULL,width,height,shooting_json,missing FROM main.ll_asset;
            INSERT INTO a.ll_record SELECT * FROM main.ll_record;
            INSERT INTO a.ll_subject SELECT * FROM main.ll_subject;
            INSERT INTO a.ll_group_edit SELECT * FROM main.ll_group_edit;
            INSERT INTO a.ll_legacy_issue SELECT * FROM main.ll_legacy_issue;
            """)
            for row in try reader.rows("SELECT hash,relative_path,byte_count FROM main.ll_asset WHERE missing=0") {
                let hash = row.s(0)!, file = dir.appendingPathComponent(row.s(1) ?? "")
                guard let handle = try? FileHandle(forReadingFrom: file) else { throw StoreError(message: "原图缺失：\(hash.prefix(12))") }
                defer { try? handle.close() }
                try reader.run("INSERT INTO a.archive_blob VALUES(?,zeroblob(?))", [hash, row.n(2)!])
                var digest = SHA256()
                try reader.streamBlob(db: "a", table: "archive_blob", column: "original", row: sqlite3_last_insert_rowid(reader.handle), write: true) { buffer, _ in
                    let part = try handle.read(upToCount: buffer.count) ?? Data()
                    guard part.count == buffer.count else { throw StoreError(message: "原图大小变化：\(hash.prefix(12))") }
                    buffer = part; digest.update(data: part)
                }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw StoreError(message: "原图校验失败：\(hash.prefix(12))") }
            }
            let counts = try reader.rows("SELECT (SELECT count(*) FROM a.ll_record),(SELECT count(*) FROM a.ll_asset),(SELECT count(*) FROM a.ll_subject),(SELECT value FROM main.ll_meta WHERE key='library_id')")[0]
            let meta: [(String, String)] = [("format", "birdcm-archive"), ("version", "1"), ("archive_id", UUID().uuidString.lowercased()), ("library_id", counts.s(3) ?? ""), ("created_utc", Self.utc(now)), ("producer", "ios"), ("taxonomy", "avilist-2026"), ("scope", "full"),
                                            ("record_count", "\(counts.n(0)!)"), ("asset_count", "\(counts.n(1)!)"), ("subject_count", "\(counts.n(2)!)"), ("resource_versions", Catalogue.resourceVersions)]
            for (k, v) in meta { try reader.run("INSERT INTO a.archive_meta VALUES(?,?)", [k, v]) }
            try reader.exec("COMMIT;DETACH DATABASE a")
            _ = try Self.inspect(url)
        } catch { try? fm.removeItem(at: url); throw error }
    }
    struct ArchiveInfo { var records = 0, photos = 0, subjects = 0, bytes = 0, created = "" }
    /// Read-only validation before anything touches the library: exact schema text, integrity, every original's SHA and size.
    static func inspect(_ url: URL) throws -> ArchiveInfo {
        let a = try SQL(url.path, readOnly: true)
        try? a.exec("PRAGMA trusted_schema=OFF")
        guard try a.rows("PRAGMA application_id").first?.n(0) == applicationID, try a.rows("PRAGMA user_version").first?.n(0) == 1 else { throw StoreError(message: "不是观羽备份文件，或版本过新") }
        let expected = try expectedSchema()
        let found = try a.rows("SELECT name,sql,type FROM sqlite_master")
        for row in found where !(row.s(0)!.hasPrefix("sqlite_autoindex_") && row.s(1) == nil) {
            guard expected[row.s(0)!] == row.s(1) else { throw StoreError(message: "备份文件含有未知结构：\(row.s(0)!)") }
        }
        guard Set(found.compactMap { $0.s(0) }).isSuperset(of: expected.keys) else { throw StoreError(message: "备份文件缺少数据表") }
        guard try a.rows("PRAGMA integrity_check").first?.s(0) == "ok", try a.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError(message: "备份文件已损坏") }
        let meta = Dictionary(uniqueKeysWithValues: try a.rows("SELECT key,value FROM archive_meta").map { ($0.s(0)!, $0.s(1)!) })
        guard meta["format"] == "birdcm-archive", meta["version"] == "1" else { throw StoreError(message: "备份格式无法识别") }
        guard try a.rows("SELECT 1 FROM ll_asset s LEFT JOIN archive_blob b ON b.hash=s.hash WHERE (s.missing=0) != (b.hash IS NOT NULL)").isEmpty else { throw StoreError(message: "备份中的原图与清单不符") }
        var info = ArchiveInfo(created: meta["created_utc"] ?? "")
        for row in try a.rows("SELECT b.rowid,b.hash,s.byte_count FROM archive_blob b JOIN ll_asset s ON s.hash=b.hash") {
            var digest = SHA256(), size = 0
            try a.streamBlob(db: "main", table: "archive_blob", column: "original", row: Int64(row.n(0)!), write: false) { buffer, _ in digest.update(data: buffer); size += buffer.count }
            guard size == row.n(2)!, digest.finalize().map({ String(format: "%02x", $0) }).joined() == row.s(1)! else { throw StoreError(message: "备份中的原图校验失败") }
            info.bytes += size
        }
        let c = try a.rows("SELECT (SELECT count(*) FROM ll_record WHERE canonical=1 AND deleted_utc IS NULL),(SELECT count(*) FROM ll_asset),(SELECT count(*) FROM ll_subject)")[0]
        info.records = c.n(0)!; info.photos = c.n(1)!; info.subjects = c.n(2)!
        return info
    }
    /// Merge keeps every local record and edit; same bytes become an alias, counted once. Restore replaces the library after a safety export.
    @discardableResult func importArchive(_ url: URL, restore: Bool = false) throws -> Int {
        _ = try Self.inspect(url)
        return try locked {
            if restore { try export(to: dir.appendingPathComponent("safety-before-restore.birdcm")) }
            let a = try SQL(url.path, readOnly: true)
            var written = [URL]()
            do {
                for row in try a.rows("SELECT rowid,hash FROM archive_blob") {
                    let hash = row.s(1)!, final = dir.appendingPathComponent("assets/\(hash).photo")
                    if FileManager.default.fileExists(atPath: final.path) { continue }
                    let staging = dir.appendingPathComponent("assets/.staging-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    let handle = try FileHandle(forWritingTo: staging)
                    try a.streamBlob(db: "main", table: "archive_blob", column: "original", row: Int64(row.n(0)!), write: false) { buffer, _ in try handle.write(contentsOf: buffer) }
                    try handle.close()
                    guard try Models.digest(staging) == hash else { throw StoreError(message: "写入原图校验失败") }
                    try FileManager.default.moveItem(at: staging, to: final); written.append(final)
                }
                try db.run("ATTACH DATABASE ? AS a", [url.path])
                defer { try? db.exec("DETACH DATABASE a") }
                let columns = Self.recordColumns.replacingOccurrences(of: "canonical,", with: "CASE WHEN canonical=1 AND EXISTS(SELECT 1 FROM main.ll_record m WHERE m.asset_hash=x.asset_hash AND m.canonical=1) THEN 0 ELSE canonical END,")
                return try db.transaction {
                    if restore { try db.exec("DELETE FROM ll_subject;DELETE FROM ll_record;DELETE FROM ll_group_edit;DELETE FROM ll_legacy_issue;DELETE FROM ll_asset") }
                    try db.exec("""
                    INSERT OR IGNORE INTO main.ll_asset SELECT hash,byte_count,mime,CASE WHEN missing=0 THEN 'assets/'||hash||'.photo' END,width,height,shooting_json,missing FROM a.ll_asset;
                    DROP TABLE IF EXISTS temp.fresh;
                    CREATE TEMP TABLE fresh AS SELECT id FROM a.ll_record WHERE id NOT IN (SELECT id FROM main.ll_record);
                    INSERT INTO main.ll_record(\(Self.recordColumns)) SELECT \(columns) FROM a.ll_record x WHERE id IN (SELECT id FROM temp.fresh);
                    INSERT INTO main.ll_subject SELECT * FROM a.ll_subject WHERE record_id IN (SELECT id FROM temp.fresh) AND id NOT IN (SELECT id FROM main.ll_subject);
                    INSERT OR IGNORE INTO main.ll_group_edit SELECT * FROM a.ll_group_edit;
                    INSERT OR IGNORE INTO main.ll_legacy_issue SELECT * FROM a.ll_legacy_issue;
                    """)
                    let added = try db.rows("SELECT count(*) FROM temp.fresh")[0].n(0)!
                    try db.exec("DROP TABLE temp.fresh")
                    guard try db.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError(message: "导入后引用不一致，已撤销") }
                    return added
                }
            } catch {
                for u in written { try? FileManager.default.removeItem(at: u) }
                throw error
            }
        }
    }
    #if DEBUG
    /// Synthetic library for performance measurement: n photos × 3 subjects, invented days/points; no original bytes,
    /// or every record pointing at one copy of `photo` (thumbnail memory with real 12 MP decodes).
    func seedSynthetic(_ n: Int, species: [String], photo: URL? = nil) throws {
        if let photo { try? FileManager.default.removeItem(at: dir.appendingPathComponent("synthetic.photo")); try FileManager.default.copyItem(at: photo, to: dir.appendingPathComponent("synthetic.photo")) }
        try locked {
            try db.transaction {
                let stamp = Self.utc(Date()), start = Date(timeIntervalSince1970: 1_700_000_000)
                for i in 0..<n {
                    let hash = sha256(Data("synthetic photo \(i)".utf8)), id = Self.stableUUID("synthetic record/\(i)")
                    let wall = Self.wall(start.addingTimeInterval(Double(i % 900) * 86400 + Double(i % 600) * 60), zone: TimeZone(identifier: "UTC")!).0
                    let lat = 20 + Double(i % 40) * 0.37, lon = 100 + Double(i % 23) * 0.53
                    try db.run("INSERT OR IGNORE INTO ll_asset VALUES(?,0,'image/jpeg',?,NULL,NULL,'{}',0)", [hash, photo == nil ? nil : "synthetic.photo"])
                    try db.run("INSERT INTO ll_record(\(Self.recordColumns)) VALUES(?,?,1,?,?,?,NULL,'ios',NULL,?,0,NULL,'second',?,0,'photo',?,NULL,?,?,'Synthetic','map',NULL,NULL,'{}',1)",
                               [id, hash, stamp, stamp, stamp, wall, wall, String(wall.prefix(10)), lat, lon])
                    for k in 0..<3 {
                        try db.run("INSERT INTO ll_subject(id,record_id,ordinal,x0,y0,x1,y1,model_level,model_key,updated_utc) VALUES(?,?,?,?,0.1,?,0.5,'species',?,?)",
                                   [Self.stableUUID("synthetic subject/\(i)/\(k)"), id, k, 0.05 + 0.3 * Double(k), 0.3 + 0.3 * Double(k), species[(i * 7 + k * 13) % species.count], stamp])
                    }
                }
            }
        }
    }
    #endif
    /// Raw-fact snapshot for round-trip assertions (paths excluded: they are not facts).
    func snapshot() throws -> [String] {
        try locked {
            var out = [String]()
            for sql in ["SELECT hash,byte_count,mime,width,height,shooting_json,missing FROM ll_asset ORDER BY hash", "SELECT \(Self.recordColumns) FROM ll_record ORDER BY id", "SELECT * FROM ll_subject ORDER BY id", "SELECT * FROM ll_group_edit ORDER BY group_key", "SELECT * FROM ll_legacy_issue ORDER BY filename"] {
                out += try db.rows(sql).map { $0.map { "\($0 ?? "∅")" }.joined(separator: "|") }
            }
            return out
        }
    }
}
