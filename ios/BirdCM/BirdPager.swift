import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

struct BirdShare: Transferable {
    let source:CropSource
    let window:[Double]
    let name:String
    let mask:CGImage?
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(exportedContentType:.image) {value in
            let url=try await Task.detached {try value.source.export(window:value.window,name:value.name,mask:value.mask)}.value
            return SentTransferredFile(url)
        }
    }
}

struct CropThumbnail:View {
    var url:URL?
    let record:Record
    var index:Int=0
    var original=false
    @State private var image:CGImage?
    var body:some View {
        Group {if let image {Image(decorative:image,scale:1).resizable().scaledToFill()} else {Rectangle().fill(Palette.paper)}}
            .clipped().task(id:"\(record.id)-\(index)-\(original)-\(record.boxes)") {
                guard let url else{return}
                let value=await Task.detached {() -> CGImage? in
                    guard let source=CropSource(url) else{return nil}
                    let window=original || !record.boxes.indices.contains(index) ? [0.0,0,1,1] : record.displayCrops?[safe:index] ?? source.crop(record.boxes[index]).normalized(in:source.size)
                    return source.image(window:window,edge:120)
                }.value
                if !Task.isCancelled {image=value}
            }
    }
}
extension Array {
    subscript(safe index:Int) -> Element? {indices.contains(index) ? self[index]:nil}
}

struct BirdPager:View {
    @Environment(AppModel.self) var model
    let record:Record
    @Binding var marks:Bool
    @Binding var drawing:Bool
    @State private var page=0
    @Environment(\.dynamicTypeSize) private var typeSize
    var count:Int {min(6,record.boxes.count)}
    var body:some View {
        VStack(spacing:8) {
            TabView(selection:$page) {
                ForEach(0..<count,id:\.self) {i in
                    BirdCropPage(record:record,index:i,active:page==i,marks:marks).tag(i)
                }
                if let image=model.preview {
                    VStack(spacing:4) {
                        PhotoView(image:image,record:record,marks:marks,drawing:drawing,onSelect:{i in if i<count {page=i}},onDraw:{box in drawing=false;Task{await model.analyze(index:0,box:box,manual:true,newBox:true,place:record.place);page=0}})
                            .aspectRatio(image.size,contentMode:.fit).accessibilityIdentifier("result.photo")
                        if record.boxes.count>count {Text("还有 \(record.boxes.count-count) 只").font(.caption).foregroundStyle(.white)}
                    }.background(.black).tag(count)
                }
            }.tabViewStyle(.page(indexDisplayMode:.always)).indexViewStyle(.page(backgroundDisplayMode:.always))
                .frame(height:typeSize.isAccessibilitySize ? 560:280).background(Palette.paper).accessibilityIdentifier("result.pager")
            ScrollView(.horizontal) {
                HStack(spacing:12) {ForEach(0...count,id:\.self) {i in
                    Button {page=i} label:{VStack(spacing:3) {
                        CropThumbnail(url:model.store?.image(record),record:record,index:i,original:i==count)
                            .frame(width:48,height:38).clipShape(RoundedRectangle(cornerRadius:8))
                        Text(i==count ? "原图":"鸟 \(i+1)").font(.caption.bold())
                    }.padding(4).background(page==i ? Palette.green.opacity(0.15):.clear,in:RoundedRectangle(cornerRadius:12))}
                        .buttonStyle(.plain).accessibilityIdentifier(i==count ? "result.original":"result.subject.\(i)").accessibilityAddTraits(page==i ? .isSelected:[])
                }}.padding(.horizontal)
            }
        }.onChange(of:page) {_,value in if value<count {Task{await model.select(value)}}}
            .onChange(of:drawing) {_,value in if value {page=count}}
            .onChange(of:record.boxes) {_,_ in page=count==0 ? 0:min(page,count-1)}
            .onAppear {page=record.boxes.isEmpty ? 0:min(record.selected,count-1)}
    }
}

struct BirdCropPage:View {
    @Environment(AppModel.self) var model
    let record:Record
    let index:Int
    let active:Bool
    let marks:Bool
    @State private var image:CGImage?
    @State private var mask:CGImage?
    @State private var lifted:CGImage?
    @State private var removeBackground=false
    @State private var maskUnavailable=false
    @State private var working=false
    @State private var saving=false
    @State private var saved=false
    var source:CropSource? {model.store.map{CropSource($0.image(record))} ?? nil}
    var window:[Double]? {source.map{record.displayCrops?[safe:index] ?? $0.crop(record.boxes[index]).normalized(in:$0.size)}}
    var species:String {(record.results[String(index)] ?? (record.selected==index ? record.result:nil)).map(title) ?? "鸟 \(index+1)"}
    var body:some View {
        VStack(spacing:4) {
            if active,let image,let source,let window {
                PhotoView(image:UIImage(cgImage:removeBackground ? lifted ?? image:image),record:CropCoordinates(window:window).record(record,index:index),marks:marks,drawing:false,neutral:true,onSelect:{_ in},onDraw:{_ in})
                    .aspectRatio(CGSize(width:image.width,height:image.height),contentMode:.fit).frame(maxHeight:180).accessibilityIdentifier("result.crop.\(index)")
                if source.crop(record.boxes[index]).tiny {Text("鸟很小").font(.caption).foregroundStyle(Palette.rust).accessibilityIdentifier("result.tiny")}
                HStack {
                    if !maskUnavailable {
                        Toggle("去背景",isOn:$removeBackground).toggleStyle(.button).disabled(working).accessibilityIdentifier("result.background")
                    } else {Text("未找到合适的轮廓").font(.caption).accessibilityIdentifier("result.noMask")}
                    if working {ProgressView()}
                    Button(saved ? "已保存":"保存到相册",systemImage:"square.and.arrow.down") {Task{await save(source:source,window:window)}}.disabled(saving).accessibilityIdentifier("result.save")
                    ShareLink(item:BirdShare(source:source,window:window,name:species,mask:removeBackground ? mask:nil),preview:SharePreview(species,image:Image(decorative:image,scale:1))) {Label("分享",systemImage:"square.and.arrow.up")}.accessibilityIdentifier("result.share")
                }.font(.caption).buttonStyle(.bordered).padding(.bottom,25)
            } else {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
        }.background(Palette.paper)
            .task(id:"\(record.id)-\(index)-\(active)") {
                guard active,let source,let window else {image=nil;lifted=nil;mask=nil;removeBackground=false;return}
                let decoded=await Task.detached {source.image(window:window,edge:1200)}.value
                guard !Task.isCancelled else{return};image=decoded
            }
            .task(id:removeBackground && active) {if removeBackground,active,mask==nil {await lift()}}
    }
    func lift() async {
        guard let image,let source,let window else{return}
        working=true;defer{working=false}
        let box=CropCoordinates(window:window).box(record.boxes[index])
        let output=await Task.detached {() -> (CGImage,CGImage)? in
            guard let mask=try? BirdMask.make(image:image,box:box),let lifted=source.image(window:window,edge:1200,mask:mask) else{return nil}
            return (mask,lifted)
        }.value
        guard !Task.isCancelled else{return}
        if let output {mask=output.0;lifted=output.1} else {removeBackground=false;maskUnavailable=true}
    }
    func save(source:CropSource,window:[Double]) async {
        saving=true;defer{saving=false}
        do {
            let selectedMask=removeBackground ? mask:nil, name=species
            let url=try await Task.detached {try source.export(window:window,name:name,mask:selectedMask)}.value
            defer{try? FileManager.default.removeItem(at:url)}
            try await saveBirdPhoto(url,shooting:record.shooting);saved=true
        } catch {model.error=error.localizedDescription}
    }
}
