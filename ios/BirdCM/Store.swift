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


/// sRGB tokens shared with the SwiftUI palette; no platform colour conversions in the AA check.
enum ThemeContrast {
    static let paper:(UInt32,UInt32)=(0xf4f1e8,0x181f1a), surface:(UInt32,UInt32)=(0xfcfaf3,0x222c24)
    static let ink:(UInt32,UInt32)=(0x222c24,0xf1eee2), secondary:(UInt32,UInt32)=(0x516053,0xbec9bb)
    static let accent:(UInt32,UInt32)=(0x254d39,0xb8d6af), warning:(UInt32,UInt32)=(0x815919,0xf0ca83)
    static let button:(UInt32,UInt32)=(0x254d39,0x254d39)
    static let iucn:[String:(UInt32,UInt32)] = ["LC":(0xffffff,0x006666),"NT":(0x000000,0x99cc99),"VU":(0x000000,0xffcc00),"EN":(0x000000,0xff6600),"CR":(0xffffff,0xcc3333),"EX":(0xffffff,0x000000),"EW":(0xffffff,0x000000),"DD":(0x000000,0xdddddd),"NE":(0x000000,0xdddddd)]
    static let rarity:[String:(UInt32,UInt32)] = ["常见":(0xffffff,0x245c45),"不常见":(0xffffff,0x375d75),"少见":(0x000000,0xe6c65c),"罕见":(0x000000,0xf4ac7e),"无记录":(0xffffff,0x805100)]
    static var pairs:[(UInt32,UInt32,Double)] {
        let text=[ink,secondary,accent,warning]
        var out=text.flatMap {fg in [paper,surface].flatMap{bg in [(fg.0,bg.0,4.5),(fg.1,bg.1,4.5)]}}
        out += [(0xffffff,button.0,4.5),(0xffffff,0x1e3f2f,4.5),(0xffffff,0x595959,4.5),(0xffffff,0x000000,4.5)]
        out += (Array(iucn.values)+Array(rarity.values)).map{($0.0,$0.1,4.5)}
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
