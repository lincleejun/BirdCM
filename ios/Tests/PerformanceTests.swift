import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BirdCM

/// Memory and time of the identification path on a synthetic 48 MP photo (CC0 photo-4 scaled up), printed as BENCH lines.
final class PerformanceTests: XCTestCase {
    /// photo-4 (3000 x 4000, CC0) drawn at 6048 x 8064 and encoded; `orientation` is written as EXIF with the pixels stored
    /// rotated to match, so the upright picture is the same for every orientation.
    static func synthetic(_ type: UTType, width: Int = 6048, height: Int = 8064, orientation: Int = 1) throws -> Data {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(fixtures.appendingPathComponent("photo-4.png") as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let upright = CGSize(width: width, height: height), swap = orientation >= 5
        let (w, h) = swap ? (height, width) : (width, height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Raw pixels such that applying `orientation` gives the upright picture: draw through the inverse transform.
        let t = uprightTransform(orientation, size: CGSize(width: w, height: h)).inverted()
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(t)
        ctx.translateBy(x: 0, y: upright.height); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: upright))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// Peak phys_footprint above the level before `body`, and its duration.
    static func measure<T>(_ body: () throws -> T) rethrows -> (T, mb: Double, s: Double) {
        let base = Diagnostics.footprint(), m = MemorySample(), t = Date()
        let r = try autoreleasepool { try body() }
        let s = Date().timeIntervalSince(t), peak = m.stop()
        return (r, Double(peak > base ? peak - base : 0) / 1e6, s)
    }

    /// Always on: a 48 MP photo never decodes at full size, for the frame or for a small bird.
    func test48MPPeakMemory() throws {
        let data = try Self.synthetic(.heic)
        let (photo, photoMB, _) = try Self.measure { try XCTUnwrap(Photo(data: data)) }
        XCTAssertEqual([photo.frame.w, photo.frame.h], [1536, 2048]); XCTAssertEqual([photo.size.w, photo.size.h], [6048, 8064])
        let w = Double(photo.frame.w), h = Double(photo.frame.h)
        let (c, cropMB, _) = Self.measure { Engine.crop(photo, [w * 0.4, h * 0.4, w * 0.41, h * 0.41]) }
        XCTAssertEqual([c.source.w, c.source.h], [6048, 8064]); XCTAssertEqual(c.size.0, 320)
        // Full decodes were 195 MB (RGBA) + 146 MB (RGB) for the small box alone.
        XCTAssertLessThan(photoMB, 120); XCTAssertLessThan(cropMB, 40)
    }

    /// 性能自测 with the CPU setting: every model gets a row from the app-bundled CC0 photos, and the 48 MP preprocessing steps.
    func testSelfTestCPU() throws {
        let (rows, steps) = try SelfTest.run(units: ["cpuOnly"])
        XCTAssertEqual(rows.map(\.model), ["Detector", "BioCLIP", "Heads"])
        for r in rows { XCTAssertNil(r.error, r.model); XCTAssertGreaterThan(r.warm, 0, r.model) }
        XCTAssertEqual(try XCTUnwrap(rows[1].cosine), 1, accuracy: 1e-6)
        XCTAssertEqual(steps.count, 4)
        print(rows.map { String(format: "BENCH selftest %@ load %.2f s first %.3f s warm %.3f s peak %.0f MB", $0.model, $0.load, $0.first, $0.warm, $0.peakMB) }.joined(separator: "\n"))
        print(steps.map { String(format: "BENCH selftest %@ %.3f s %.0f MB", $0.name, $0.seconds, $0.peakMB) }.joined(separator: "\n"))
    }

    /// BENCH lines for the report; slow, so only with TEST_RUNNER_BIRDCM_BENCH=1.
    func testBench48MP() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BIRDCM_BENCH"] != nil)
        let engine = try Engine(dir: Models.dir)
        _ = try engine.speciesModel(); _ = try engine.headsModel()
        _ = try engine.warmUp()
        for (name, type, w, h) in [("12MP HEIC", UTType.heic, 3024, 4032), ("24MP HEIC", .heic, 4284, 5712), ("48MP HEIC", .heic, 6048, 8064), ("48MP JPEG", .jpeg, 6048, 8064)] {
            let data = try Self.synthetic(type, width: w, height: h)
            let (photo, decodeMB, decodeS) = try Self.measure { try XCTUnwrap(Photo(data: data)) }
            let fw = Double(photo.frame.w), fh = Double(photo.frame.h)
            let small = [fw * 0.4, fh * 0.4, fw * 0.41, fh * 0.41], large = [fw * 0.2, fh * 0.3, fw * 0.7, fh * 0.7]
            let (_, smallMB, smallS) = Self.measure { Engine.crop(photo, small) }
            let (_, largeMB, largeS) = Self.measure { Engine.crop(photo, large) }
            let (_, detectMB, detectS) = try Self.measure { try engine.detect(photo) }
            let (_, idMB, idS) = try Self.measure { try engine.identify(photo, box: large) }
            let (_, idSmallMB, idSmallS) = try Self.measure { try engine.identify(photo, box: small) }
            print(String(format: "BENCH %@ (%.1f MB file) frame %dx%d: Photo %.0f MB %.3f s | crop small %.0f MB %.3f s, large %.0f MB %.3f s | detect %.0f MB %.3f s | identify large %.0f MB %.3f s, small %.0f MB %.3f s",
                         name, Double(data.count) / 1e6, photo.frame.w, photo.frame.h, decodeMB, decodeS, smallMB, smallS, largeMB, largeS, detectMB, detectS, idMB, idS, idSmallMB, idSmallS))
        }
        // The Swift (PIL-port) resampling steps on their own.
        let full = try XCTUnwrap(RGB.load(Data(contentsOf: fixtures.appendingPathComponent("photo-4.png"))))   // 3000 x 4000
        let t0 = Date(); let frame = full.fit(2048); let fitS = Date().timeIntervalSince(t0)
        let t1 = Date(); _ = frame.resized(640, 640, .bilinear).pixelBuffer(); let detS = Date().timeIntervalSince(t1)
        var cropS = [String]()
        for side in [320, 700, 1400] {
            let sq = frame.cropped(0, 0, side, side), t = Date(); _ = sq.frame224().pixelBuffer()
            cropS.append(String(format: "%d px %.4f s", side, Date().timeIntervalSince(t)))
        }
        print(String(format: "BENCH resample: 3000x4000 -> 2048 Lanczos %.3f s | frame -> 640 bilinear + buffer %.3f s | crop -> 224 bicubic + buffer: ", fitS, detS) + cropS.joined(separator: ", "))
    }

    /// Time per photo for 1, 3 and 6 birds (every bird identified).
    func testBenchBirds() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BIRDCM_BENCH"] != nil)
        let engine = try Engine(dir: Models.dir)
        _ = try engine.speciesModel(); _ = try engine.headsModel(); _ = try engine.warmUp()
        let photo = try XCTUnwrap(Photo(data: Data(contentsOf: fixtures.appendingPathComponent("photo-4.png"))))
        let fw = Double(photo.frame.w), fh = Double(photo.frame.h)
        let boxes = (0..<6).map { i -> [Double] in let x = Double(i % 2) * 0.45 + 0.05, y = Double(i / 2) * 0.3 + 0.05; return [x * fw, y * fh, (x + 0.4) * fw, (y + 0.25) * fh] }
        for n in [1, 3, 6] {
            let t = Date()
            for b in boxes.prefix(n) { _ = try engine.identify(photo, box: b) }
            let one = Date().timeIntervalSince(t), t2 = Date()
            let batched = try engine.identify(photo, boxes: Array(boxes.prefix(n)))
            print(String(format: "BENCH birds %d: one call each %.3f s, one batch %.3f s", n, one, Date().timeIntervalSince(t2)))
            for (b, id) in zip(boxes.prefix(n), batched) {
                let single = try engine.identify(photo, box: b)
                XCTAssertEqual(id.top5, single.top5); XCTAssertEqual(id.level, single.level); XCTAssertEqual(id.eye, single.eye); XCTAssertEqual(id.flying, single.flying)
            }
        }
    }
}
