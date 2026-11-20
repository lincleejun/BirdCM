import Foundation
import SQLite3

struct RarityValue: Codable { var label: String; var iucn: String?; var region: String? }
final class Rarity {
    var db: OpaquePointer?
    init(path: URL) throws {
        guard sqlite3_open_v2(path.path,&db,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { sqlite3_close(db); db=nil; throw CocoaError(.fileReadCorruptFile) }
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ values: [String]) -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i,v) in values.enumerated() { _ = v.withCString { sqlite3_bind_text(stmt,Int32(i+1),$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) } }
        var out = [[String]]()
        while sqlite3_step(stmt) == SQLITE_ROW { out.append((0..<sqlite3_column_count(stmt)).map { sqlite3_column_text(stmt,$0).map{String(cString:$0)} ?? "" }) }
        return out
    }
    static func tier(count: Int, total: Int) -> Int {
        if count == 0 { return 0 }; if count < 5 { return 1 }
        let p = Double(count)/Double(max(total,1))
        return p >= 0.002 ? 4 : p >= 0.0002 ? 3 : p >= 0.00002 ? 2 : 1
    }
    private static var regionCache = [String: (division: String?, country: String?)]()
    private static let regionLock = NSLock()
    /// regionAt cached per place bucket (≈1 km cell); statistics and eBird ask for the same few points thousands of times.
    func regionAt(lat: Double, lon: Double, bucket: String) -> (division: String?, country: String?) {
        Self.regionLock.lock(); if let hit = Self.regionCache[bucket] { Self.regionLock.unlock(); return hit }; Self.regionLock.unlock()
        let value = regionAt(lat: lat, lon: lon)
        Self.regionLock.lock(); Self.regionCache[bucket] = value; Self.regionLock.unlock()
        return value
    }
    private var areaCache = [Int64: Double]()
    private let areaLock = NSLock()
    /// Summed bounding-box area of one region's shapes, the same SQLite expression the lookup used inline; once per region per instance.
    /// nil when the query fails (not cached), as the old inline subquery failing gave no region at all.
    private func area(_ id: Int64) -> Double? {
        areaLock.lock(); if let hit = areaCache[id] { areaLock.unlock(); return hit }; areaLock.unlock()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT sum((maxx-minx)*(maxy-miny)) FROM shapes WHERE region_id=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let value = sqlite3_column_double(stmt, 0)
        areaLock.lock(); areaCache[id] = value; areaLock.unlock()
        return value
    }
    private var boxCache: [(id: Int64, minx: Double, maxx: Double, miny: Double, maxy: Double)]?
    private let boxLock = NSLock()
    /// Every shape's rowid and bounding box, read once per instance (NULL boxes never match in SQL, so they are left out;
    /// TEXT/BLOB values compare above every number in SQL, so they are read as +Inf). nil when the read fails part way; nothing is kept and the next call reads again.
    private func boxes() -> [(id: Int64, minx: Double, maxx: Double, miny: Double, maxy: Double)]? {
        boxLock.lock(); if let hit = boxCache { boxLock.unlock(); return hit }; boxLock.unlock()
        var stmt: OpaquePointer?
        let col = { (c: String) in "CASE WHEN typeof(\(c)) IN ('text','blob') THEN 9e999 ELSE \(c) END" }
        guard sqlite3_prepare_v2(db, "SELECT rowid,\(["minx", "maxx", "miny", "maxy"].map(col).joined(separator: ",")) FROM shapes WHERE minx IS NOT NULL AND maxx IS NOT NULL AND miny IS NOT NULL AND maxy IS NOT NULL", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out = [(id: Int64, minx: Double, maxx: Double, miny: Double, maxy: Double)]()
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1), sqlite3_column_double(stmt, 2), sqlite3_column_double(stmt, 3), sqlite3_column_double(stmt, 4)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { return nil }
        boxLock.lock(); if boxCache == nil { boxCache = out }; let value = boxCache!; boxLock.unlock()
        return value
    }
    private typealias ShapeRow = (code: String, level: Int, region: Int64, ring: [Double])
    private var shapeCache = [Int64: [ShapeRow]]()
    private let shapeLock = NSLock()
    /// Port of rarity_global.region_at: ISO codes, even/odd rings, smallest area wins, 0.25° coastal tolerance.
    /// Each shape row is read and decoded once per instance (shapeCache, by rowid: its one joined row, or none when the blob is NULL
    /// or its region_id is not in regions); area() is still asked row by row on every call, as before.
    func regionAt(lat:Double,lon:Double) -> (division:String?,country:String?) {
        // Same box test as the former SQL (minx<=lon+0.25 AND maxx>=lon-0.25 AND miny<=lat+0.25 AND maxy>=lat-0.25), done in memory; only the hits are read.
        guard let boxes=boxes() else {return (nil,nil)}
        let x1=lon+0.25, x0=lon-0.25, y1=lat+0.25, y0=lat-0.25
        let ids=boxes.filter {$0.minx<=x1 && $0.maxx>=x0 && $0.miny<=y1 && $0.maxy>=y0}.map(\.id)
        guard !ids.isEmpty else {return (nil,nil)}
        shapeLock.lock(); let cached=shapeCache; shapeLock.unlock()
        let missing=ids.filter {cached.index(forKey:$0)==nil}
        var fetched=[Int64:[ShapeRow]]()
        if !missing.isEmpty {
            var stmt:OpaquePointer?
            let sql="SELECT r.code,r.level,s.pts,s.region_id,s.rowid FROM shapes s JOIN regions r ON r.id=s.region_id WHERE s.rowid IN (\(missing.map {String($0)}.joined(separator:",")))"
            guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else {return (nil,nil)}
            defer{sqlite3_finalize(stmt)}
            var rc=sqlite3_step(stmt)
            while rc==SQLITE_ROW {
                let code=String(cString:sqlite3_column_text(stmt,0)), n=Int(sqlite3_column_bytes(stmt,2))/4, id=sqlite3_column_int64(stmt,4)
                var row=[ShapeRow]()   // NULL (or empty) blob: no row, skipped as before
                if let blob=sqlite3_column_blob(stmt,2) {
                    let data=Data(bytes:blob,count:n*4)
                    let ring=data.withUnsafeBytes {raw in (0..<n).map {Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self))))}}
                    // area() when the row is read, as the old loop did: a failure stops here, before any later row (none kept or marked).
                    guard area(sqlite3_column_int64(stmt,3)) != nil else {return (nil,nil)}
                    row=[(code,Int(sqlite3_column_int(stmt,1)),sqlite3_column_int64(stmt,3),ring)]
                }
                fetched[id]=row
                rc=sqlite3_step(stmt)
            }
            // Only a complete read proves a missing rowid has no row (region_id not in regions); after a step error it is read again next time.
            if rc==SQLITE_DONE {for id in missing where fetched.index(forKey:id)==nil {fetched[id]=[]}}
            shapeLock.lock(); shapeCache.merge(fetched) {old,_ in old}; shapeLock.unlock()
        }
        var rings=[String:[[Double]]](), areas=[String:Double](), levels=[String:Int]()
        for id in ids {
            for shape in cached[id] ?? fetched[id] ?? [] {   // not read (step error part way): left out this time, as the old loop did
                guard let area=area(shape.region) else {return (nil,nil)}
                rings[shape.code,default:[]].append(shape.ring);areas[shape.code]=area;levels[shape.code]=shape.level
            }
        }
        var hit=[Int:String](), nearest:(Double,String)?
        for code in rings.keys.sorted(by:{areas[$0]! > areas[$1]!}) {
            var inside=false
            for ring in rings[code]! {if Boundaries.inside(lon,lat,ring) {inside.toggle()}}
            if inside {hit[levels[code]!]=code}
            for ring in rings[code]! {for i in stride(from:0,to:ring.count,by:2) {
                let d=pow(ring[i]-lon,2)+pow(ring[i+1]-lat,2)
                if d <= 0.0625 && (nearest == nil || d < nearest!.0 || (d == nearest!.0 && code < nearest!.1)) {nearest=(d,code)}
            }}
        }
        if hit.isEmpty,let nearest {hit[levels[nearest.1]!]=nearest.1}
        if hit[1] != nil && hit[0] == nil {hit[0]=String(hit[1]!.prefix(2))}
        return (hit[1],hit[0])
    }
    /// Country outlines (level-0 rings, flat lon/lat pairs) for the species page's offline range map.
    func countryRings() -> [[Float]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT s.pts FROM shapes s JOIN regions r ON r.id=s.region_id WHERE r.level=0", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out = [[Float]]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(stmt, 0)) / 4
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            out.append((0..<n).map { Float(bitPattern: UInt32(littleEndian: blob.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) })
        }
        return out
    }
    /// The region code for a place (explicit region choice first, else the point lookup), and the month's GBIF source region.
    func source(_ place: Place, month: Int) -> (code: String?, source: String?, coverage: String?) {
        let point: (division: String?, country: String?) = place.regionCode == nil ? regionAt(lat: place.lat, lon: place.lon) : (nil, nil)
        guard let code = place.regionCode ?? point.division ?? point.country else { return (nil, nil, nil) }
        var row = rows("SELECT m.source_id,m.coverage FROM months m JOIN regions r ON r.id=m.region_id WHERE r.code=? AND m.month=?", [code, String(month)]).first
        if row == nil && code.contains("-") { row = rows("SELECT m.source_id,m.coverage FROM months m JOIN regions r ON r.id=m.region_id WHERE r.code=? AND m.month=?", [String(code.prefix(2)), String(month)]).first }
        return (code, row.flatMap { $0[0].isEmpty ? nil : $0[0] }, row?[1])
    }
    /// GBIF records per species in the source region/month (record share = n / total); nil when the month has no data.
    func monthCounts(_ place: Place, month: Int) -> (counts: [String: (n: Int, tier: Int)], total: Int, coverage: String?)? {
        let s = source(place, month: month)
        guard let src = s.source else { return nil }
        var out = [String: (Int, Int)](), total = 0
        for r in rows("SELECT sp.scientific,c.n,c.tier FROM counts c JOIN species sp ON sp.id=c.species_id WHERE c.region_id=? AND c.month=?", [src, String(month)]) {
            let n = Int(r[1]) ?? 0; out[r[0]] = (n, Int(r[2]) ?? 0); total += n
        }
        return (out, total, s.coverage)
    }
    /// RarityBook.compute's read of the monthCounts table: the same source() and rows (text-bound, joined to species), tiers only, by species id.
    /// A tier stored as an integer is read as one, anything else as Int(text) ?? 0 like monthCounts. nil when the month has no data;
    /// a failed prepare gives an empty table and a step error part way keeps the rows read so far, as rows() does.
    func monthTiers(_ code: String, month: Int) -> [Int64: Int]? {
        guard let src = source(Place(lat: 0, lon: 0, label: "", source: "region", regionCode: code), month: month).source else { return nil }
        var out = [Int64: Int]()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT sp.id,c.tier FROM counts c JOIN species sp ON sp.id=c.species_id WHERE c.region_id=? AND c.month=?", -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in [src, String(month)].enumerated() { _ = v.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[sqlite3_column_int64(stmt, 0)] = sqlite3_column_type(stmt, 1) == SQLITE_INTEGER ? Int(sqlite3_column_int64(stmt, 1)) : Int(sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "") ?? 0
        }
        return out
    }
    /// RarityBook.compute's one read of the species table. ids: name → id, the name as rows() reads it (NULL as ""), keyed by Swift String like the
    /// old Set and month dictionary. iucn: keyed by the name's bytes, as `scientific=?` compares (NULL and BLOB names never match; NULL or empty = none).
    /// nil when the query can't be prepared, an id isn't an integer, or two rows share a name by Swift equality: the caller then takes the old path.
    /// Also nil on a step error part way: the old scientific-only read and per-species lookups may not fail where this three-column scan does.
    func speciesIndex() -> (ids: [String: Int64], iucn: [[UInt8]: String])? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,scientific,iucn FROM species", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var ids = [String: Int64](), iucn = [[UInt8]: String]()
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER else { return nil }
            let text = sqlite3_column_type(stmt, 1) == SQLITE_TEXT   // before column_text, which converts
            let p = sqlite3_column_text(stmt, 1)
            guard ids.updateValue(sqlite3_column_int64(stmt, 0), forKey: p.map { String(cString: $0) } ?? "") == nil else { return nil }
            if text, let p, let c = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }), !c.isEmpty { iucn[Array(UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, 1))))] = c }
            rc = sqlite3_step(stmt)
        }
        return rc == SQLITE_DONE ? (ids, iucn) : nil
    }
    /// The one IUCN read for display: the current table's category for a species (nil when hidden or unknown).
    /// Never the value stored inside an old Identification.
    func iucn(_ sci: String) -> String? {
        UserDefaults.standard.bool(forKey:"hideIUCN") ? nil : rows("SELECT iucn FROM species WHERE scientific=?",[sci]).first.flatMap{$0[0].isEmpty ? nil:$0[0]}
    }
    /// Same column for many species at once (探索 filters and badges).
    func iucn(codes: [String]) -> [String: String] {
        guard !UserDefaults.standard.bool(forKey:"hideIUCN") else {return [:]}
        return Dictionary(rows("SELECT scientific,iucn FROM species WHERE iucn IN (\(codes.map{"'\($0)'"}.joined(separator:",")))",[]).map{($0[0],$0[1])},uniquingKeysWith:{a,_ in a})
    }
    func lookup(_ sci: String, place: Place?, month: Int?) -> RarityValue {
        let sp=rows("SELECT id,iucn FROM species WHERE scientific=?",[sci]).first
        let iucn=self.iucn(sci)
        guard let place else {return RarityValue(label:"数据不足",iucn:iucn)}
        let global = !rows("SELECT name FROM sqlite_master WHERE name='shapes'",[]).isEmpty
        var code:String?
        if global {
            if let known=place.regionCode {code=known} else {let point=regionAt(lat:place.lat,lon:place.lon);code=point.division ?? point.country}
        } else {
            // Read-only migration support for historical test tables; production uses only shapes.
            let key=place.legacyRegionKey
            code=key.1.flatMap{rows("SELECT code FROM regions WHERE country=? AND name_en=? AND level=1",[key.0,$0]).first?.first}
                ?? rows("SELECT code FROM regions WHERE country=? AND level=0",[key.0]).first?.first
        }
        guard let code else {return RarityValue(label:"数据不足",iucn:iucn)}
        guard let sp else {return RarityValue(label:"未知",iucn:nil,region:code)}
        guard let month else {return RarityValue(label:"时间未知",iucn:iucn,region:code)}
        var source=rows("SELECT m.source_id FROM months m JOIN regions r ON r.id=m.region_id WHERE r.code=? AND m.month=?",[code,String(month)]).first?.first
        if source == nil && global && code.contains("-") {source=rows("SELECT m.source_id FROM months m JOIN regions r ON r.id=m.region_id WHERE r.code=? AND m.month=?",[String(code.prefix(2)),String(month)]).first?.first}
        guard let source,!source.isEmpty else {return RarityValue(label:"数据不足",iucn:iucn,region:code)}
        let t=rows("SELECT tier FROM counts WHERE region_id=? AND month=? AND species_id=?",[source,String(month),sp[0]]).first?.first.flatMap(Int.init) ?? 0
        return RarityValue(label:["无记录","罕见","少见","不常见","常见"][max(0,min(4,t))],iucn:iucn,region:code)
    }
    static func iucnLabel(_ value: String?) -> String {
        guard let value else { return String(localized: "数据不足") }
        return ["LC":String(localized:"无危"),"NT":String(localized:"近危"),"VU":String(localized:"易危"),"EN":String(localized:"濒危"),"CR":String(localized:"极危"),"DD":String(localized:"数据缺乏"),"NE":String(localized:"未评估"),"EX":String(localized:"灭绝"),"EW":String(localized:"野外灭绝")][value].map {"\($0) · \(value)"} ?? value
    }
}
