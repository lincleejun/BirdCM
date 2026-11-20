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

/// Species page and 探索: the geo model at one place through the year, and over the globe. Offline, a model estimate.
extension Geo {
    private static var sharedGeo: Geo?
    private static let sharedLock = NSLock()
    /// One Geo for browsing, indexed like `Catalogue.shared.all`; nil when the model is missing. `network`, `indices` and the
    /// functions below are safe from any thread; `spread` (its cache) stays behind `Likelihood`'s lock.
    static func shared(_ catalogue: Catalogue = .shared) -> Geo? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if sharedGeo == nil, FileManager.default.fileExists(atPath: Models.geoURL.path) { sharedGeo = try? Geo(weights: Models.geoURL, scientific: catalogue.all.map(\.sci)) }
        return sharedGeo
    }
    /// 48 model weeks (Geo.week: four per month) → 12 months, each the mean of its four weeks.
    static func monthly(_ weekly: [Double]) -> [Double] {
        precondition(weekly.count == 48)
        return (0..<12).map { m in weekly[m*4..<m*4+4].reduce(0, +) / 4 }
    }
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), mid = s.count / 2
        return s.isEmpty ? .nan : s.count % 2 == 0 ? (s[mid-1] + s[mid]) / 2 : s[mid]
    }
    /// Words for a model value when the GBIF table has nothing for the place and month: the local-rarity labels, cut at
    /// `Confirm.tau` (below it the result page warns 此地此季少见) and Explore's 0.01 floor; under that 不太可能.
    // ponytail: 0.5 / 0.2 are judgement cut-offs on a model score, not calibrated against GBIF tiers.
    static func modelTier(_ p: Double) -> String {
        p >= 0.5 ? "常见" : p >= 0.2 ? "不常见" : p >= Confirm.tau ? "少见" : p >= 0.01 ? "罕见" : "不太可能"
    }
    /// 12 monthly values per catalogue species at a place: the point itself, or for a region the median over its grid
    /// (like `typical`). nil for a species the model does not have (never 0). One 48-week batch per point.
    /// Points of a region forwarded at once by `months(at:)`. Fixed, not the core count: an iPhone has 6 cores
    /// (2 performance), and each concurrent 48-row forward holds ~17 MB of activations.
    static let monthsWorkers = 4
    func months(at p: Place) throws -> [[Double]?] {
        let pts = p.source == "region" ? cover(p) : [Self.snap([p.lat, p.lon])]
        let n = pts.count, workers = min(Self.monthsWorkers, n)
        // values[(j*12+m)*n + point]: one flat buffer, not arrays per point, species and week. Same arithmetic as
        // `monthly` (0 + four weeks in order, / 4) and `median` (sorted in place, the same sort as `sorted()`).
        var values = [Double](repeating: 0, count: indices.count * 12 * n)
        try values.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            // Point k into its own slots values[i*n + k]; `sums` is the caller's scratch (one per worker).
            func point(_ k: Int, _ sums: inout [Double]) throws {
                let q = try network.predict((1...48).map { [Float(pts[k][0]), Float(pts[k][1]), Float($0)] })
                // As `monthly`'s precondition did: 48 weeks whenever some species has a model id.
                precondition(q.count == 48 || indices.allSatisfy(\.isEmpty))
                for i in sums.indices { sums[i] = 0 }
                for (w, row) in q.enumerated() {
                    for (j, ids) in indices.enumerated() where !ids.isEmpty {
                        var best = row[ids[0]]
                        for i in ids.dropFirst() where best < row[i] { best = row[i] }   // as Array.max(): first wins ties and NaN
                        sums[j * 12 + w / 4] += Double(best)
                    }
                }
                for i in sums.indices { out[i * n + k] = sums[i] / 4 }
            }
            if workers <= 1 {
                var sums = [Double](repeating: 0, count: indices.count * 12)
                for k in 0..<n { try point(k, &sums) }
                return
            }
            // Worker w takes points w, w+workers, …; any failure is thrown once all workers are done.
            let lock = NSLock(); var failure: Error?
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                var sums = [Double](repeating: 0, count: indices.count * 12)
                do { for k in stride(from: w, to: n, by: workers) { try point(k, &sums) } }
                catch { lock.lock(); failure = error; lock.unlock() }
            }
            if let failure { throw failure }
        }
        var out = [[Double]?]()
        for j in indices.indices {
            guard !indices[j].isEmpty else { out.append(nil); continue }
            out.append((0..<12).map { m in
                let lo = (j * 12 + m) * n, mid = lo + n / 2
                values[lo..<lo + n].sort()
                return n == 0 ? .nan : n % 2 == 0 ? (values[mid - 1] + values[mid]) / 2 : values[mid]
            })
        }
        return out
    }

    // MARK: range map
    enum Season: String, CaseIterable { case year = "全年", breeding = "繁殖季", nonBreeding = "非繁殖季" }
    /// Months (1–12) of a season for a cell at `lat`: 繁殖季 north May–Jul / south Nov–Jan, 非繁殖季 north Dec–Feb / south Jun–Aug.
    static func seasonMonths(_ s: Season, lat: Double) -> [Int] {
        switch s {
        case .year: return Array(1...12)
        case .breeding: return lat >= 0 ? [5, 6, 7] : [11, 12, 1]
        case .nonBreeding: return lat >= 0 ? [12, 1, 2] : [6, 7, 8]
        }
    }
    static let rangeStep = 3.0
    static let rangeLat = (-60.0, 84.0)
    /// Cell centres [lat, lon], north row first, west to east: `step`° cells over latitudes 60° S – 84° N.
    static func rangeGrid(step: Double = rangeStep) -> [[Double]] {
        let rows = Int(((rangeLat.1 - rangeLat.0) / step).rounded()), cols = Int((360 / step).rounded())
        var out = [[Double]]()
        for r in 0..<rows {
            let lat: Double = rangeLat.1 - (Double(r) + 0.5) * step
            for c in 0..<cols { out.append([lat, -180 + (Double(c) + 0.5) * step]) }
        }
        return out
    }
    /// The model week sampled for each month (its second week).
    static func rangeWeek(_ month: Int) -> Int { (month - 1) * 4 + 2 }
    /// cells × 12 months (row-major, value × 255) of catalogue species `j`; nil when the model does not have it.
    /// Cached in Caches/SpeciesRange per species and grid. Chunks run in parallel; `progress` 0…1 from any thread.
    func range(_ j: Int, sci: String, step: Double = rangeStep, cache: Bool = true, progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> [UInt8]? {
        let ids = indices[j]
        guard !ids.isEmpty else { return nil }
        let grid = Self.rangeGrid(step: step)
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SpeciesRange/\(sci.replacingOccurrences(of: " ", with: "_"))-\(step)-v1.u8")
        if cache, let data = try? Data(contentsOf: file), data.count == grid.count * 12 { return [UInt8](data) }
        let rows = grid.flatMap { c in (1...12).map { [Float(c[0]), Float(c[1]), Float(Self.rangeWeek($0))] } }
        var out = [UInt8](repeating: 0, count: rows.count)
        // predict keeps every activation until it returns (~120 × 384 floats a row): small chunks bound memory per core.
        let chunk = 256, chunks = (rows.count + chunk - 1) / chunk
        let lock = NSLock(); var done = 0; var failure: Error?
        out.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { k in
                let lo = k * chunk, hi = min(rows.count, lo + chunk)
                do {
                    let q = try network.predict(Array(rows[lo..<hi]), columns: ids)
                    for (i, r) in q.enumerated() { base[lo + i] = UInt8((Double(r.max()!) * 255).rounded()) }
                } catch { lock.lock(); failure = error; lock.unlock() }
                lock.lock(); done += 1; let f = Double(done) / Double(chunks); lock.unlock()
                progress(f)
            }
        }
        if let failure { throw failure }
        if cache {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(out).write(to: file, options: .atomic)
        }
        return out
    }
    /// One value per cell (0…1): the highest of the season's months, by the cell's hemisphere.
    static func seasonMap(_ values: [UInt8], grid: [[Double]], season: Season) -> [Double] {
        grid.indices.map { c in Double(seasonMonths(season, lat: grid[c][0]).map { values[c * 12 + $0 - 1] }.max()!) / 255 }
    }
}
