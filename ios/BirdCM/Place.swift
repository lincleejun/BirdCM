import CoreLocation
import Foundation
import ImageIO

/// Even/odd ray test shared with the global table region resolver.
enum Boundaries {
    static func inside(_ x:Double,_ y:Double,_ r:[Double]) -> Bool {
        var hit=false
        for i in stride(from:0,to:r.count,by:2) {
            let j=(i+2)%r.count
            if (r[i+1]>y) != (r[j+1]>y), x < r[i]+(y-r[i+1])*(r[j]-r[i])/(r[j+1]-r[i+1]) {hit.toggle()}
        }
        return hit
    }
}


func resource<T: Decodable>(_ name: String, as type: T.Type) -> T {
    let u = (UserDefaults.standard.string(forKey:"resourceDir") ?? ProcessInfo.processInfo.environment["RESOURCE_DIR"]).map{URL(fileURLWithPath:$0).appendingPathComponent(name+".json")} ?? Bundle.main.url(forResource:name,withExtension:"json")
    guard let u, let d = try? Data(contentsOf: u), let v = try? JSONDecoder().decode(type, from: d) else { preconditionFailure("Missing resource: \(name)") }
    return v
}
struct Place: Codable, Equatable {
    var lat: Double, lon: Double, label: String, source: String
    var regionCode:String?
    var regionEnglish:String?
    var sourceLabel:String { if source=="region" {return "按整个"+(label.components(separatedBy:" · ").last ?? label)+"估计"};return ["photo":"用了照片自带的位置","device":"当前位置","map":"按地图上选的位置","region":"按整个地区估计"][source] ?? source }
    /// The label without a trailing "lat, lon" (photo GPS and device labels are only coordinates; map picks append them).
    /// Coordinates are shown on a map snapshot and as a caption instead.
    var name:String {
        let s=label.replacingOccurrences(of:#"(^| · )-?\d+(\.\d+)?, -?\d+(\.\d+)?$"#,with:"",options:.regularExpression)
        return s.isEmpty ? ["photo":String(localized:"照片拍摄位置"),"device":String(localized:"当前位置")][source] ?? String(localized:"地图选点"):s
    }
    var stableCode:String {regionCode ?? String(format:"%.4f,%.4f",lat,lon)}
    var valid: Bool { lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon) }
    static func resolve(photo: Place?, device: Place?, manual: Place?) -> Place? {
        [photo, device, manual].compactMap { $0 }.first { $0.valid }
    }
    static let countries = resource("countries", as: [[String:String]].self)
    static let regions = resource("regions", as: [[String:String]].self)
    static let globalRegions:[Place] = {
        guard let db=try? Rarity(path:Models.rarityURL) else {return []}
        let values=db.rows("SELECT r.code,r.country,r.name_en,r.name_zh,s.minx,s.miny,s.maxx,s.maxy FROM regions r JOIN shapes s ON s.region_id=r.id WHERE r.level=1 ORDER BY (s.maxx-s.minx)*(s.maxy-s.miny) DESC",[])
        var found=[String:Place]()
        for r in values where found[r[0]] == nil {
            guard let x0=Double(r[4]),let y0=Double(r[5]),let x1=Double(r[6]),let y1=Double(r[7]) else {continue}
            let country=countries.first{$0["code"]==r[1]}?["zh"] ?? r[1]
            let old=regions.first{$0["country"]==country && $0["name_en"]==r[2]}
            let name=old?["region"] ?? (r[3].isEmpty ? r[2]:r[3])
            found[r[0]]=Place(lat:(y0+y1)/2,lon:(x0+x1)/2,label:country+" · "+name,source:"region",regionCode:r[0],regionEnglish:r[2])
        }
        return Array(found.values)
    }()
    var searchText:String {
        if let regionEnglish {return label+" "+regionEnglish}
        if source=="region", let r=Self.regions.first(where:{Self.from($0,country:$0["country"]!).label==label}) {return label+" "+(r["name_en"] ?? "")}
        return label+" "+(Self.countries.first{$0["zh"]==label}?["en"] ?? "")
    }
    static func choices(query:String,recent:[String]) -> [Place] {
        let all=countries.map{Self.from($0)}+(globalRegions.isEmpty ? regions.map{Self.from($0,country:$0["country"]!)}:globalRegions)
        return all.filter{query.isEmpty || $0.searchText.localizedStandardContains(query)}.sorted {a,b in
            let ai=recent.firstIndex(of:a.label) ?? Int.max, bi=recent.firstIndex(of:b.label) ?? Int.max
            return ai==bi ? a.label<b.label : ai<bi
        }
    }
    static func from(_ row: [String:String], country: String? = nil) -> Place {
        Place(lat: Double(row["lat"]!)!, lon: Double(row["lon"]!)!, label: country.map { $0 + " · " + row["region"]! } ?? row["zh"]!, source: "region",regionCode:country == nil ? row["code"]:nil)
    }
    /// For reading old three-country test databases only. Production point lookup is Rarity.regionAt.
    var legacyRegionKey:(String,String?) {
        let parts=label.components(separatedBy:" · ")
        let code=Self.countries.first{$0["zh"]==parts[0]}?["code"] ?? ""
        let division=parts.count>1 ? Self.regions.first{$0["country"]==parts[0] && $0["region"]==parts[1]}?["name_en"]:nil
        return (code,division)
    }

}

struct Shooting: Codable {
    var takenAt: String?
    var timeOffset: String?
    var captureDate:Date? {
        guard let takenAt else{return nil}
        if let timeOffset {return ISO8601DateFormatter().date(from:takenAt+timeOffset)}
        let parser=DateFormatter();parser.locale=Locale(identifier:"en_US_POSIX");parser.dateFormat="yyyy-MM-dd'T'HH:mm:ss"
        return parser.date(from:takenAt)
    }
    var photoPlace: Place?
    var fields: [String:String] = [:]
    var month: Int? { takenAt.flatMap { Int($0.dropFirst(5).prefix(2)) } }
    init(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData,nil), let p = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any] else { return }
        let ex = p[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        timeOffset=ex[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        if let s = ex[kCGImagePropertyExifDateTimeOriginal as String] as? String, s.count >= 10 {
            let date = s.prefix(10).replacingOccurrences(of: ":",with:"-")
            takenAt = date + "T" + s.dropFirst(11)
        }
        fields["相机"] = tiff[kCGImagePropertyTIFFModel as String] as? String
        fields["镜头"] = ex[kCGImagePropertyExifLensModel as String] as? String
        func n(_ key: CFString) -> Double? { (ex[key as String] as? NSNumber)?.doubleValue }
        if let f = n(kCGImagePropertyExifFocalLength) { fields["焦距"] = String(format:"%.0f mm",f) }
        if let f = n(kCGImagePropertyExifFNumber) { fields["光圈"] = String(format:"f/%.1f",f) }
        if let s = n(kCGImagePropertyExifExposureTime), s > 0 { fields["快门"] = s < 1 ? String(format:"1/%.0f s",1/s) : "\(s) s" }
        if let iso = (ex[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first { fields["ISO"] = iso.stringValue }
        if let v = n(kCGImagePropertyExifExposureBiasValue) { fields["曝光补偿"] = String(format:"%g EV",v) }
        if let gps = p[kCGImagePropertyGPSDictionary as String] as? [String:Any], let lat = gps["Latitude"] as? Double, let lon = gps["Longitude"] as? Double {
            let la = lat * ((gps["LatitudeRef"] as? String) == "S" ? -1 : 1), lo = lon * ((gps["LongitudeRef"] as? String) == "W" ? -1 : 1)
            let place = Place(lat:la,lon:lo,label:String(format:"%.4f, %.4f",la,lo),source:"photo")
            if place.valid { photoPlace = place }
        }
    }
}

@MainActor final class DeviceLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Place?, Never>?
    private var requestID=UUID()
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    nonisolated static func canLocate(_ status:CLAuthorizationStatus) -> Bool {status != .denied && status != .restricted}
    func request() async -> Place? {
        #if DEBUG
        if UserDefaults.standard.string(forKey:"locationFixture") == "denied" {return nil}
        if UserDefaults.standard.string(forKey:"locationFixture") == "allowed" {return Place(lat:33.7,lon:-118.06,label:"Bolsa Chica",source:"device")}
        #endif
        guard continuation == nil, Self.canLocate(manager.authorizationStatus) else { return nil }
        return await withCheckedContinuation { c in
            continuation = c
            let id=UUID();requestID=id
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
            default: finish(nil)
            }
            Task { try? await Task.sleep(for: .seconds(12)); if self.requestID==id {self.finish(nil)} }
        }
    }
    func finish(_ p: Place?) { continuation?.resume(returning:p); continuation = nil }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { finish(nil); return }
        finish(Place(lat:c.latitude,lon:c.longitude,label:String(format:"%.3f, %.3f",c.latitude,c.longitude),source:"device"))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
}
