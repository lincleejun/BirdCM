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
    let url:URL?, id:UUID, boxes:[[Double]], crops:[[Double]]?, index:Int, original:Bool
    init(url:URL?,id:UUID,boxes:[[Double]],crops:[[Double]]?,index:Int=0,original:Bool=false) {self.url=url;self.id=id;self.boxes=boxes;self.crops=crops;self.index=index;self.original=original}
    init(url:URL?,record:Record,index:Int=0,original:Bool=false) {self.init(url:url,id:record.id,boxes:record.boxes,crops:record.displayCrops,index:index,original:original)}
    @State private var image:CGImage?
    @State private var frame=CGSize.zero
    @Environment(\.displayScale) private var displayScale
    /// Decoded crops at their on-screen pixel size, keyed by photo / subject / window / frame; evicted under memory pressure.
    static let cache:NSCache<NSString,CGImage>={let c=NSCache<NSString,CGImage>();c.totalCostLimit=48<<20;return c}()
    /// At most four decodes at once: a fast scroll through a large grid never stacks dozens of transient bitmaps.
    static let gate=Gate(4)
    /// Long-edge pixels for a window filling `frame` at `scale`, capped: the frame × screen scale, never a fixed thumbnail size.
    nonisolated static func edge(window:[Double],size:CGSize,frame:CGSize,scale:CGFloat) -> Int {
        let w=max(1,(window[2]-window[0])*size.width),h=max(1,(window[3]-window[1])*size.height)
        let fill=max(frame.width/w,frame.height/h)
        return min(1024,Int((max(w,h)*fill*scale).rounded(.up)))
    }
    nonisolated static func load(url:URL,boxes:[[Double]],crops:[[Double]]?,index:Int,original:Bool,frame:CGSize,scale:CGFloat) async -> CGImage? {
        await gate.enter();defer{gate.leave()}
        guard !Task.isCancelled,let source=CropSource(url) else{return nil}
        let window=original || !boxes.indices.contains(index) ? [0.0,0,1,1] : crops?[safe:index] ?? source.crop(boxes[index]).normalized(in:source.size)
        return source.preview(window:window,edge:edge(window:window,size:source.size,frame:frame,scale:scale))
    }
    var body:some View {
        // Fill whatever frame the caller proposes, then clip to it (not to the image's own fill size).
        Rectangle().fill(Palette.paper).overlay {if let image {Image(decorative:image,scale:displayScale).resizable().scaledToFill()}}
            .clipped().onGeometryChange(for:CGSize.self) {$0.size} action:{frame=CGSize(width:$0.width.rounded(),height:$0.height.rounded())}
            .task(id:"\(id)-\(index)-\(original)-\(boxes)-\(frame)") {
                guard let url,frame.width>0,frame.height>0 else{return}
                let key="\(id)-\(index)-\(original)-\(crops?[safe:index] ?? [])-\(frame)@\(displayScale)" as NSString
                if let hit=Self.cache.object(forKey:key) {image=hit;return}
                let value=await Self.load(url:url,boxes:boxes,crops:crops,index:index,original:original,frame:frame,scale:displayScale)
                if let value {Self.cache.setObject(value,forKey:key,cost:value.bytesPerRow*value.height)}
                if !Task.isCancelled,let value {image=value}
            }
    }
}
/// Counting semaphore for async code (no blocked threads).
final class Gate:@unchecked Sendable {
    private let lock=NSLock()
    private var free:Int
    private var waiting=[CheckedContinuation<Void,Never>]()
    init(_ n:Int) {free=n}
    func enter() async {
        await withCheckedContinuation {c in
            lock.lock()
            if free>0 {free-=1;lock.unlock();c.resume()} else {waiting.append(c);lock.unlock()}
        }
    }
    func leave() {
        lock.lock()
        if waiting.isEmpty {free+=1;lock.unlock()} else {let c=waiting.removeFirst();lock.unlock();c.resume()}
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
                        PhotoView(image:image,record:record,marks:marks,drawing:drawing,onSelect:{i in if i<count {page=i}},onDraw:{box in drawing=false;let i=record.boxes.isEmpty ? 0:record.selected;Task{await model.analyze(index:i,box:box,manual:true,newBox:true,place:record.place);page=i}})
                            .aspectRatio(image.size,contentMode:.fit).accessibilityIdentifier("result.photo")
                        if record.boxes.count>count {Text("还有 \(record.boxes.count-count) 只").font(.caption).foregroundStyle(.white)}
                    }.background(.black).tag(count)
                }
            }.tabViewStyle(.page(indexDisplayMode:.always)).indexViewStyle(.page(backgroundDisplayMode:.always))
                .frame(height:typeSize.isAccessibilitySize ? 560:320).background(Palette.paper).accessibilityIdentifier("result.pager")
            ScrollView(.horizontal) {
                HStack(spacing:12) {ForEach(0...count,id:\.self) {i in
                    Button {page=i} label:{VStack(spacing:3) {
                        CropThumbnail(url:model.url(record.id),record:record,index:i,original:i==count)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let record:Record
    let index:Int
    let active:Bool
    let marks:Bool
    @State private var image:CGImage?
    @State private var mask:CGImage?
    @State private var lifted:CGImage?
    @State private var removeBackground=false
    /// idle / success / fixture / none / unsupported — a fixture or fallback is never shown as real Vision success.
    @State private var maskState="idle"
    @State private var retried=false
    @State private var working=false
    @State private var saving=false
    @State private var saved=false
    var source:CropSource? {model.url(record.id).flatMap{CropSource($0)}}
    var window:[Double]? {source.map{record.displayCrops?[safe:index] ?? $0.crop(record.boxes[index]).normalized(in:$0.size)}}
    /// Saved/shared captions use the effective (corrected) name.
    var species:String {model.effective(record,index).name}
    var body:some View {
        // No inner vertical scroll: it would capture drags meant for the result page. The pager height fits this content at every type size.
        VStack(spacing:6) {
                if active,let image,let source,let window {
                    PhotoView(image:UIImage(cgImage:removeBackground ? lifted ?? image:image),record:CropCoordinates(window:window).record(record,index:index),marks:marks,drawing:false,neutral:true,onSelect:{_ in},onDraw:{_ in})
                        .aspectRatio(CGSize(width:image.width,height:image.height),contentMode:.fit).frame(maxHeight:typeSize.isAccessibilitySize ? 300:170).accessibilityIdentifier("result.crop.\(index)")
                    if source.crop(record.boxes[index]).tiny {Text("鸟很小").font(.caption).foregroundStyle(Palette.rust).accessibilityIdentifier("result.tiny")}
                    let controls=Group {
                        if maskState != "none" && maskState != "unsupported" {
                            Toggle("去背景",isOn:$removeBackground).toggleStyle(.button).disabled(working).accessibilityIdentifier("result.background")
                        }
                        if working {ProgressView()}
                        Button(saved ? "已保存":"保存到相册",systemImage:"square.and.arrow.down") {Task{await save(source:source,window:window)}}.disabled(saving).accessibilityIdentifier("result.save")
                        ShareLink(item:BirdShare(source:source,window:window,name:species,mask:removeBackground ? mask:nil),preview:SharePreview(species,image:Image(decorative:image,scale:1))) {Label("分享",systemImage:"square.and.arrow.up")}.accessibilityIdentifier("result.share")
                    }.buttonStyle(.bordered).frame(minHeight:44)
                    ViewThatFits(in:.horizontal) {HStack{controls};VStack{controls}}.font(.caption)
                    switch maskState {
                    case "none":
                        let note=Text("未找到合适的轮廓，矩形裁图仍可保存和分享。").font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("result.noMask")
                        let retry=Button("再试一次"){retried=true;maskState="idle";removeBackground=true}.font(.caption).frame(minHeight:44).accessibilityIdentifier("result.maskRetry")
                        if retried {note} else {ViewThatFits(in:.horizontal) {HStack{note;retry};VStack(spacing:0){note;retry}}}
                    case "unsupported": Text("此设备不支持去背景（模拟器不运行 Apple Vision 前景分割）。矩形裁图仍可保存和分享。").font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("result.maskUnsupported")
                    case "fixture": Text("测试夹具蒙版，不是 Apple Vision 结果").font(.caption).foregroundStyle(Palette.rust).accessibilityIdentifier("result.maskFixture")
                    case "success": Text("轮廓来自 Apple Vision，细腿、羽缘可能被切掉，请核对。").font(.caption2).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    default: EmptyView()
                    }
                } else {ProgressView().frame(maxWidth:.infinity,minHeight:160)}
            }.padding(.horizontal,8).padding(.bottom,40)   // clear of the page dots
            .frame(maxHeight:.infinity,alignment:.top).background(Palette.paper)
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
        var injected:String?
        #if DEBUG
        injected=UserDefaults.standard.string(forKey:"maskFixture")
        #endif
        #if targetEnvironment(simulator)
        if injected == nil {injected="unsupported"}
        #endif
        if let injected {
            if injected=="success",let m=BirdMask.ellipse(width:image.width,height:image.height,box:box),let l=source.image(window:window,edge:1200,mask:m) {mask=m;lifted=l;maskState="fixture"}
            else {removeBackground=false;maskState=injected=="unsupported" ? "unsupported":"none"}
            return
        }
        let output=await Task.detached {() -> Result<(CGImage,CGImage)?,Error> in
            do {
                guard let mask=try BirdMask.make(image:image,box:box),let lifted=source.image(window:window,edge:1200,mask:mask) else{return .success(nil)}
                return .success((mask,lifted))
            } catch {return .failure(error)}
        }.value
        guard !Task.isCancelled else{return}
        switch output {
        case .success(let v?): mask=v.0;lifted=v.1;maskState="success"
        case .success(nil): removeBackground=false;maskState="none"
        case .failure: removeBackground=false;maskState="unsupported"
        }
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
