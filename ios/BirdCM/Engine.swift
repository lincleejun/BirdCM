import Accelerate
import CoreML
import Foundation
import UniformTypeIdentifiers
import ImageIO

/// One photo, decoded the way gardener's decode does: `frame` has a long edge <= 2048 (boxes live in its pixels),
/// Small boxes decode the original again only when needed, matching desktop pipeline.SMALL_BOX.
struct Photo {
    let frame: RGB
    let data: Data

    init?(data: Data) {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              let kind=CGImageSourceGetType(source), let type=UTType(kind as String), !type.conforms(to:.rawImage),
              let full = RGB.load(data,largePhotoLimit:4096) else { return nil }
        frame = full.fit(2048)
        self.data=data
    }
}

struct Candidate: Codable, Hashable {
    var scientific: String, english: String, chinese: String, p: Double
}

struct Identification: Codable {
    var top5: [Candidate]
    var level: String            // species / genus / uncertain (committed desktop thresholds)
    var name: String?            // species or genus named at that level
    var flying: Double?          // nil without the heads file
    var beak: [Double]?          // points in the frame, 0..1 of its width / height; nil when not visible or no heads
    var eye: [Double]?
    var visibility: [Double]?
    var clear: Bool?
    var rare = false
    var reason: String?
    var genusP: Double?
    var rarity: RarityValue?
    var diagnostics: DiagnosticRun?
    var priorUnknown: Bool?
    var visual: [Double]?
}

final class Engine: @unchecked Sendable {
    static let threshold: Float = 0.25           // D-FINE bird score; T/2 when nothing reaches it (distill/detectors.py)
    static let logitScale: Float = 98.8644790649414
    let detector: MLModel, heads: MLModel?
    private var bioclip: MLModel?
    private let modelLock=NSLock()
    private let modelDir: URL
    private let configuration: MLModelConfiguration
    func releaseBioCLIP() { modelLock.lock(); bioclip=nil; embedding=nil; modelLock.unlock() }
    func speciesModel() throws -> MLModel {
        modelLock.lock(); defer{modelLock.unlock()}
        if let bioclip {return bioclip}
        let model=try MLModel(contentsOf:Self.compiled(modelDir,"BioCLIP"),configuration:configuration)
        bioclip=model; return model
    }
    let names: [Float]                           // 11,172 x 1024, row-major
    var rows: [[String]]                         // scientific, English, Chinese, genus, family
    var geo: Geo?
    var rarity: Rarity?
    var loadSeconds: Double = 0
    var loadPeakBytes: UInt64 = 0
    let clearWeights = resource("clear", as: [String:[Double]].self)
    private var embedding: [Float]?
    var lastEmbedding: [Float]? {modelLock.lock();defer{modelLock.unlock()};return embedding}     // for pipeline reference tests

    init(dir: URL) throws {
        let started = Date(), memory = MemorySample()
        defer { _ = memory.stop() }
        let cfg = MLModelConfiguration()
        switch Diagnostics.compute {
        case "cpuOnly": cfg.computeUnits = .cpuOnly
        case "cpuAndGPU": cfg.computeUnits = .cpuAndGPU
        case "cpuAndNeuralEngine": cfg.computeUnits = .cpuAndNeuralEngine
        default: cfg.computeUnits = .all
        }
        #if targetEnvironment(simulator)
        cfg.computeUnits = .cpuOnly
        #endif
        modelDir=dir; configuration=cfg
        var tick=Date()
        func lap(_ n:String) { Perf.mark("load."+n,Date().timeIntervalSince(tick)); tick=Date() }
        detector = try MLModel(contentsOf: try Self.compiled(dir, "Detector"), configuration: cfg); lap("detector")
        bioclip = try MLModel(contentsOf: try Self.compiled(dir, "BioCLIP"),  configuration: cfg); lap("bioclip")
        heads = FileManager.default.fileExists(atPath: dir.appendingPathComponent("Heads.mlmodelc").path)
            ? try MLModel(contentsOf: try Self.compiled(dir, "Heads"), configuration: cfg) : nil
        lap("heads")
        let raw = try Data(contentsOf: dir.appendingPathComponent("names.f16"))
        names = raw.withUnsafeBytes { $0.bindMemory(to: Float16.self).map(Float.init) }
        lap("names.f16")
        let zh = Dictionary(uniqueKeysWithValues: resource("zh-names", as: [[String:String]].self).map{($0["scientific"]!, $0["zh"]!)})
        rows = try String(contentsOf: dir.appendingPathComponent("names.tsv"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard names.count == rows.count * 1024, rows.count == 11172, rows.allSatisfy({$0.count >= 5}) else { throw CocoaError(.fileReadCorruptFile) }
        rows = rows.map { r in var row = r; row[2] = zh[row[0]] ?? ""; return row }
        lap("names.tsv")
        if FileManager.default.fileExists(atPath:Models.geoURL.path) { geo = try Geo(weights:Models.geoURL,scientific:rows.map{$0[0]}) }
        lap("geo")
        if FileManager.default.fileExists(atPath:Models.rarityURL.path) { rarity = try Rarity(path:Models.rarityURL) }
        lap("rarity")
        loadSeconds = Date().timeIntervalSince(started); loadPeakBytes = memory.stop()
    }

    /// Build-time compiled models stay in the signed application bundle.
    static func compiled(_ dir: URL, _ name: String) throws -> URL {
        let url=dir.appendingPathComponent(name+".mlmodelc")
        guard FileManager.default.fileExists(atPath:url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return url
    }
    func rerank(_ cached: Identification, place: Place?, shooting: Shooting) throws -> Identification {
        guard let visual=cached.visual else { throw NSError(domain:"BirdCM",code:8,userInfo:[NSLocalizedDescriptionKey:"旧记录还不支持更改地点，请重新选择这张照片识别一次。"] ) }
        let spread:GeoSpread?
        if let place {
            guard let geo else {throw CocoaError(.fileReadNoSuchFile)}
            spread=try geo.spread(place,date:shooting.takenAt)
        } else {spread=nil}
        var id=Confirm.decide(p:Confirm.posterior(visual,spread?.wide),rows:rows,wide:spread?.wide,typical:spread?.typical)
        id.visual=visual; id.clear=cached.clear; id.eye=cached.eye; id.beak=cached.beak
        id.flying=cached.flying; id.visibility=cached.visibility; id.diagnostics=cached.diagnostics
        if cached.clear == false { id.reason="鸟的特征不够清楚，请核对候选或手动画框。" }
        if id.level=="species" {id.rarity=rarity?.lookup(id.top5[0].scientific,place:place,month:shooting.month)}
        return id
    }

    func detect(_ photo: Photo) throws -> [[Double]] {
        let f = photo.frame
        let out = try detector.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: f.resized(640, 640, .bilinear).pixelBuffer())]))
        let scores = floats(out.featureValue(for: "scores")!.multiArrayValue!)
        let boxes = floats(out.featureValue(for: "boxes")!.multiArrayValue!)
        for t in [Self.threshold, Self.threshold / 2] {
            var found=[[Double]](), confidence=[Double]()
            for i in scores.indices where scores[i]>=t {
                let raw=(0..<4).map{Double(boxes[i*4+$0])}
                guard raw.allSatisfy({$0.isFinite}) else{continue}
                let box=raw.enumerated().map{min(1,max(0,$0.element))*Double($0.offset%2==0 ? f.w:f.h)}
                guard box[2]>box[0],box[3]>box[1] else{continue}
                found.append(box);confidence.append(Double(scores[i]))
            }
            let keep=displaySubjects(found,scores:confidence)
            if !keep.isEmpty {return keep}
        }
        return []
    }

    /// What BioCLIP sees for one box (gardener species_crops + open_clip's framing), and where that crop sits.
    static func needsHighResolution(_ box:[Double]) -> Bool {max(box[2]-box[0],box[3]-box[1]) < 128}

    func crop(_ photo: Photo, _ box: [Double]) -> (image: RGB, origin: (Double, Double), size: (Double, Double), source: RGB) {
        var src = photo.frame, b = box, minSide = 320.0
        if Self.needsHighResolution(box), let d=RGB.load(photo.data), max(d.w,d.h)>max(src.w,src.h) {
            let sx = Double(d.w) / Double(src.w), sy = Double(d.h) / Double(src.h)
            b = [box[0] * sx, box[1] * sy, box[2] * sx, box[3] * sy]
            minSide = 320
            src = d
        }
        let (x0, y0, x1, y1) = cropWithContext(src.w, src.h, b, minSide: minSide)
        return (src.paddedCrop(x0, y0, x1, y1).frame224(), (Double(x0), Double(y0)), (Double(x1 - x0), Double(y1 - y0)), src)
    }

    func identify(_ photo: Photo, box: [Double], place: Place? = nil, shooting: Shooting? = nil, manual: Bool = false) throws -> Identification {
        let memory = MemorySample(), started = Date()
        defer { _ = memory.stop() }
        var diag = DiagnosticRun()
        var tick = Date()
        let c = crop(photo, box)
        let out = try speciesModel().prediction(from: try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: c.image.pixelBuffer())]))
        diag.stages["BioCLIP"] = Date().timeIntervalSince(tick); tick = Date()
        let e = floats(out.featureValue(for: "embedding")!.multiArrayValue!)
        modelLock.lock(); embedding = e; modelLock.unlock()
        var logits = [Float](repeating: 0, count: rows.count)
        vDSP_mmul(names, 1, e, 1, &logits, 1, vDSP_Length(rows.count), 1, 1024)
        let m = logits.max()!
        var p = logits.map { exp(Self.logitScale * ($0 - m)) }
        let sum = p.reduce(0, +)
        p = p.map { $0 / sum }
        let visual = p.map(Double.init)
        diag.stages["名录"] = Date().timeIntervalSince(tick); tick = Date()
        let spread = try place.map { p -> GeoSpread in
            guard let geo else { throw NSError(domain:"BirdCM",code:1,userInfo:[NSLocalizedDescriptionKey:"安装包缺少地点模型，请重新安装完整 App。"] ) }
            return try geo.spread(p,date:shooting?.takenAt)
        }
        diag.stages["地点先验"] = Date().timeIntervalSince(tick); tick = Date()
        var id = Confirm.decide(p:Confirm.posterior(visual,spread?.wide), rows:rows, wide:spread?.wide,typical:spread?.typical)
        let h = clearWeights
        let z = e.indices.reduce(h["bias"]![0]) { $0 + ((Double(e[$1])-h["mean"]![$1])/h["std"]![$1])*h["weight"]![$1] }
        id.clear = z >= h["z_min"]![0] && Double(m) >= h["cos_min"]![0]
        if !manual && id.clear == false { id.reason = "鸟的特征不够清楚，请核对候选或手动画框。" }
        id.visual=visual
        if id.level == "species" { id.rarity = rarity?.lookup(id.top5[0].scientific,place:place,month:shooting?.month) ?? RarityValue(label:"数据不足",iucn:nil) }
        if let heads {
            let h = try heads.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["tokens15": out.featureValue(for: "tokens15")!]))
            let pts = Self.points(h)
            id.visibility = pts.visible
            id.flying = Double(floats(h.featureValue(for: "flying")!.multiArrayValue!)[0])
            // 224 frame -> crop -> source image -> 0..1 (the same for frame and detail: one is a scaled copy of the other)
            let rw = c.size.0 <= c.size.1 ? 224 : Double(Int(224 * c.size.0 / c.size.1)), rh = c.size.0 <= c.size.1 ? Double(Int(224 * c.size.1 / c.size.0)) : 224
            let left = ((rw - 224) / 2).rounded(.toNearestOrEven), top = ((rh - 224) / 2).rounded(.toNearestOrEven)
            let place = { (q: [Double]) -> [Double] in
                [((q[0] + left) * c.size.0 / rw + c.origin.0) / Double(c.source.w), ((q[1] + top) * c.size.1 / rh + c.origin.1) / Double(c.source.h)]
            }
            if pts.visible[0] >= 0.5 { id.beak = place(pts.xy[0]) }
            let eye = pts.visible[1] >= pts.visible[2] ? 1 : 2      // the more confident eye (parts.py score())
            if pts.visible[eye] >= 0.5 { id.eye = place(pts.xy[eye]) }
        }
        if id.clear == false { id.flying = nil; id.eye = nil; id.beak = nil; id.visibility = nil }
        diag.stages["小头与查表"] = Date().timeIntervalSince(tick)
        diag.stages["当前主体总计"] = Date().timeIntervalSince(started)
        diag.peakBytes = memory.stop(); id.diagnostics = diag
        return id
    }

    /// Beak / left eye / right eye in the 224 px frame and their visible probabilities.
    static func points(_ h: MLFeatureProvider) -> (xy: [[Double]], visible: [Double]) {
        let heat = floats(h.featureValue(for: "heat")!.multiArrayValue!)          // 256 x 3
        let off = floats(h.featureValue(for: "offset")!.multiArrayValue!)         // 256 x 3 x 2
        let vis = floats(h.featureValue(for: "visible")!.multiArrayValue!)        // 3
        let xy = (0..<3).map { k -> [Double] in
            let cell = (0..<256).max { heat[$0 * 3 + k] < heat[$1 * 3 + k] }!
            return [(Double(cell % 16) + Double(off[(cell * 3 + k) * 2])) * 14, (Double(cell / 16) + Double(off[(cell * 3 + k) * 2 + 1])) * 14]
        }
        return (xy, vis.map { 1 / (1 + exp(-Double($0))) })
    }


}

/// Float32 or float16 outputs (which one a model gives depends on its precision) as [Float].
func floats(_ a: MLMultiArray) -> [Float] {
    a.dataType == .float16 ? MLShapedArray<Float16>(a).scalars.map(Float.init) : MLShapedArray<Float>(a).scalars
}

func area(_ b: [Double]) -> Double { (b[2] - b[0]) * (b[3] - b[1]) }

func iou(_ a: [Double], _ b: [Double]) -> Double {
    let w = max(0, min(a[2], b[2]) - max(a[0], b[0])), h = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    let u = area(a) + area(b) - w * h
    return u > 0 ? w * h / u : 0
}
