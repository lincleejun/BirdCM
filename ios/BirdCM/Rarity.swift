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
    /// Port of rarity_global.region_at: ISO codes, even/odd rings, smallest area wins, 0.25° coastal tolerance.
    func regionAt(lat:Double,lon:Double) -> (division:String?,country:String?) {
        var stmt:OpaquePointer?
        let sql="SELECT r.code,r.level,s.pts,(SELECT sum((maxx-minx)*(maxy-miny)) FROM shapes t WHERE t.region_id=s.region_id) FROM shapes s JOIN regions r ON r.id=s.region_id WHERE minx<=? AND maxx>=? AND miny<=? AND maxy>=?"
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else {return (nil,nil)}
        defer{sqlite3_finalize(stmt)}
        for (i,v) in [lon+0.25,lon-0.25,lat+0.25,lat-0.25].enumerated() {sqlite3_bind_double(stmt,Int32(i+1),v)}
        var rings=[String:[[Double]]](), areas=[String:Double](), levels=[String:Int]()
        while sqlite3_step(stmt)==SQLITE_ROW {
            let code=String(cString:sqlite3_column_text(stmt,0)), n=Int(sqlite3_column_bytes(stmt,2))/4
            guard let blob=sqlite3_column_blob(stmt,2) else {continue}
            let data=Data(bytes:blob,count:n*4)
            let ring=data.withUnsafeBytes {raw in (0..<n).map {Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self))))}}
            rings[code,default:[]].append(ring);areas[code]=sqlite3_column_double(stmt,3);levels[code]=Int(sqlite3_column_int(stmt,1))
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
        guard let value else { return "数据不足" }
        return ["LC":"无危","NT":"近危","VU":"易危","EN":"濒危","CR":"极危","DD":"数据缺乏","NE":"未评估","EX":"灭绝","EW":"野外灭绝"][value].map {"\($0) · \(value)"} ?? value
    }
}
