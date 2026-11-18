import Foundation

struct GeoSpread { var wide: [Double]; var typical: [Double] }
final class Geo {
    let network: GeoNetwork
    let indices: [[Int]]
    let grid: [String:[[Double]]]
    private var cached: (Place,String?,GeoSpread)?
    init(weights: URL, scientific: [String]) throws {
        network = try GeoNetwork(weights:weights,graphURL:UserDefaults.standard.string(forKey:"resourceDir").map{URL(fileURLWithPath:$0).appendingPathComponent("geo-graph.json")} ?? Bundle.main.url(forResource:"geo-graph",withExtension:"json")!)
        let mapping = resource("avilist-birdnet-geo3",as:[[String:String]].self)
        let index = Dictionary(uniqueKeysWithValues:mapping.map { ($0["scientific"]!,($0["geo3_index"] ?? "").split(separator:"|").compactMap{Int($0)}) })
        indices = scientific.map { index[$0] ?? [] }
        grid = Dictionary(grouping:resource("region-grid",as:[[String:String]].self),by:{$0["place"]!}).mapValues { $0.map{[Double($0["lat"]!)!,Double($0["lon"]!)!]} }
    }
    static func week(_ date: String?) -> Int? {
        guard let date, date.count >= 10, let m = Int(date.dropFirst(5).prefix(2)),let d = Int(date.dropFirst(8).prefix(2)),(1...12).contains(m),(1...31).contains(d) else { return nil }
        return (m-1)*4+min(3,(d-1)/8)+1
    }
    static func weeks(_ date: String?) -> [Int] {
        guard let w = week(date) else { return Array(1...48) }
        return (-3...3).map{(w-1+$0+48)%48+1}.sorted()
    }
    static func snap(_ point: [Double]) -> [Double] {
        let lon = (point[1]+540).truncatingRemainder(dividingBy:360)-180
        return [point[0],lon].map { (($0/0.05).rounded(.toNearestOrEven)*0.05*100).rounded(.toNearestOrEven)/100 }
    }
    func cover(_ p: Place) -> [[Double]] {
        if p.source == "region", let pts = grid[p.label] { return pts.map(Self.snap) }
        return [-0.25,0,0.25].flatMap { a in [-0.25,0,0.25].map{Self.snap([p.lat+a,p.lon+$0])} }
    }
    func spread(_ p: Place, date: String?) throws -> GeoSpread {
        if let c = cached, c.0 == p, c.1 == date { return c.2 }
        let pts = cover(p), weeks = Self.weeks(date)
        var byPoint = [[Double]]()
        // Bound activation memory even for large countries and unknown capture dates.
        for point in pts {
            let q = try network.predict(weeks.map{[Float(point[0]),Float(point[1]),Float($0)]})
            byPoint.append(indices.map { ids in ids.reduce(0.0) { best,i in max(best,q.reduce(0.0){max($0,Double($1[i]))}) } })
        }
        var wide = [Double](), typical = [Double]()
        for j in indices.indices {
            if indices[j].isEmpty { wide.append(.nan); typical.append(.nan); continue }
            let values = byPoint.map{$0[j]}.sorted(), mid = values.count/2
            wide.append(values.last ?? 0)
            typical.append(values.count%2==0 ? (values[mid-1]+values[mid])/2 : values[mid])
        }
        let out = GeoSpread(wide:wide,typical:typical); cached = (p,date,out); return out
    }
}
