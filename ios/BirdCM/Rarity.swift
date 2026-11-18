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
    func lookup(_ sci: String, place: Place?, month: Int?) -> RarityValue {
        let sp=rows("SELECT id,iucn FROM species WHERE scientific=?",[sci]).first
        let iucn=UserDefaults.standard.bool(forKey:"hideIUCN") ? nil:sp.flatMap{$0[1].isEmpty ? nil:$0[1]}
        guard let place else {return RarityValue(label:"数据不足",iucn:iucn)}
        let global = !rows("SELECT name FROM sqlite_master WHERE name='shapes'",[]).isEmpty
        var code:String?
        if global {
            let point=regionAt(lat:place.lat,lon:place.lon);code=place.regionCode ?? point.division ?? point.country
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
