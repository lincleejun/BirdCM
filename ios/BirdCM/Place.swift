import CoreLocation
import Foundation
import ImageIO
import Observation

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
    var sourceLabel:String { if source=="region" {let name=Self.display(label);return String(localized:"按整个\(name.components(separatedBy:" · ").last ?? name)估计")};return ["photo":String(localized:"用了照片自带的位置"),"device":String(localized:"当前位置"),"map":String(localized:"按地图上选的位置")][source] ?? source }
    /// In English: the bundled English name for a region or country label, and 地图选点 etc. translated (stored labels stay Chinese).
    static let english=Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
    static func display(_ label:String) -> String {
        guard english else {return label}
        return Library.regionCodes[label].flatMap{englishNames[$0]} ?? label.components(separatedBy:" · ").map(loc).joined(separator:" · ")
    }
    /// The label without a trailing "lat, lon" (photo GPS and device labels are only coordinates; map picks append them).
    /// Coordinates are shown on a map snapshot and as a caption instead.
    var name:String {
        let s=Self.withoutCoordinates(label)
        return s.isEmpty ? ["photo":String(localized:"照片拍摄位置"),"device":String(localized:"当前位置")][source] ?? String(localized:"地图选点"):s
    }
    /// The label without a trailing "lat, lon"; empty when the label was only coordinates.
    static func withoutCoordinates(_ label:String) -> String {
        label.replacingOccurrences(of:#"(^| · )-?\d+(\.\d+)?, -?\d+(\.\d+)?$"#,with:"",options:.regularExpression)
    }
    /// Offline English names by ISO code: "United States" for a country, "United States · California" for a division.
    static let englishNames:[String:String] = {
        var out=[String:String]()
        for c in countries {if let code=c["code"],let en=c["en"] {out[code]=en}}
        for p in globalRegions {
            guard let code=p.regionCode,let en=p.regionEnglish else {continue}
            out[code]=(out[String(code.prefix(2))].map{$0+" · "} ?? "")+en
        }
        return out
    }()
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

/// Readable names for points (owner 2026-11-18: "文字位置，好理解", in English): the offline country · division at once,
/// then Apple's reverse geocoding (en_US) once per ~1 km cell, cached in the library. Only coordinates go to Apple, one
/// request at a time, ~1 s apart, a minute's pause after an error; never a street address.
@MainActor @Observable final class PlaceNames {
    private(set) var online=[String:String]()
    @ObservationIgnored private var offline=[String:String]()
    @ObservationIgnored private var queue=[(key:String,lat:Double,lon:Double)]()
    @ObservationIgnored private var queued=Set<String>()
    @ObservationIgnored private var running=false
    @ObservationIgnored private var pausedUntil=Date.distantPast
    /// Persist a fetched name (the library's cell cache) and the offline region lookup (codes for a point).
    @ObservationIgnored var store:((String,String)->Void)?
    @ObservationIgnored var regionAt:((Double,Double)->(division:String?,country:String?))?
    /// 设置 → 用网络显示地名 (default on; UI tests register off unless they opt in).
    static var networkEnabled:Bool {UserDefaults.standard.object(forKey:"placeNamesOnline") as? Bool ?? true}
    func load(_ names:[String:String]) {online=names}
    func name(lat:Double,lon:Double) -> String? {
        let key="p:\(Int(floor(lat*100))):\(Int(floor(lon*100)))"
        if Self.networkEnabled {
            if let n=online[key] {return n}
            if !queued.contains(key) && Date()>pausedUntil {queued.insert(key);queue.append((key,lat,lon));Task{await drain()}}
        }
        if let n=offline[key] {return n}
        let codes=regionAt?(lat,lon), n=(codes?.division ?? codes?.country).flatMap{Place.englishNames[$0]} ?? codes?.country.flatMap{Place.englishNames[$0]}
        if let n {offline[key]=n}
        return n
    }
    private func drain() async {
        guard !running else {return}
        running=true;defer{running=false}
        while !queue.isEmpty,Self.networkEnabled {
            let job=queue.removeFirst()
            do {
                let marks=try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude:job.lat,longitude:job.lon),preferredLocale:Locale(identifier:"en_US"))
                if let p=marks.first,let n=Self.compose(locality:p.locality,county:p.subAdministrativeArea,state:p.administrativeArea,area:p.areasOfInterest?.first,district:p.subLocality,water:p.inlandWater ?? p.ocean,country:p.country) {online[job.key]=n;store?(job.key,n)}
                try? await Task.sleep(for:.milliseconds(1200))
            } catch {
                // Offline or throttled: forget the queue (names are asked again when rows show) and pause a minute.
                pausedUntil=Date().addingTimeInterval(60);queue.removeAll();queued.removeAll();return
            }
        }
    }
    /// "Town · park or district": the most local named area, never a street or house number; falls back to the country.
    nonisolated static func compose(locality:String?,county:String?,state:String?,area:String?,district:String?,water:String?,country:String?) -> String? {
        let parts=[locality ?? county ?? state,area ?? district ?? water].compactMap{$0}.filter{!$0.isEmpty}
        let unique=parts.reduce(into:[String]()){if !$0.contains($1) {$0.append($1)}}
        return unique.isEmpty ? country:unique.joined(separator:" · ")
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
