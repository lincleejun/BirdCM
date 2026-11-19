import Foundation
import Darwin

@main struct CoreCheck {
 static func main() throws {
    setbuf(stdout,nil)
    let args=CommandLine.arguments
    let fixtures=URL(fileURLWithPath:args[1])
    let models=URL(fileURLWithPath:args[2])
    print("Loading production engine")
    let engine=try Engine(dir:models)
    print("Engine loaded")
    let alaska=Place.choices(query:"Alaska",recent:[])
    precondition(alaska.count==1 && alaska[0].regionCode=="US-AK","offline global region search")
    let japan=Place.choices(query:"日本",recent:[]).first{$0.label=="日本"}!
    precondition(engine.rarity?.lookup("Anas platyrhynchos",place:japan,month:11).region=="JP","explicit offline country must use country ISO code")
    print("Global offline place catalogue and explicit country ISO lookup passed")
    var visual=[Double](repeating:0,count:engine.rows.count)
    let remote=engine.rows.firstIndex{$0[0]=="Turdus merula"}!,local=engine.rows.firstIndex{$0[0]=="Agelaius phoeniceus"}!
    visual[remote]=0.5;visual[local]=0.5
    var synthetic=Confirm.decide(p:visual,rows:engine.rows,wide:nil,typical:nil);synthetic.visual=visual
    precondition(synthetic.level=="uncertain")
    var date=Shooting(data:Data());date.takenAt="2026-11-14"
    let california=try engine.rerank(synthetic,place:Place(lat:33.7,lon:-118.06,label:"Bolsa Chica, California",source:"map"),shooting:date)
    print("Actual California geomodel blackbird regression: \(california.level) \(california.top5[0].scientific) \(california.top5[0].p)")
    precondition(california.level=="species" && california.top5[0].scientific=="Agelaius phoeniceus")
    let cases=try JSONSerialization.jsonObject(with:Data(contentsOf:fixtures.appendingPathComponent("expected.json"))) as! [[String:Any]]
    var report=[[String:Any]]()
    for (i,c) in cases.enumerated() {
        if i==1 {engine.releaseBioCLIP();precondition(engine.lastEmbedding == nil)}
        print("Case \(i)")
        let photo=Photo(data:try Data(contentsOf:fixtures.appendingPathComponent(c["path"] as! String)))!
        if i==4 {
            let w=Double(photo.frame.w),h=Double(photo.frame.h)
            let crop=Engine.crop(photo,[w*0.4,h*0.4,w*0.41,h*0.41])
            precondition(max(crop.source.w,crop.source.h)>2048)
            let ref=RGB.load(try Data(contentsOf:fixtures.appendingPathComponent("small-highres.png")))!
            let err=Double(zip(crop.image.px,ref.px).reduce(0){$0+abs(Int($1.0)-Int($1.1))})/Double(ref.px.count)
            precondition(err<1,"high-resolution padded input error \(err)")
            print("Small-bird high-resolution crop agrees with desktop; mean error \(err)")
        }
        let boxes=try engine.detect(photo)
        print("Detected \(boxes.count) boxes")
        guard let b=boxes.first else {throw NSError(domain:"CoreCheck",code:1,userInfo:[NSLocalizedDescriptionKey:"No detection for fixture \(i)"])}
        let want=c["box"] as! [Double]
        let overlap=iou(b,want);precondition(overlap>0.95,"IoU \(overlap)")
        let mine=Engine.crop(photo,want).image, theirs=RGB.load(try Data(contentsOf:fixtures.appendingPathComponent("\(i).png")))!
        let mean=Double(zip(mine.px,theirs.px).reduce(0){$0+abs(Int($1.0)-Int($1.1))})/Double(mine.px.count);precondition(mean<1,"224 mean \(mean)")
        print("IoU \(overlap), input mean \(mean)")
        let result=try engine.identify(photo,box:want)
        if i==0 {
            let place=Place(lat:33.7,lon:-118.06,label:"Bolsa Chica",source:"map")
            var shooting=Shooting(data:Data());shooting.takenAt="2026-11-14"
            let cached=try engine.rerank(result,place:place,shooting:shooting)
            let fresh=try engine.identify(photo,box:want,place:place,shooting:shooting)
            precondition(cached.top5==fresh.top5 && cached.level==fresh.level && cached.rare==fresh.rare,"cached reranking must equal fresh inference")
            print("Cached visual reranking equals fresh inference")
        }
        let referencePoints=c["points_normalized"] as! [[Double]],visible=c["visible"] as! [Double]
        let eye=visible[1]>=visible[2] ? 1:2
        for (point,index) in [(result.beak,0),(result.eye,eye)] {
            if let point {precondition(zip(point,referencePoints[index]).allSatisfy{abs($0-$1)<0.02},"square-pad head point mapping")}
        }
        let embedding=engine.lastEmbedding!, expected=c["embedding"] as! [Double]
        let cos=zip(embedding,expected).reduce(0.0){$0+Double($1.0)*$1.1};print("Embedding cosine \(cos)");precondition(cos>0.995,"Embedding cosine \(cos)")
        let names=(c["top5"] as! [[String:Any]]).map{$0["scientific"] as! String}
        precondition(result.top5[0].scientific==names[0]);precondition(Set(result.top5.map(\.scientific)).intersection(names).count>=4)
        if let flying=result.flying{precondition((flying>0.5)==((c["flying"] as! Double)>0.5))}
        let r:[String:Any]=["case":c["path"]!,"box_iou":overlap,"input_mean_difference":mean,"embedding_cosine":cos,"top5":result.top5.map(\.scientific),"flying":result.flying.map{$0 as Any} ?? NSNull(),"clear":result.clear.map{$0 as Any} ?? NSNull()]
        report.append(r); print(r)
    }
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:URL(fileURLWithPath:args[3]))
 }
}
