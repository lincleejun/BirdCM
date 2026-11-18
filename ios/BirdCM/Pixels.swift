import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// 8-bit RGB pixels, row-major, no padding. Every resize and crop here copies what gardener does with PIL
/// (decode.fit, rules.crop_with_context / species_crops, open_clip's Resize + CenterCrop): if these drift,
/// the species answer drifts. mobile/check.py writes the Python side; PipelineTests compares the two.
struct RGB {
    var w: Int, h: Int
    var px: [UInt8]

    static func decodingEdge(width:Int,height:Int,limit:Int?) -> Int {
        guard let limit, Double(width)*Double(height)>24_000_000 else {return max(width,height)}
        return min(max(width,height),limit)
    }
    /// The photo upright (EXIF orientation applied), values as stored: no colour management, like PIL.
    static func load(_ data: Data, largePhotoLimit: Int? = nil) -> RGB? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: decodingEdge(width:w,height:h,limit:largePhotoLimit)] as CFDictionary)
        else { return nil }
        let space = img.colorSpace?.model == .rgb ? img.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: img.width * img.height * 4)
        guard let ctx = CGContext(data: &rgba, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        var px = [UInt8](repeating: 0, count: img.width * img.height * 3)
        for i in 0..<(img.width * img.height) {
            px[i * 3] = rgba[i * 4]; px[i * 3 + 1] = rgba[i * 4 + 1]; px[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return RGB(w: img.width, h: img.height, px: px)
    }

    /// gardener decode.fit: long edge to `edge` (Lanczos), never enlarged.
    func fit(_ edge: Int) -> RGB {
        let s = Double(edge) / Double(max(w, h))
        if s >= 1 { return self }
        return resized(Int((Double(w) * s).rounded(.toNearestOrEven)), Int((Double(h) * s).rounded(.toNearestOrEven)), .lanczos)
    }

    /// PIL Image.crop with integer corners already inside the image.
    func cropped(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> RGB {
        var out = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 3)
        for y in y0..<y1 {
            let src = (y * w + x0) * 3, dst = (y - y0) * (x1 - x0) * 3
            out[dst..<dst + (x1 - x0) * 3] = px[src..<src + (x1 - x0) * 3]
        }
        return RGB(w: x1 - x0, h: y1 - y0, px: out)
    }

    func paddedCrop(_ x0:Int,_ y0:Int,_ x1:Int,_ y1:Int) -> RGB {
        let left=max(0,x0), top=max(0,y0), right=min(w,x1), bottom=min(h,y1)
        let part=cropped(left,top,right,bottom)
        var sums=[Int](repeating:0,count:3)
        for i in part.px.indices { sums[i%3] += Int(part.px[i]) }
        let mean=sums.map{UInt8($0 / (part.w*part.h))}
        var out=RGB(w:x1-x0,h:y1-y0,px:Array(repeating:mean,count:(x1-x0)*(y1-y0)).flatMap{$0})
        for y in top..<bottom { for x in left..<right { for c in 0..<3 {
            out.px[((y-y0)*out.w+x-x0)*3+c]=px[(y*w+x)*3+c]
        } } }
        return out
    }

    /// open_clip's eval transform: torchvision Resize(224) (shortest side, long side truncated) + CenterCrop(224).
    func frame224() -> RGB {
        let (nw, nh) = w <= h ? (224, Int(224 * Double(h) / Double(w))) : (Int(224 * Double(w) / Double(h)), 224)
        let r = resized(nw, nh, .bicubic)
        let left = Int((Double(nw - 224) / 2).rounded(.toNearestOrEven)), top = Int((Double(nh - 224) / 2).rounded(.toNearestOrEven))
        return r.cropped(left, top, left + 224, top + 224)
    }

    enum Filter {
        case bilinear, bicubic, lanczos
        var support: Double { switch self { case .bilinear: 1; case .bicubic: 2; case .lanczos: 3 } }
        func callAsFunction(_ x: Double) -> Double {
            switch self {
            case .bilinear: let x = abs(x); return x < 1 ? 1 - x : 0
            case .bicubic:
                let a = -0.5, x = abs(x)
                if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
                return x < 2 ? (((x - 5) * x + 8) * x - 4) * a : 0
            case .lanczos:
                func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(x * .pi) / (x * .pi) }
                return -3 <= x && x < 3 ? sinc(x) * sinc(x / 3) : 0
            }
        }
    }

    /// PIL's Image.resize (libImaging/Resample.c, 8 bits): antialiased separable filter, horizontal pass first,
    /// fixed-point weights with 22 fraction bits, each pass rounded and clipped to 8 bits.
    func resized(_ ow: Int, _ oh: Int, _ f: Filter) -> RGB {
        if ow == w && oh == h { return self }
        var cur = self
        if ow != w { cur = cur.pass(ow, f, horizontal: true) }
        if oh != h { cur = cur.pass(oh, f, horizontal: false) }
        return cur
    }

    private func pass(_ out: Int, _ f: Filter, horizontal: Bool) -> RGB {
        let inSize = horizontal ? w : h, bits = 22
        let scale = Double(inSize) / Double(out), fscale = max(scale, 1), support = f.support * fscale
        var starts = [Int](repeating: 0, count: out), weights = [[Int]](repeating: [], count: out)
        for o in 0..<out {
            let center = (Double(o) + 0.5) * scale
            let lo = max(Int(center - support + 0.5), 0), hi = min(Int(center + support + 0.5), inSize)
            let ss = 1 / fscale
            var k = (lo..<hi).map { f((Double($0) - center + 0.5) * ss) }
            let sum = k.reduce(0, +)
            if sum != 0 { k = k.map { $0 / sum } }
            starts[o] = lo
            weights[o] = k.map { $0 < 0 ? Int(-0.5 + $0 * Double(1 << bits)) : Int(0.5 + $0 * Double(1 << bits)) }
        }
        let (nw, nh) = horizontal ? (out, h) : (w, out)
        var res = [UInt8](repeating: 0, count: nw * nh * 3)
        px.withUnsafeBufferPointer { src in
            res.withUnsafeMutableBufferPointer { dst in
                for y in 0..<nh {
                    for x in 0..<nw {
                        let o = horizontal ? x : y, k = weights[o], s0 = starts[o]
                        var r = 1 << (bits - 1), g = r, b = r
                        for (i, kk) in k.enumerated() {
                            let p = horizontal ? (y * w + s0 + i) * 3 : ((s0 + i) * w + x) * 3
                            r += Int(src[p]) * kk; g += Int(src[p + 1]) * kk; b += Int(src[p + 2]) * kk
                        }
                        let d = (y * nw + x) * 3
                        dst[d] = UInt8(clamping: r >> bits); dst[d + 1] = UInt8(clamping: g >> bits); dst[d + 2] = UInt8(clamping: b >> bits)
                    }
                }
            }
        }
        return RGB(w: nw, h: nh, px: res)
    }

    /// BGRA pixel buffer for a Core ML image input (the models read RGB and scale it themselves).
    func pixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h {
            for x in 0..<w {
                let s = (y * w + x) * 3, d = y * row + x * 4
                base[d] = px[s + 2]; base[d + 1] = px[s + 1]; base[d + 2] = px[s]; base[d + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    func cgImage() -> CGImage {
        let data = Data(px) as CFData
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// gardener rules.crop_with_context: the box plus 10 % context, squared, at least `minSide`, shifted inside the frame.
/// Returns the integer crop corners.
func cropWithContext(_ w: Int, _ h: Int, _ b: [Double], minSide: Double) -> (Int, Int, Int, Int) {
    let side=Int(max((b[2]-b[0])*1.2,(b[3]-b[1])*1.2,minSide).rounded(.toNearestOrEven))
    func start(_ center:Double,_ size:Int) -> Int {
        let lo=Int((center-Double(side)/2).rounded(.toNearestOrEven))
        return side > size ? lo : min(max(0,lo),size-side)
    }
    let x=start((b[0]+b[2])/2,w), y=start((b[1]+b[3])/2,h)
    return (x,y,x+side,y+side)
}
