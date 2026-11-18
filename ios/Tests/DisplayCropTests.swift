import XCTest
import ImageIO
import UniformTypeIdentifiers
#if !NATIVE_CHECK
@testable import BirdCM
#endif

final class DisplayCropTests:XCTestCase {
    func testMarginsAspectAndEdgeShift() {
        let size=CGSize(width:4000,height:3000)
        let square=DisplayCrop.make(size:size,box:[0.4,0.3,0.6,0.5666666667])
        XCTAssertEqual(square.rect.width/square.rect.height,1,accuracy:0.002)
        XCTAssertGreaterThanOrEqual(square.rect.width,1088)
        XCTAssertEqual(square.rect.midX,2000,accuracy:1)
        let portrait=DisplayCrop.make(size:size,box:[0.4,0.2,0.5,0.6])
        XCTAssertEqual(portrait.rect.width/portrait.rect.height,0.8,accuracy:0.002)
        let landscape=DisplayCrop.make(size:size,box:[0.2,0.4,0.6,0.5])
        XCTAssertEqual(landscape.rect.width/landscape.rect.height,1.5,accuracy:0.002)
        let edge=DisplayCrop.make(size:size,box:[0,0,0.2,0.2666666667])
        XCTAssertEqual(edge.rect.minX,0);XCTAssertEqual(edge.rect.minY,0)
        XCTAssertEqual(edge.rect.size,square.rect.size)
        let opposite=DisplayCrop.make(size:size,box:[0.8,0.7333333333,1,1])
        XCTAssertEqual(opposite.rect.maxX,4000);XCTAssertEqual(opposite.rect.maxY,3000)
    }
    func testTinyAndNeverUpscale() {
        let tiny=DisplayCrop.make(size:CGSize(width:8000,height:6000),box:[0.49,0.49,0.5,0.5])
        XCTAssertTrue(tiny.tiny);XCTAssertEqual(max(tiny.rect.width,tiny.rect.height),204,accuracy:2)   // 1.5x the margined box, not 600 px
        let small=DisplayCrop.make(size:CGSize(width:200,height:100),box:[0.1,0.1,0.9,0.9])
        XCTAssertLessThanOrEqual(small.rect.width,200);XCTAssertLessThanOrEqual(small.rect.height,100)
    }
    func testDuplicatesAndSubjectOrder() {
        let boxes=[[0.0,0,1,1],[0.05,0.05,0.95,0.95],[0.3,0.3,0.4,0.4],[1.1,0,1.6,1],[2.0,0,2.6,1]]
        let result=displaySubjects(boxes,scores:[0.1,0.9,0.8,0.99,0.2])
        XCTAssertEqual(result,[boxes[1],boxes[4],boxes[3]])
        XCTAssertTrue(displaySubjects([],scores:[]).isEmpty)
    }
    func testCoordinatePixelRoundTripAndMarks() {
        let window=[0.12,0.2,0.8,0.95],transform=CropCoordinates(window:window)
        for x in stride(from:960,through:6400,by:17) {
            let point=[Double(x)/8000,0.4],back=transform.original(transform.local(point))
            XCTAssertEqual(back[0]*8000,Double(x),accuracy:0.000001)
            XCTAssertEqual(back[1]*6000,2400,accuracy:0.000001)
        }
        let result=Identification(top5:[],level:"uncertain",beak:[0.4,0.6],eye:[0.3,0.5])
        let record=Record(boxes:[window],selected:0,result:result,shooting:Shooting(data:Data()),place:nil)
        let mapped=transform.record(record,index:0)
        XCTAssertEqual(mapped.result?.eye,transform.local(result.eye!));XCTAssertEqual(mapped.result?.beak,transform.local(result.beak!))
        XCTAssertTrue(mapped.boxes.isEmpty)
    }
    func fixture(orientation:Int=1) throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        var pixels=[UInt8]()
        for y in 0..<60 {for x in 0..<80 {pixels += [UInt8(x*3),UInt8(y*4),90]}}
        let dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,RGB(w:80,h:60,px:pixels).cgImage(),[
            kCGImagePropertyOrientation:orientation,
            kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2026:11:14 10:25:00",kCGImagePropertyExifOffsetTimeOriginal:"-08:00"],
            kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.7,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:122.4,kCGImagePropertyGPSLongitudeRef:"W"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest));return url
    }
    func testAllEXIFOrientationsAndSourcePixels() throws {
        for orientation in 1...8 {
            let url=try fixture(orientation:orientation);defer{try? FileManager.default.removeItem(at:url)}
            let source=try XCTUnwrap(CropSource(url)),reference=try XCTUnwrap(RGB.load(Data(contentsOf:url)))
            XCTAssertEqual(source.size,CGSize(width:reference.w,height:reference.h))
            let window=[0.25,0.25,0.75,0.75]
            let exported=try source.export(window:window,name:"测试鸟");defer{try? FileManager.default.removeItem(at:exported)}
            let actual=try XCTUnwrap(RGB.load(Data(contentsOf:exported)))
            let expected=reference.cropped(reference.w/4,reference.h/4,reference.w*3/4,reference.h*3/4)
            XCTAssertEqual(actual.w,expected.w);XCTAssertEqual(actual.h,expected.h)
            let diff=zip(actual.px,expected.px).map{abs(Int($0)-Int($1))}.reduce(0,+)
            XCTAssertLessThan(Double(diff)/Double(actual.px.count),4,"EXIF \(orientation)")
        }
    }
    func testHistoryThumbnailMetadataAndAlpha() throws {
        let url=try fixture();defer{try? FileManager.default.removeItem(at:url)}
        let source=try XCTUnwrap(CropSource(url))
        var record=Record(boxes:[[0.2,0.2,0.4,0.5]],selected:0,shooting:Shooting(data:Data()),place:nil)
        record.displayCrops=[[0.25,0.25,0.75,0.75]]
        let thumb=try XCTUnwrap(source.thumbnail(record,edge:120));XCTAssertEqual(thumb.width,40);XCTAssertEqual(thumb.height,30)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try HistoryStore(dir:dir);try store.save(record,data:Data(contentsOf:url))
        XCTAssertEqual(try store.all().first?.displayCrops,record.displayCrops)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path).count,2)
        var cached=Identification(top5:[Candidate(scientific:"Haliaeetus leucocephalus",english:"Bald Eagle",chinese:"白头海雕",p:0.99)],level:"species")
        cached.visual=Array(repeating:1.0/11172,count:11172)
        var measured=record;measured.result=cached;measured.results=["0":cached]
        print("History example JSON bytes \(try JSONEncoder().encode(measured).count), plus exactly one original; rectangle bytes \(try JSONEncoder().encode(measured.displayCrops).count)")
        let output=try source.export(window:record.displayCrops![0],name:"白头海雕 · Bald Eagle")
        defer{try? FileManager.default.removeItem(at:output)}
        let savedShooting=Shooting(data:try Data(contentsOf:output))
        XCTAssertEqual(savedShooting.captureDate,ISO8601DateFormatter().date(from:"2026-11-14T10:25:00-08:00"))
        let metadata=try XCTUnwrap(CropSource(output)).properties
        XCTAssertEqual((metadata[kCGImagePropertyExifDictionary] as? [CFString:Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,"2026:11:14 10:25:00")
        XCTAssertEqual((metadata[kCGImagePropertyGPSDictionary] as? [CFString:Any])?[kCGImagePropertyGPSLongitude] as? Double,122.4)
        XCTAssertEqual((metadata[kCGImagePropertyIPTCDictionary] as? [CFString:Any])?[kCGImagePropertyIPTCCaptionAbstract] as? String,"白头海雕 · Bald Eagle")
        let cgMask=try XCTUnwrap(CGImage(width:40,height:30,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:40,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:CGDataProvider(data:Data(repeating:128,count:1200) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
        let alpha=try source.export(window:record.displayCrops![0],name:"白头海雕",mask:cgMask)
        defer{try? FileManager.default.removeItem(at:alpha)}
        XCTAssertEqual(alpha.pathExtension,"png")
        let alphaMetadata=try XCTUnwrap(CropSource(alpha)).properties
        XCTAssertEqual((alphaMetadata[kCGImagePropertyExifDictionary] as? [CFString:Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,"2026:11:14 10:25:00")
        XCTAssertEqual((alphaMetadata[kCGImagePropertyGPSDictionary] as? [CFString:Any])?[kCGImagePropertyGPSLongitude] as? Double,122.4)
        let src=try XCTUnwrap(CGImageSourceCreateWithURL(alpha as CFURL,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(src,0,nil))
        let alphaContext=try XCTUnwrap(CGContext(data:nil,width:40,height:30,bitsPerComponent:8,bytesPerRow:160,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        alphaContext.draw(image,in:CGRect(x:0,y:0,width:40,height:30))
        let alphaValue=alphaContext.data!.assumingMemoryBound(to:UInt8.self)[3]
        XCTAssertEqual(Int(alphaValue),128,accuracy:2)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedLast,.premultipliedFirst,.last,.first].contains(image.alphaInfo))
    }
    func testLargeSyntheticRegionDecode() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer{try? FileManager.default.removeItem(at:url)}
        try autoreleasepool {
            let context=try XCTUnwrap(CGContext(data:nil,width:8000,height:6000,bitsPerComponent:8,bytesPerRow:8000,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0))
            context.setFillColor(gray:0.4,alpha:1);context.fill(CGRect(x:0,y:0,width:8000,height:6000))
            let image=try XCTUnwrap(context.makeImage()),dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil))
            CGImageDestinationAddImage(dest,image,nil);XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        let baseline=Diagnostics.footprint(),sample=MemorySample()
        defer {let peak=sample.stop();print("48 MP crop baseline \(baseline), peak \(peak), delta \(peak>baseline ? peak-baseline:0)")}
        let source=try XCTUnwrap(CropSource(url)),crop=source.crop([0.49,0.49,0.50,0.50]),window=crop.normalized(in:source.size)
        let image=try XCTUnwrap(source.image(window:window,edge:1200))
        XCTAssertEqual(Double(max(image.width,image.height)),204,accuracy:2)
        let saved=try source.export(window:window,name:"合成测试")
        defer{try? FileManager.default.removeItem(at:saved)}
        XCTAssertEqual(try XCTUnwrap(CropSource(saved)).size,CGSize(width:image.width,height:image.height))
    }
    #if os(iOS)
    func testBlankCropMaskFallback() throws {
        let image=RGB(w:128,h:128,px:Array(repeating:220,count:128*128*3)).cgImage()
        XCTAssertNil(try? BirdMask.make(image:image,box:[0.2,0.2,0.8,0.8]))
    }
    #endif
    func testMaskFailurePolicy() {
        XCTAssertFalse(BirdMask.acceptable(covered:99,total:100,overlap:5))
        XCTAssertFalse(BirdMask.acceptable(covered:40,total:100,overlap:0))
        XCTAssertTrue(BirdMask.acceptable(covered:40,total:100,overlap:20))
    }
}
