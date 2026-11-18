import XCTest
import ImageIO
import UniformTypeIdentifiers
#if !NATIVE_CHECK
@testable import BirdCM
#endif

final class LogicTests: XCTestCase {
    func testFullDistributionPosteriorAndGenus() {
        let visual=[0.6,0.3,0.1], geo=[0.0,1.0,0.5]
        let p=Confirm.posterior(visual,geo)
        XCTAssertEqual(p.reduce(0,+),1,accuracy:1e-12)
        XCTAssertEqual(p[0],0.012/(0.012+0.306+0.052),accuracy:1e-12)
        XCTAssertGreaterThan(p[1],p[0]);XCTAssertEqual(Confirm.posterior(visual,nil),visual)
        XCTAssertEqual(Confirm.posterior([0,0,0],geo),[0,0,0])
        let rows=(0..<10).map { ["G s\($0)","","","G",""] }
        let result=Confirm.decide(p:[Double](repeating:0.1,count:10),rows:rows,wide:nil,typical:nil)
        XCTAssertEqual(result.level,"genus");XCTAssertEqual(result.genusP!,1,accuracy:1e-12)
    }
    func testDesktopConfirmRegression() throws {
        let fixture=try JSONDecoder().decode([String:[String:Double]].self,from:Data(contentsOf:fixtures.appendingPathComponent("california-november.json")))
        for (s,expect) in [("Xenopsaris albinucha","genus"),("Tyrannus melancholicus","species")] {
            let genus=String(s.split(separator:" ")[0]), f=fixture[s]!
            let rows=[[s,"","",genus,""],[genus+" other","","",genus,""]]
            let r=Confirm.decide(p:[0.99,0.01],rows:rows,wide:[f["max"]!,0],typical:[f["median"]!,0])
            XCTAssertEqual(r.level,expect);XCTAssertEqual(r.rare,s=="Tyrannus melancholicus")
            XCTAssertEqual(r.top5[0].scientific,s)
            if expect=="genus"{XCTAssertNotNil(r.reason)}
        }
        let r=Confirm.decide(p:[0.93,0.07],rows:[["A b","","","A",""],["B c","","","B",""]],wide:nil,typical:nil)
        XCTAssertEqual(r.level,"uncertain")
    }
    func testUnknownPriorNeverVetoesOrFlags() throws {
        let rows=[["Anas laysanensis","Laysan Duck","莱岛鸭","Anas",""],["Anas platyrhynchos","Mallard","绿头鸭","Anas",""]]
        let result=Confirm.decide(p:[0.97,0.02],rows:rows,wide:[.nan,0.6],typical:[.nan,0.5])
        XCTAssertEqual(result.level,"species");XCTAssertEqual(result.priorUnknown,true)
        XCTAssertFalse(result.rare);XCTAssertNil(result.reason)
        XCTAssertNoThrow(try JSONEncoder().encode(result))
        let post=Confirm.posterior([0.6,0.4],[.nan,0.5])
        XCTAssertEqual(post[0],0.042/(0.042+0.208),accuracy:1e-12)
    }
    func testHistorySearchAllNamesAndPlaceAndInvalidPhoto() {
        let candidate=Candidate(scientific:"Haliaeetus leucocephalus",english:"Bald Eagle",chinese:"白头海雕",p:0.99)
        let r=Record(boxes:[],selected:0,result:Identification(top5:[candidate],level:"species"),shooting:Shooting(data:Data()),place:Place(lat:1,lon:2,label:"美国 · 阿拉斯加州",source:"region"))
        for q in ["白头","BALD","leucocephalus","阿拉斯加","alaska","  "] {XCTAssertTrue(r.matches(q),q)}
        XCTAssertFalse(r.matches("企鹅"));XCTAssertNil(Photo(data:Data("not a photo".utf8)))
    }
    func testRegionSearchAndRecentsAndAssetCorruption() throws {
        let english=Place.choices(query:"alaska",recent:[]).map(\.label)
        XCTAssertEqual(english,Place.choices(query:"阿拉斯加",recent:[]).map(\.label))
        XCTAssertEqual(english,["美国 · 阿拉斯加州"])
        XCTAssertEqual(Place.choices(query:"",recent:english).first?.label,english[0])
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let good=dir.appendingPathComponent("good"),bad=dir.appendingPathComponent("bad")
        try Data("abc".utf8).write(to:good);try Data("corrupt".utf8).write(to:bad)
        let asset=Models.Asset(path:"",url:"",sha256:"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",bytes:3)
        XCTAssertTrue(try asset.valid(at:good));XCTAssertFalse(try asset.valid(at:bad));XCTAssertFalse(try asset.valid(at:dir.appendingPathComponent("missing")))
    }
    func testFailedHistoryWriteDoesNotCreateRecord() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try HistoryStore(dir:dir)
        let r=Record(boxes:[],selected:0,shooting:Shooting(data:Data()))
        try FileManager.default.createDirectory(at:dir.appendingPathComponent("\(r.id).json"),withIntermediateDirectories:true)
        XCTAssertThrowsError(try store.save(r,data:Data([1,2,3])))
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.image(r).path))
    }
    func testDesktopConfirmPlainAndLocalCongenerKeepOrder() {
        let rows=[["Haliaeetus albicilla","White-tailed Eagle","白尾海雕","Haliaeetus",""],["Haliaeetus leucocephalus","Bald Eagle","白头海雕","Haliaeetus",""]]
        let rejected=Confirm.decide(p:[0.998,0.002],rows:rows,wide:[0,0.6],typical:[0,0.4])
        XCTAssertEqual(rejected.level,"genus")
        XCTAssertEqual(rejected.top5.map(\.scientific),rows.map{$0[0]})
        XCTAssertTrue(rejected.reason?.contains("当地同属候选：白头海雕") == true)
        let plain=Confirm.decide(p:[0.99,0.01],rows:rows,wide:[0.5,0.5],typical:[0.2,0.2])
        XCTAssertEqual(plain.level,"species");XCTAssertFalse(plain.rare);XCTAssertNil(plain.reason)
    }
    func testLocationPrecedenceCalendarAndRegionKey() {
        let gps=Place(lat:10,lon:20,label:"GPS",source:"photo"), device=Place(lat:30,lon:40,label:"device",source:"device")
        let manual=Place(lat:37.2,lon:-119.5,label:"美国 · 加利福尼亚州",source:"region")
        XCTAssertEqual(Place.resolve(photo:gps,device:device,manual:manual),gps)
        XCTAssertEqual(Place.resolve(photo:nil,device:device,manual:manual),device)
        XCTAssertEqual(Place.resolve(photo:nil,device:nil,manual:manual),manual)
        XCTAssertNil(Place.resolve(photo:Place(lat:95,lon:0,label:"bad",source:"photo"),device:nil,manual:nil))
        XCTAssertEqual(manual.legacyRegionKey.0,"US");XCTAssertEqual(manual.legacyRegionKey.1,"California")
        XCTAssertEqual(Geo.week("2026-11-14T10:00:00"),42);XCTAssertEqual(Geo.week("2026-12-31"),48)
        XCTAssertNil(Geo.week(nil));XCTAssertNil(Geo.week("2026-13-01"))
        XCTAssertEqual(Geo.weeks(nil).count,48);XCTAssertEqual(Geo.weeks("2026-01-01"),[1,2,3,4,46,47,48])
        XCTAssertEqual(Geo.snap([36.61,-121.92]),[36.6,-121.9]);XCTAssertEqual(Geo.snap([0,180]),[0,-180])
    }
    func testRarityTiersAndRealTable() throws {
        XCTAssertEqual(Rarity.tier(count:0,total:100000),0)
        XCTAssertEqual(Rarity.tier(count:4,total:100),1)
        XCTAssertEqual(Rarity.tier(count:5,total:1000000),1)
        XCTAssertEqual(Rarity.tier(count:20,total:1000000),2)
        XCTAssertEqual(Rarity.tier(count:200,total:1000000),3)
        XCTAssertEqual(Rarity.tier(count:2000,total:1000000),4)
        let db=try Rarity(path:fixtures.appendingPathComponent("rarity-test.sqlite"))
        let ca=Place(lat:36.6,lon:-121.9,label:"美国 · 加利福尼亚州",source:"region")
        XCTAssertEqual(db.lookup("Anas platyrhynchos",place:ca,month:11).label,"常见")
        XCTAssertEqual(db.lookup("Not a bird",place:ca,month:11).label,"未知")
        XCTAssertEqual(db.lookup("Anas platyrhynchos",place:ca,month:nil).label,"时间未知")
        XCTAssertEqual(db.lookup("Anas platyrhynchos",place:nil,month:11).iucn,"LC")
        XCTAssertEqual(db.lookup("Anas platyrhynchos",place:Place(lat:35,lon:139,label:"日本",source:"region"),month:11).label,"数据不足")
        // Fixture's sparse division/month points to the country month; engine must follow source_id.
        XCTAssertEqual(db.lookup("Anas platyrhynchos",place:ca,month:1).label,"不常见")
    }
    func testHistoryRoundTripAndDelete() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try HistoryStore(dir:dir)
        let data=Data("original photo bytes".utf8)
        var old=Record(boxes:[[0,0,1,1]],selected:0,shooting:Shooting(data:Data()),place:nil)
        old.date=Date(timeIntervalSince1970:1)
        try store.save(old,data:data)
        var next=old;next.id=UUID();next.date=Date();try store.save(next,data:data)
        let rows=try store.all();XCTAssertEqual(rows.map(\.id),[next.id,old.id]);XCTAssertEqual(try Data(contentsOf:store.image(rows[0])),data)
        next.place=Place(lat:1,lon:2,label:"manual",source:"region");try store.save(next)
        XCTAssertEqual(try store.all().first?.place,next.place)
        try store.delete(next);XCTAssertEqual(try store.all().count,1);XCTAssertFalse(FileManager.default.fileExists(atPath:store.image(next).path))
        try store.delete(old);XCTAssertTrue(try store.all().isEmpty)
    }
    func testEXIFGPSAndOrientation() throws {
        let rgb=RGB(w:40,h:20,px:[UInt8](repeating:120,count:40*20*3))
        let data=NSMutableData()
        let dest=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,rgb.cgImage(),[
            kCGImagePropertyOrientation:6,
            kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2026:11:14 10:25:00",kCGImagePropertyExifFNumber:6.3],
            kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.7,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:122.4,kCGImagePropertyGPSLongitudeRef:"W"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let shooting=Shooting(data:data as Data),photo=try XCTUnwrap(Photo(data:data as Data))
        XCTAssertEqual(shooting.takenAt,"2026-11-14T10:25:00")
        XCTAssertEqual(shooting.photoPlace?.lon,-122.4)
        XCTAssertEqual(shooting.fields["光圈"],"f/6.3")
        XCTAssertEqual([photo.frame.w,photo.frame.h],[20,40])
    }
    func testHugePhotoDecodeBudget() {
        XCTAssertEqual(RGB.decodingEdge(width:8064,height:6048,limit:4096),4096)
        XCTAssertEqual(RGB.decodingEdge(width:4000,height:3000,limit:4096),4000)
        XCTAssertEqual(RGB.decodingEdge(width:8064,height:6048,limit:nil),8064)
    }
    func testGlobalRegionAtMatchesPythonAndCoverage() throws {
        struct Point:Decodable {let lat:Double;let lon:Double;let division:String?;let country:String?}
        let db=try Rarity(path:fixtures.appendingPathComponent("rarity-global-test.sqlite"))
        let points=try JSONDecoder().decode([Point].self,from:Data(contentsOf:fixtures.appendingPathComponent("global-region-reference.json")))
        for p in points {
            let found=db.regionAt(lat:p.lat,lon:p.lon)
            XCTAssertEqual(found.division,p.division);XCTAssertEqual(found.country,p.country)
        }
        let value=db.lookup("Anas platyrhynchos",place:Place(lat:33.7,lon:-118.06,label:"California",source:"map"),month:11)
        XCTAssertEqual(value.label,"数据不足");XCTAssertEqual(value.region,"US-CA")
    }
    func testContrastEveryTokenPair() {
        for (foreground,background,minimum) in ThemeContrast.pairs {
            XCTAssertGreaterThanOrEqual(ThemeContrast.contrast(foreground,background),minimum,"\(String(foreground,radix:16)) on \(String(background,radix:16))")
        }
    }
    func testDeniedPermissionFallsBackToMap() {
        XCTAssertFalse(DeviceLocation.canLocate(.denied));XCTAssertFalse(DeviceLocation.canLocate(.restricted))
        XCTAssertTrue(DeviceLocation.canLocate(.authorizedAlways))
    }
    func testSyntheticCaliforniaBlackbird() throws {
        let rows=[["Turdus merula","Common Blackbird","乌鸫","Turdus",""],["Agelaius phoeniceus","Red-winged Blackbird","红翅黑鹂","Agelaius",""],["Quiscalus mexicanus","Great-tailed Grackle","大尾拟八哥","Quiscalus",""]]
        let visual=[0.49,0.48,0.03], wide=[0.0,0.95,0.03], typical=[0.0,0.6,0.01]
        XCTAssertEqual(Confirm.decide(p:visual,rows:rows,wide:nil,typical:nil).level,"uncertain")
        let local=Confirm.decide(p:Confirm.posterior(visual,wide),rows:rows,wide:wide,typical:typical)
        XCTAssertEqual(local.level,"species");XCTAssertEqual(local.top5[0].scientific,"Agelaius phoeniceus")
        var cached=local;cached.visual=visual
        let decoded=try JSONDecoder().decode(Identification.self,from:JSONEncoder().encode(cached))
        XCTAssertEqual(Confirm.posterior(decoded.visual!,wide),Confirm.posterior(visual,wide))
    }
    func testSmallBirdUsesDecodeResolutionOnlyBelow128() {
        XCTAssertTrue(Engine.needsHighResolution([1,2,128,120]))
        XCTAssertFalse(Engine.needsHighResolution([1,2,129,120]))
        XCTAssertFalse(Engine.needsHighResolution([1,2,90,200]))
    }
    func testPaddedSquarePreservesWholeBoxAndMean() {
        let rgb=RGB(w:10,h:20,px:[UInt8](repeating:90,count:600))
        let (x,y,right,bottom)=cropWithContext(10,20,[0,0,10,20],minSide:0)
        XCTAssertEqual(right-x,bottom-y);XCTAssertEqual(right-x,24)
        let square=rgb.paddedCrop(x,y,right,bottom)
        XCTAssertEqual(square.w,24);XCTAssertTrue(square.px.allSatisfy{$0==90})
    }
    func testCropBoundaries() {
        for (w,h,b) in [(500,300,[0.0,0,20,30]),(300,500,[280.0,480,300,500]),(100,50,[0.0,0,100,50])] {
            let (x0,y0,x1,y1)=cropWithContext(w,h,b,minSide:320)
            XCTAssertEqual(x1-x0,y1-y0)
            XCTAssertLessThanOrEqual(x0,Int(b[0]));XCTAssertLessThanOrEqual(y0,Int(b[1]))
            XCTAssertGreaterThanOrEqual(x1,Int(b[2]));XCTAssertGreaterThanOrEqual(y1,Int(b[3]))
        }
    }
}
#if NATIVE_CHECK
let fixtures=URL(fileURLWithPath:ProcessInfo.processInfo.environment["FIXTURES"]!)
#else
let fixtures=Bundle(for:LogicTests.self).resourceURL!.appendingPathComponent("Fixtures")

#endif
