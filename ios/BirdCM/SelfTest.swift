import CoreML
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 诊断 → 性能自测: the bundled CC0 photos (Tests/Fixtures/photos.json) through every compute-unit setting of each
/// model, each with a fresh MLModel. Uses nothing of the records, the library or the stored compute-unit choice, so the
/// owner can run it once on the phone and send a screenshot; the per-model defaults (Diagnostics.defaultUnits) follow.
enum SelfTest {
    struct Row: Identifiable {
        let id = UUID()
        let model: String, units: String
        var load = 0.0, first = 0.0, warm = 0.0, peakMB = 0.0
        var cosine: Double?           // BioCLIP: lowest embedding cosine to cpuOnly over the photos
        var error: String?
    }
    struct Step: Identifiable { let id = UUID(); let name: String; let seconds: Double; let peakMB: Double }
    static let photos = ["photo-0", "photo-1", "photo-2", "photo-3"]

    /// Peak phys_footprint above the level before `body`, and its duration.
    static func measure<T>(_ body: () throws -> T) rethrows -> (T, mb: Double, s: Double) {
        let base = Diagnostics.footprint(), m = MemorySample(), t = Date()
        let r = try autoreleasepool { try body() }
        let s = Date().timeIntervalSince(t), peak = m.stop()
        return (r, Double(peak > base ? peak - base : 0) / 1e6, s)
    }

    /// The bundled photo-0 drawn at 6048 x 8064 (48 MP) and encoded as HEIC, as an iPhone 48 MP photo would arrive.
    static func synthetic48MP(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: 6048, height: 8064, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 6048, height: 8064))
        let out = NSMutableData()
        guard let big = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, big, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func run(dir: URL = Models.dir, units: [String] = Diagnostics.unitNames, models: [String] = Diagnostics.models,
                    progress: (String) -> Void = { _ in }) throws -> (rows: [Row], steps: [Step]) {
        let files = try photos.map { name -> Data in
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { throw CocoaError(.fileReadNoSuchFile) }
            return try Data(contentsOf: url)
        }
        // Preprocessing, on a synthetic 48 MP HEIC (the app's own code path, fixed boxes).
        progress("合成 48 MP HEIC")
        var steps = [Step]()
        if let big = synthetic48MP(files[0]) {
            let (photo, mb, s) = measure { Photo(data: big) }
            steps.append(Step(name: "48 MP HEIC → 2048 帧", seconds: s, peakMB: mb))
            if let photo {
                let w = Double(photo.frame.w), h = Double(photo.frame.h)
                let (_, dmb, ds) = measure { photo.frame.resized(640, 640, .bilinear).pixelBuffer() }
                steps.append(Step(name: "检测输入 640", seconds: ds, peakMB: dmb))
                for (name, box) in [("大鸟裁剪 → 224", [w * 0.2, h * 0.3, w * 0.7, h * 0.7]), ("小鸟只解码区域 → 224", [w * 0.4, h * 0.4, w * 0.41, h * 0.41])] {
                    let (_, cmb, cs) = measure { Engine.crop(photo, box).image.pixelBuffer() }
                    steps.append(Step(name: name, seconds: cs, peakMB: cmb))
                }
            }
        }
        // Model inputs from the CC0 photos: the detector's 640 frame, BioCLIP's 224 crop of the whole photo, heads' tokens.
        let frames = files.compactMap { Photo(data: $0)?.frame }
        let detectorInputs: [MLFeatureProvider] = try frames.map { try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: $0.resized(640, 640, .bilinear).pixelBuffer())]) }
        let crops: [MLFeatureProvider] = try frames.map { f in
            let (x0, y0, x1, y1) = cropWithContext(f.w, f.h, [0, 0, Double(f.w), Double(f.h)], minSide: 320)
            return try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: f.paddedCrop(x0, y0, x1, y1).frame224().pixelBuffer())])
        }
        var tokens = [MLFeatureProvider](), embeddings = [String: [[Float]]]()
        var rows = [Row]()
        for model in models {
            for unit in units {
                progress("\(model) · \(unit)")
                var row = Row(model: model, units: unit)
                let inputs: [MLFeatureProvider] = model == "Detector" ? detectorInputs : model == "BioCLIP" ? crops : tokens
                if inputs.isEmpty { row.error = "缺少输入"; rows.append(row); continue }
                do {
                    let (outs, mb, _) = try measure { () -> [MLFeatureProvider] in
                        let cfg = MLModelConfiguration(); cfg.computeUnits = Diagnostics.units(unit)
                        var t = Date()
                        let m = try MLModel(contentsOf: Engine.compiled(dir, model), configuration: cfg)
                        row.load = Date().timeIntervalSince(t); t = Date()
                        var outs = [try m.prediction(from: inputs[0])]
                        row.first = Date().timeIntervalSince(t)
                        // Warm: two rounds over the photos after the first prediction.
                        let warm = Array(inputs.dropFirst()) + inputs; t = Date()
                        for (i, input) in warm.enumerated() { let o = try m.prediction(from: input); if i < inputs.count - 1 { outs.append(o) } }
                        row.warm = Date().timeIntervalSince(t) / Double(warm.count)
                        return outs
                    }
                    row.peakMB = mb
                    if model == "BioCLIP" {
                        if tokens.isEmpty { tokens = try outs.map { try MLDictionaryFeatureProvider(dictionary: ["tokens15": $0.featureValue(for: "tokens15")!]) } }
                        embeddings[unit] = outs.map { floats($0.featureValue(for: "embedding")!.multiArrayValue!) }
                    }
                } catch { row.error = error.localizedDescription }
                rows.append(row)
            }
        }
        if let reference = embeddings["cpuOnly"] {
            for i in rows.indices where rows[i].model == "BioCLIP" {
                guard let e = embeddings[rows[i].units] else { continue }
                rows[i].cosine = zip(e, reference).map { a, b in
                    let dot = { (x: [Float], y: [Float]) in Double(zip(x, y).map { $0 * $1 }.reduce(0, +)) }
                    return dot(a, b) / (dot(a, a) * dot(b, b)).squareRoot()
                }.min()
            }
        }
        return (rows, steps)
    }
}

struct SelfTestView: View {
    @Environment(AppModel.self) var model
    @State private var running = false
    @State private var progress = ""
    @State private var result: (rows: [SelfTest.Row], steps: [SelfTest.Step])?
    @State private var error: String?
    static let shortUnits = ["all": "all", "cpuAndNeuralEngine": "CPU+ANE", "cpuAndGPU": "CPU+GPU", "cpuOnly": "CPU"]
    static let shortModels = ["Detector": "检测", "BioCLIP": "BioCLIP", "Heads": "小头"]
    var body: some View {
        List {
            Section {
                Text("用随 App 附带的 4 张 CC0 照片，逐个模型、逐个计算单元设置（all / CPU+ANE / CPU+GPU / CPU）测加载、首次与预热后单次预测用时和峰值内存，另测 48 MP 照片的预处理。不读写你的记录，不改设置。约需 1–3 分钟（首次用神经网络引擎时系统要编译模型），请保持在本页并截图发给开发者。").font(.caption)
                Button(running ? "正在测：\(progress)" : "开始性能自测") { start() }
                    .disabled(running || model.busy).accessibilityIdentifier("selfTest.start")
                if let error { Text(error).font(.caption).foregroundStyle(Palette.warning) }
            }
            if let result {
                Section("\(Self.device) · iOS \(UIDevice.current.systemVersion)") {
                    Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 4) {
                        GridRow { Text("模型").gridColumnAlignment(.leading); Text("单元").gridColumnAlignment(.leading); Text("加载"); Text("首次"); Text("预热"); Text("峰值"); Text("余弦") }.bold()
                        ForEach(result.rows) { r in
                            GridRow {
                                Text(Self.shortModels[r.model] ?? r.model); Text(Self.shortUnits[r.units] ?? r.units)
                                if let e = r.error { Text(e).lineLimit(2).gridCellColumns(5) } else {
                                    Text(Self.ms(r.load)); Text(Self.ms(r.first)); Text(Self.ms(r.warm))
                                    Text(String(format: "%.0f M", r.peakMB)); Text(r.cosine.map { String(format: "%.4f", $0) } ?? "—")
                                }
                            }
                        }
                    }.font(.caption2.monospacedDigit()).accessibilityIdentifier("selfTest.table")
                    Text("加载为建立模型用时；首次、预热为每次预测用时；峰值为加载与预测期间比开始时多出的内存；余弦为 BioCLIP 输出与 CPU 的最低一致性（1 = 相同）。").font(.caption2)
                }
                Section("预处理 · 当前 App 的做法") {
                    Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(result.steps) { s in GridRow { Text(s.name).gridColumnAlignment(.leading); Text(Self.ms(s.seconds)); Text(String(format: "%.0f M", s.peakMB)) } }
                    }.font(.caption2.monospacedDigit())
                }
                Section("当前设置") { Text(Diagnostics.compute).font(.caption2) }
            }
        }.navigationTitle("性能自测")
    }
    static func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }
    static var device: String {
        var u = utsname(); uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    func start() {
        running = true; error = nil; result = nil
        UIApplication.shared.isIdleTimerDisabled = true
        model.engine?.releaseBioCLIP()      // one 600 MB tower at a time; the next identification reloads it
        #if targetEnvironment(simulator)
        let units = ["cpuOnly"]             // the simulator runs everything on the CPU anyway
        #else
        let units = Diagnostics.unitNames
        #endif
        Task {
            do {
                let r = try await Task.detached { try SelfTest.run(units: units) { p in Task { @MainActor in progress = p } } }.value
                result = r
            } catch { self.error = "自测失败：\(error.localizedDescription)" }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
