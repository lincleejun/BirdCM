#if DEBUG
import UIKit
import SwiftUI
/// Explicit visual fixtures, never stored in the user's history or represented as inference output.
extension AppModel {
    static let blackbirdRows=[["Turdus merula","Common Blackbird","乌鸫","Turdus",""],["Agelaius phoeniceus","Red-winged Blackbird","红翅黑鹂","Agelaius",""],["Quiscalus mexicanus","Great-tailed Grackle","大尾拟八哥","Quiscalus",""]]

    /// An old-format History folder (pre-library JSON + .photo) built from the CC0 fixture, to exercise migration on launch.
    static func seedLegacy(_ dir:URL,count:Int) {
        guard !FileManager.default.fileExists(atPath:dir.appendingPathComponent("library.sqlite").path),let path=UserDefaults.standard.string(forKey:"fixtureImage"),let data=FileManager.default.contents(atPath:path),let old=try? HistoryStore(dir:dir) else {return}
        for i in 0..<count {
            var s=Shooting(data:data);s.takenAt=String(format:"2026-09-%02dT08:00:00",i+1)
            let c=Candidate(scientific:"Haliaeetus leucocephalus",english:"Bald Eagle",chinese:"白头海雕",p:0.99)
            var r=Record(boxes:[[0.34,0.09,0.72,0.73]],selected:0,result:Identification(top5:[c],level:"species",name:c.scientific,clear:true),shooting:s,place:Place(lat:36.6,lon:-121.9,label:"美国 · 加利福尼亚州",source:"region"))
            r.results["0"]=r.result
            try? old.save(r,data:data+Data([UInt8(i)]))
        }
        try? Data("{corrupt".utf8).write(to:dir.appendingPathComponent("\(UUID()).json"))
    }
    func preparePreview(_ state: String,path: String) {
        guard let data=FileManager.default.contents(atPath:path),let photo=Photo(data:data) else {error="测试夹具读取失败";return}
        previewing=true;self.photo=photo;preview=UIImage(cgImage:photo.frame.cgImage());status=""
        let c=Candidate(scientific:"Haliaeetus leucocephalus",english:"Bald Eagle",chinese:"白头海雕",p:0.99)
        let other=Candidate(scientific:"Haliaeetus albicilla",english:"White-tailed Eagle",chinese:"白尾海雕",p:0.006)
        var result=Identification(top5:[c,other],level:"species",name:c.scientific,flying:1,beak:[0.55,0.3],eye:[0.54,0.28],rarity:RarityValue(label:"不常见",iucn:"LC"))
        var shooting=Shooting(data:data);shooting.takenAt="2026-11-14T10:26:00";shooting.fields=["相机":"CC0 测试照片","焦距":"600 mm","光圈":"f/6.3","快门":"1/1000 s","ISO":"250","曝光补偿":"0 EV"]
        let place=Place(lat:36.6,lon:-121.9,label:"美国 · 加利福尼亚州",source:"region")
        if state=="uncertain" {result.level="uncertain";result.name=nil;result.top5[0].p=0.42;result.top5[1].p=0.30;result.rarity=nil}
        if state=="genus" {result.level="genus";result.name="Haliaeetus";result.genusP=0.97}
        if state=="rare" {result.rare=true}
        // GBIF tier comes from the bundled table at read time (US-CA, November): Aegolius acadicus is tier 2 (少见) with no geo-prior warning.
        if state=="gbif-rare" {result.top5[0]=Candidate(scientific:"Aegolius acadicus",english:"Northern Saw-whet Owl",chinese:"棕榈鬼鸮",p:0.97);result.name="Aegolius acadicus";result.rare=false}
        if state=="uncertain-geo" {result.level="uncertain";result.name=nil;result.top5[0].p=0.6;result.reason="图像最像 白头海雕，但此地此季几乎没有它。"}
        if state=="unknown-prior" {result.priorUnknown=true}
        if state=="photo-gps" {shooting.photoPlace=Place(lat:33.7,lon:-118.06,label:"33.7000, -118.0600",source:"photo")}   // as Shooting labels real photo GPS
        if state=="location-rerank" {result=Confirm.decide(p:[0.49,0.48,0.03],rows:Self.blackbirdRows,wide:nil,typical:nil);result.visual=[0.49,0.48,0.03]}
        var r=Record(boxes:state=="no-bird" ? []:[[0.34,0.09,0.72,0.73]],selected:0,result:state=="no-bird" ? nil:result,shooting:shooting,place:shooting.photoPlace ?? ((state=="no-location" || state=="home-place") ? homePlace:state=="location-rerank" ? nil:place))
        if state=="multiple" {
            r.boxes=[[0.23,0.61,0.54,0.84],[0.49,0.37,0.66,0.60]]
            result=Identification(top5:[Candidate(scientific:"Pelecanus occidentalis",english:"Brown Pelican",chinese:"褐鹈鹕",p:0.98),Candidate(scientific:"Pelecanus erythrorhynchos",english:"American White Pelican",chinese:"美洲白鹈鹕",p:0.01)],level:"species",eye:[0.45,0.65],rarity:RarityValue(label:"常见",iucn:"LC"))
            r.result=result
        }
        for i in r.boxes.indices {var v=result;if i==1 {v.eye=[0.52,0.40];v.top5[0].p=0.96};r.results[String(i)]=v}
        if let saved=try? library?.save(r,data:data) {r=saved}
        if let url=url(r.id),let source=CropSource(url) {r.displayCrops=r.boxes.map{source.crop($0).normalized(in:source.size)};if let saved=try? library?.save(r) {r=saved}}
        current=r;if !["home","history","loading","missing-gps","damaged"].contains(state) {show(r.id,on:.identify)}
        refresh()
        if state=="missing-gps" {needsPlace=true}
        if state=="damaged" {previewing=false;status="安装包损坏或缺少模型，请重新安装完整 App。"}
        if state=="loading" {busy=true;status="认种"}
    }
}
struct Screens_Previews: PreviewProvider {
    @ViewBuilder static func screen(_ state:String) -> some View {
        switch state {
        case "place":PlacePicker().environment(AppModel(previewState:"home"))
        case "map":MapPlacePicker(initial:Place(lat:33.7,lon:-118.06,label:"Bolsa Chica",source:"map")){_ in}
        case "about":AboutView()
        case "diagnostics":DiagnosticsView().environment(AppModel(previewState:"normal"))
        default:RootView().environment(AppModel(previewState:state))
        }
    }
    static var previews:some View {
        ForEach(["home","history","normal","multiple","uncertain","genus","rare","unknown-prior","no-location","no-bird","loading","missing-gps","damaged","place","map","about","diagnostics"],id:\.self) {state in
            ForEach(["iPhone 15","iPhone 18 Pro","iPhone SE (3rd generation)"],id:\.self) {device in
                ForEach(0..<4) {mode in
                    screen(state).preferredColorScheme(mode%2==0 ? .light:.dark)
                        .dynamicTypeSize(mode<2 ? .large:.accessibility5)
                        .previewDevice(PreviewDevice(rawValue:device))
                        .previewDisplayName(state+" · "+device+" · \(mode)")
                }
            }
        }
    }
}
#endif
