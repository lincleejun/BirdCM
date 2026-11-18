import CoreLocation
import ImageIO
import Photos
import UniformTypeIdentifiers
import Vision

/// Display only. The model's padded square remains cropWithContext in Pixels.swift.
struct DisplayCrop: Equatable {
    let rect: CGRect // upright original pixels, top-left origin
    let tiny: Bool
    static func make(size: CGSize, box: [Double]) -> DisplayCrop {
        let b=CGRect(x:box[0]*size.width,y:box[1]*size.height,width:(box[2]-box[0])*size.width,height:(box[3]-box[1])*size.height)
        let margin=max(b.width,b.height)*0.35 // room for surroundings, not just the tail
        let w=b.width+2*margin, h=b.height+2*margin
        let candidates=[1.0,0.8,1.5].map {ratio -> CGSize in
            CGSize(width:max(w,h*ratio),height:max(h,w/ratio))
        }
        var best=candidates.min{$0.width*$0.height < $1.width*$1.height}!
        // A small bird gets a little more context, never the whole frame: at most 1.5x, aiming at 320 px.
        let long=max(best.width,best.height), tiny=long<320
        let scale=min(1.5,max(1,320/long));best.width *= scale;best.height *= scale
        // Shift at edges; only a source smaller than the window can constrain its size.
        let cw=min(size.width,ceil(best.width)), ch=min(size.height,ceil(best.height))
        let x=min(max(0,floor(b.midX-cw/2)),size.width-cw), y=min(max(0,floor(b.midY-ch/2)),size.height-ch)
        return DisplayCrop(rect:CGRect(x:x,y:y,width:cw,height:ch),tiny:tiny)
    }
    func normalized(in size:CGSize) -> [Double] { [rect.minX/size.width,rect.minY/size.height,rect.maxX/size.width,rect.maxY/size.height] }
}

/// The single top-left normalized transform for boxes, eye/beak and mask selection.
struct CropCoordinates {
    let window: [Double]
    func local(_ point:[Double]) -> [Double] {[(point[0]-window[0])/(window[2]-window[0]),(point[1]-window[1])/(window[3]-window[1])]}
    func original(_ point:[Double]) -> [Double] {[window[0]+point[0]*(window[2]-window[0]),window[1]+point[1]*(window[3]-window[1])]}
    func box(_ b:[Double]) -> [Double] {local(Array(b.prefix(2)))+local(Array(b.suffix(2)))}
    func record(_ source:Record,index:Int) -> Record {
        var r=source;r.boxes=[]
        r.result=source.results[String(index)] ?? (source.selected==index ? source.result:nil)
        let eye=r.result?.eye.map(local),beak=r.result?.beak.map(local)
        r.result?.eye=eye;r.result?.beak=beak
        return r
    }
}

/// Suppress duplicate detections; preserve the strongest size × score subject, then descending area.
func displaySubjects(_ boxes:[[Double]], scores:[Double]) -> [[Double]] {
    func area(_ b:[Double])->Double {(b[2]-b[0])*(b[3]-b[1])}
    var kept=[Int]()
    for i in boxes.indices.sorted(by:{area(boxes[$0])*scores[$0] > area(boxes[$1])*scores[$1]}) {
        let a=boxes[i]
        if kept.allSatisfy({j in
            let b=boxes[j], intersection=max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
            return intersection/(area(a)+area(b)-intersection)<=0.5 && intersection/min(area(a),area(b))<0.9
        }) {kept.append(i)}
    }
    guard let first=kept.first else{return []}
    return ([first]+kept.dropFirst().sorted{area(boxes[$0])>area(boxes[$1])}).map{boxes[$0]}
}

/// Raw top-left pixels → upright top-left pixels for all eight EXIF orientations.
func uprightTransform(_ orientation:Int,size:CGSize) -> CGAffineTransform {
    let w=size.width,h=size.height
    switch orientation {
    case 2:return CGAffineTransform(a:-1,b:0,c:0,d:1,tx:w,ty:0)
    case 3:return CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:w,ty:h)
    case 4:return CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:h)
    case 5:return CGAffineTransform(a:0,b:1,c:1,d:0,tx:0,ty:0)
    case 6:return CGAffineTransform(a:0,b:1,c:-1,d:0,tx:h,ty:0)
    case 7:return CGAffineTransform(a:0,b:-1,c:-1,d:0,tx:h,ty:w)
    case 8:return CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:w)
    default:return .identity
    }
}

struct CropSource {
    let url: URL
    let size: CGSize
    let properties: [CFString:Any]
    init?(_ url:URL) {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let p=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any],
              let w=p[kCGImagePropertyPixelWidth] as? Int,let h=p[kCGImagePropertyPixelHeight] as? Int else{return nil}
        self.url=url;properties=p
        let swap=(p[kCGImagePropertyOrientation] as? Int ?? 1)>=5
        size=CGSize(width:swap ? h:w,height:swap ? w:h)
    }
    func crop(_ box:[Double]) -> DisplayCrop {DisplayCrop.make(size:size,box:box)}
    func image(window:[Double],edge:Int?=nil,mask:CGImage?=nil) -> CGImage? {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let raw=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCache:false,kCGImageSourceShouldCacheImmediately:false] as CFDictionary) else{return nil}
        if window == [0,0,1,1],let edge {
            return CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:min(edge,Int(max(size.width,size.height)))] as CFDictionary)
        }
        let orientation=properties[kCGImagePropertyOrientation] as? Int ?? 1
        let transform=uprightTransform(orientation,size:CGSize(width:raw.width,height:raw.height))
        let x=(window[0]*size.width).rounded(),y=(window[1]*size.height).rounded()
        let r=CGRect(x:x,y:y,width:(window[2]*size.width).rounded()-x,height:(window[3]*size.height).rounded()-y)
        // Crop the lazy ImageIO provider BEFORE decoding/rendering and applying EXIF. Retain only this region.
        let region=r.applying(transform.inverted()).integral
        guard let part=raw.cropping(to:region) else{return nil}
        let scale:CGFloat=edge.map{min(CGFloat(1),CGFloat($0)/max(r.width,r.height))} ?? CGFloat(1)
        let w=max(1,Int((r.width*scale).rounded())),h=max(1,Int((r.height*scale).rounded()))
        guard let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
        if let mask {ctx.clip(to:CGRect(x:0,y:0,width:w,height:h),mask:mask)}
        ctx.translateBy(x:0,y:Double(h));ctx.scaleBy(x:Double(w)/r.width,y:-Double(h)/r.height)
        ctx.concatenate(uprightTransform(orientation,size:CGSize(width:part.width,height:part.height)))
        ctx.translateBy(x:0,y:Double(part.height));ctx.scaleBy(x:1,y:-1)
        ctx.interpolationQuality = .high
        ctx.draw(part,in:CGRect(x:0,y:0,width:part.width,height:part.height))
        return ctx.makeImage()
    }
    func thumbnail(_ record:Record,edge:Int=120) -> CGImage? {
        let window=record.displayCrops?.first ?? record.boxes.first.map{crop($0).normalized(in:size)} ?? [0,0,1,1]
        return image(window:window,edge:edge)
    }
    func export(window:[Double],name:String,mask:CGImage?=nil) throws -> URL {
        guard let image=image(window:window,mask:mask) else {throw CocoaError(.fileReadCorruptFile)}
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("BirdExports")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        for file in (try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] {
            if let date=try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>86400 {try? FileManager.default.removeItem(at:file)}
        }
        let output=dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(mask == nil ? "jpg":"png")
        let type=mask == nil ? UTType.jpeg:UTType.png
        guard let dest=CGImageDestinationCreateWithURL(output as CFURL,type.identifier as CFString,1,nil) else {throw CocoaError(.fileWriteUnknown)}
        CGImageDestinationAddImage(dest,image,exportMetadata(name:name) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {throw CocoaError(.fileWriteUnknown)}
        return output
    }
    func exportMetadata(name:String) -> [CFString:Any] {
        var p=[CFString:Any]()
        // Copy only capture time/GPS, never stale orientation, dimensions or embedded thumbnails.
        if let gps=properties[kCGImagePropertyGPSDictionary] {p[kCGImagePropertyGPSDictionary]=gps}
        if let exif=properties[kCGImagePropertyExifDictionary] as? [CFString:Any] {
            var ex=[CFString:Any]()
            for key in [kCGImagePropertyExifDateTimeOriginal,kCGImagePropertyExifDateTimeDigitized,kCGImagePropertyExifOffsetTimeOriginal,kCGImagePropertyExifSubsecTimeOriginal] {ex[key]=exif[key]}
            ex[kCGImagePropertyExifUserComment]=name;p[kCGImagePropertyExifDictionary]=ex
        }
        p[kCGImagePropertyTIFFDictionary]=[kCGImagePropertyTIFFImageDescription:name]
        p[kCGImagePropertyIPTCDictionary]=[kCGImagePropertyIPTCCaptionAbstract:name]
        p[kCGImagePropertyOrientation]=1;p[kCGImageDestinationLossyCompressionQuality]=0.95
        return p
    }
}

/// Apple foreground instances, chosen by greatest intersection with the bird box.
enum BirdMask {
    static func acceptable(covered:Int,total:Int,overlap:Int) -> Bool {total>0 && overlap>0 && Double(covered)/Double(total)<0.95 && Double(covered)/Double(total)>0.005}
    static func make(image:CGImage,box:[Double]) throws -> CGImage? {
        let handler=VNImageRequestHandler(cgImage:image)
        let request=VNGenerateForegroundInstanceMaskRequest();try handler.perform([request])
        guard let observation=request.results?.first else{return nil}
        let labels=observation.instanceMask
        CVPixelBufferLockBaseAddress(labels,.readOnly);defer{CVPixelBufferUnlockBaseAddress(labels,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(labels)?.assumingMemoryBound(to:UInt8.self) else{return nil}
        let w=CVPixelBufferGetWidth(labels),h=CVPixelBufferGetHeight(labels),row=CVPixelBufferGetBytesPerRow(labels)
        var counts=[Int:Int](),hits=[Int:Int]()
        for y in 0..<h {for x in 0..<w {
            let value=Int(base[y*row+x]);guard value>0 else{continue}
            counts[value,default:0]+=1
            if Double(x)/Double(w)>=box[0] && Double(x)/Double(w)<=box[2] && Double(y)/Double(h)>=box[1] && Double(y)/Double(h)<=box[3] {hits[value,default:0]+=1}
        }}
        guard let id=hits.keys.sorted().max(by:{hits[$0]!<hits[$1]!}),acceptable(covered:counts[id] ?? 0,total:w*h,overlap:hits[id] ?? 0) else{return nil}
        let buffer=try observation.generateScaledMaskForImage(forInstances:IndexSet(integer:id),from:handler)
        CVPixelBufferLockBaseAddress(buffer,.readOnly);defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        guard let pixels=CVPixelBufferGetBaseAddress(buffer) else{return nil}
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
        var gray=[UInt8](repeating:0,count:width*height)
        let floating=CVPixelBufferGetPixelFormatType(buffer)==kCVPixelFormatType_OneComponent32Float
        for y in 0..<height {for x in 0..<width {
            gray[y*width+x]=floating ? UInt8(clamping:Int((pixels.advanced(by:y*stride).assumingMemoryBound(to:Float.self)[x]*255).rounded())):pixels.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[x]
        }}
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:CGDataProvider(data:Data(gray) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}

#if os(iOS)
func saveBirdPhoto(_ url:URL,shooting:Shooting) async throws {
    let status=await PHPhotoLibrary.requestAuthorization(for:.addOnly)
    guard status == .authorized || status == .limited else {throw NSError(domain:"BirdCM",code:5,userInfo:[NSLocalizedDescriptionKey:"未获准添加照片。可在设置中允许观羽添加照片。"])}
    try await PHPhotoLibrary.shared().performChanges {
        let request=PHAssetCreationRequest.forAsset()
        request.addResource(with:.photo,fileURL:url,options:nil)
        request.creationDate=shooting.captureDate
        if let p=shooting.photoPlace {request.location=CLLocation(latitude:p.lat,longitude:p.lon)}
    }
}

#endif
