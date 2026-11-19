import Foundation
import Observation
import CryptoKit

func excludeBackup(_ url: URL) throws {
    var u = url, values = URLResourceValues(); values.isExcludedFromBackup = true; try u.setResourceValues(values)
}
struct Record: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var boxes: [[Double]]
    var displayCrops: [[Double]]? = nil
    var selected: Int
    var result: Identification?
    var shooting: Shooting
    var place: Place?
    var manual = false
    var results: [String:Identification] = [:]
    /// Library overlay (subject identity and human edits); never written into the legacy JSON.
    var subjects: [SubjectEdit]? = nil
    func matches(_ query:String) -> Bool {
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !q.isEmpty else {return true}
        let names=([result].compactMap{$0}+Array(results.values)).flatMap{$0.top5}.flatMap{[$0.chinese,$0.english,$0.scientific]}
        return (names+[place?.searchText ?? ""]).contains{$0.localizedStandardContains(q)}
    }
}

struct SubjectEdit: Codable, Equatable {
    var id: String
    var state = "none"
    var key: String?
    var count: Int?
    var excluded = false
}

/// The pre-library format (one JSON + one `.photo` per identification). Read only by migration; kept for building old-format test stores.
final class HistoryStore {
    let dir: URL
    init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try excludeBackup(dir)
    }
    func all() throws -> [Record] {
        try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
            .map { try JSONDecoder().decode(Record.self,from:Data(contentsOf:$0)) }.sorted{$0.date>$1.date}
    }
    func save(_ r: Record, data: Data? = nil) throws {
        let encoded=try JSONEncoder().encode(r)
        if let data {
            try data.write(to:image(r),options:.atomic)
            do { try encoded.write(to:dir.appendingPathComponent("\(r.id).json"),options:.atomic) }
            catch { try? FileManager.default.removeItem(at:image(r)); throw error }
        } else { try encoded.write(to:dir.appendingPathComponent("\(r.id).json"),options:.atomic) }
    }
    func image(_ r: Record) -> URL { dir.appendingPathComponent("\(r.id).photo") }
    func delete(_ r: Record) throws {
        for u in [dir.appendingPathComponent("\(r.id).json"),image(r)] where FileManager.default.fileExists(atPath:u.path) { try FileManager.default.removeItem(at:u) }
    }
}
enum Models {
    static let geoName = "BirdNET+_Geomodel_V3.0.4_Global_14K_FP32.onnx"
    static var support: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0] }
    static var dir: URL { UserDefaults.standard.string(forKey:"modelDir").map{URL(fileURLWithPath:$0)} ?? Bundle.main.resourceURL!.appendingPathComponent("Models") }
    static var geoURL: URL { UserDefaults.standard.string(forKey:"geoPath").map{URL(fileURLWithPath:$0)} ?? dir.appendingPathComponent(geoName) }
    static var rarityURL: URL { UserDefaults.standard.string(forKey:"rarityPath").map{URL(fileURLWithPath:$0)} ?? dir.appendingPathComponent("rarity-global.sqlite") }
    struct Asset: Codable {
        var path: String; var url: String; var sha256: String; var bytes: Int64
        func valid(at url:URL) throws -> Bool {
            guard FileManager.default.fileExists(atPath:url.path) else {return false}
            return try Models.digest(url)==sha256
        }
    }
    static var assets: [Asset] {
        let url=dir.appendingPathComponent("integrity.json")
        return (try? JSONDecoder().decode([Asset].self,from:Data(contentsOf:url))) ?? []
    }
    static var present: Bool { !assets.isEmpty }
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "")(\(info["CFBundleVersion"] ?? ""))"
    }
    /// The bundled models live inside the code-signed, read-only app bundle: iOS checks the signature (which covers every
    /// file here) at install, so the full SHA-256 pass (~700 MB) runs once per installed build — key: version + build number +
    /// file sizes — and is remembered in UserDefaults. Other launches only check that each file exists with its size.
    /// `full` forces the hash pass (诊断 → 完整校验). Returns the bad paths and whether this call hashed.
    static func check(dir: URL = dir, assets: [Asset] = assets, full: Bool = false, defaults: UserDefaults = .standard, build: String = build) throws -> (invalid: [String], hashed: Bool) {
        guard !assets.isEmpty else { return (["integrity.json"], false) }
        let key = build + "|" + sha256(Data(assets.map { "\($0.path)=\($0.bytes)" }.joined(separator: "\n").utf8))
        let sized = assets.filter { a in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(a.path).path)[.size] as? NSNumber)?.int64Value
            return size != a.bytes
        }.map(\.path)
        guard sized.isEmpty else { defaults.removeObject(forKey: "integrityVerified"); return (sized, false) }
        if !full && defaults.string(forKey: "integrityVerified") == key { return ([], false) }
        let invalid = try assets.filter { try Models.digest(dir.appendingPathComponent($0.path)) != $0.sha256 }.map(\.path)
        if invalid.isEmpty { defaults.set(key, forKey: "integrityVerified") } else { defaults.removeObject(forKey: "integrityVerified") }
        return (invalid, true)
    }
    /// An early build downloaded the models into Application Support/Models (~700 MB); they ship in the bundle now. Deletes
    /// that one folder (never History or anything else), and never while the models in use live inside it. Remembers the
    /// bytes freed for 诊断; returns them.
    @discardableResult static func removeLegacyDownloads(support: URL = support, inUse: URL = dir, defaults: UserDefaults = .standard) -> Int64 {
        let fm = FileManager.default, legacy = support.appendingPathComponent("Models", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return 0 }
        func path(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        guard !path(inUse).hasPrefix(path(legacy)) else { return 0 }
        var bytes: Int64 = 0
        let files = fm.enumerator(at: legacy, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let f = files?.nextObject() as? URL { bytes += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        guard (try? fm.removeItem(at: legacy)) != nil else { return 0 }
        defaults.set(bytes, forKey: "legacyModelsFreed")
        return bytes
    }
    static func digest(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom:url); defer{try? h.close()}
        var hash = SHA256()
        while let data = try h.read(upToCount:1024*1024), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
}


/// sRGB tokens (light, dark) shared with the SwiftUI palette: docs/design/polish/tokens.json v2 (kingfisher: 0–9 neutral
/// grays, accent #17646B / #76CFD1, orange only for 新种 numbers). No platform colour conversions in the AA check.
enum ThemeContrast {
    typealias Pair = (UInt32,UInt32)
    /// A semantic state: foreground on its own background, per mode.
    struct Semantic { let fg:Pair; let bg:Pair }
    static let canvas:Pair=(0xFAFAFA,0x0A0A0A), surface:Pair=(0xFFFFFF,0x141414)
    static let inset:Pair=(0xF5F5F5,0x1F1F1F), surface3:Pair=(0xEBEBEB,0x292929)
    static let ink:Pair=(0x171717,0xEDEDED), secondary:Pair=(0x606060,0xB5B5B5), tertiary:Pair=(0x666666,0xA3A3A3)
    static let border:Pair=(0xD4D4D4,0x3D3D3D), borderStrong:Pair=(0x858585,0x858585)
    static let accent:Pair=(0x17646B,0x76CFD1), accentPressed:Pair=(0x124E55,0xA2E2DF), onAccent:Pair=(0xFFFFFF,0x0A0A0A)
    static let newSpecies:Pair=(0x854015,0xFFBC87)
    static let mat:Pair=(0x171717,0x0A0A0A), onMat:Pair=(0xEDEDED,0xEDEDED), onMatMuted:Pair=(0xB5B5B5,0xB5B5B5)
    static let success=Semantic(fg:(0x245D52,0xA5D8C1),bg:(0xDCF0E7,0x1B413A))
    static let warning=Semantic(fg:(0x76510F,0xEED28C),bg:(0xF6E9BE,0x453917))
    static let error=Semantic(fg:(0x983F47,0xFFB3BF),bg:(0xFBE4E7,0x4C252E))
    static let unavailable=Semantic(fg:(0x4D6062,0xC3D0D2),bg:(0xE5EAEA,0x2A3B40))
    static let rarity:[String:Semantic] = [
        "常见":success, "不常见":Semantic(fg:(0x2D596E,0xB0D7E9),bg:(0xE2EEF4,0x203D4A)), "少见":warning,
        "罕见":Semantic(fg:(0x854015,0xFFBC87),bg:(0xF9E4D2,0x4A3021)), "无记录":Semantic(fg:(0x67552B,0xDACEA9),bg:(0xEEE8D8,0x3E382B))]
    static let iucn:[String:Semantic] = [
        "LC":success, "NT":Semantic(fg:(0x4F621D,0xCDDB98),bg:(0xEAF0D5,0x353F20)), "VU":warning, "EN":rarity["罕见"]!, "CR":error,
        "EW":Semantic(fg:(0x654666,0xDDC1E2),bg:(0xEEE5EF,0x3C2E42)), "EX":Semantic(fg:(0x35474E,0xCDDCDF),bg:(0xE1E7E9,0x28383F)),
        "DD":unavailable, "NE":unavailable]
    /// contrast.md: text roles ≥ 4.5 on every surface, control borders and focus ≥ 3, each state on its own background;
    /// plus warning / error / success text on the plain surfaces (inline notes).
    static var pairs:[(UInt32,UInt32,Double)] {
        func both(_ fg:Pair,_ bg:Pair,_ min:Double) -> [(UInt32,UInt32,Double)] {[(fg.0,bg.0,min),(fg.1,bg.1,min)]}
        let surfaces=[canvas,surface,inset,surface3]
        var out=[ink,secondary,tertiary,accent,newSpecies].flatMap {fg in surfaces.flatMap {both(fg,$0,4.5)}}
        out += [borderStrong,accent].flatMap {fg in surfaces.flatMap {both(fg,$0,3)}}
        out += [warning.fg,error.fg,success.fg].flatMap {fg in [canvas,surface].flatMap {both(fg,$0,4.5)}}
        out += both(onAccent,accent,4.5)+both(onAccent,accentPressed,4.5)+both(onMat,mat,4.5)+both(onMatMuted,mat,4.5)
        out += (Array(iucn.values)+Array(rarity.values)).flatMap {both($0.fg,$0.bg,4.5)}
        return out
    }
    static func contrast(_ a:UInt32,_ b:UInt32) -> Double {
        func luminance(_ h:UInt32) -> Double {
            let c=[16,8,0].map { shift -> Double in
                let v=Double((h >> shift)&255)/255
                return v <= 0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)
            }
            return c[0]*0.2126+c[1]*0.7152+c[2]*0.0722
        }
        let x=luminance(a), y=luminance(b)
        return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
}
