import PhotosUI
import SwiftUI

@main struct BirdCMApp: App {
    @State private var model = AppModel()
    var body: some Scene { WindowGroup { Home().environment(model).tint(Palette.green)
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in
            if let engine=model.engine { Task.detached { engine.releaseBioCLIP() } }
        }
    } }
}
enum Palette {
    static func adaptive(_ light: UInt32,_ dark: UInt32) -> Color {
        Color(uiColor:UIColor { t in
            let h=t.userInterfaceStyle == .dark ? dark:light
            return UIColor(red:Double((h>>16)&255)/255,green:Double((h>>8)&255)/255,blue:Double(h&255)/255,alpha:1)
        })
    }
    static func token(_ pair:(UInt32,UInt32)) -> Color {adaptive(pair.0,pair.1)}
    static let paper=token(ThemeContrast.paper), surface=token(ThemeContrast.surface)
    static let green=token(ThemeContrast.accent), ink=token(ThemeContrast.ink), rust=token(ThemeContrast.warning)
    static let secondary=token(ThemeContrast.secondary), button=token(ThemeContrast.button)


}
func title(_ r: Identification) -> String {
    if r.level == "species", let c=r.top5.first { return c.chinese.isEmpty ? c.english:c.chinese }
    if r.level == "genus" { return "\(r.name ?? "") · 只到属" }
    return "不确定"
}

@MainActor @Observable final class AppModel {
    var engine: Engine?
    var previewing=false
    var ready: Bool { engine != nil || previewing }
    var status=""
    var busy=false
    var history=[Record]()
    var current: Record?
    var photo: Photo?
    var preview: UIImage?
    var showing=false
    var loadSeconds: Double=0
    var homePlace: Place? = UserDefaults.standard.data(forKey:"homePlace").flatMap {try? JSONDecoder().decode(Place.self,from:$0)}
    var pendingData: Data?
    var needsPlace=false
    #if DEBUG
    var pendingFixtureState:String?
    #endif
    func chooseHome(_ p:Place) {
        UISelectionFeedbackGenerator().selectionChanged()
        homePlace=p
        if let data=try? JSONEncoder().encode(p) {UserDefaults.standard.set(data,forKey:"homePlace")}
        var recent=(UserDefaults.standard.data(forKey:"recentPlaceData").flatMap{try? JSONDecoder().decode([Place].self,from:$0)}) ?? []
        recent.removeAll{$0.label==p.label};recent.insert(p,at:0)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(recent.prefix(6))),forKey:"recentPlaceData")
    }
    func receive(_ data:Data) async {
        if Shooting(data:data).photoPlace == nil && homePlace == nil {pendingData=data;needsPlace=true}
        else {await identify(data)}
    }
    func identifyPending() async {
        needsPlace=false
        #if DEBUG
        if let state=pendingFixtureState, let path=UserDefaults.standard.string(forKey:"fixtureImage") {
            pendingFixtureState=nil;preparePreview(state,path:path)
            if let r=current,let data=try? Data(contentsOf:URL(fileURLWithPath:path)) {try? store?.save(r,data:data);refresh()}
            return
        }
        #endif
        guard let data=pendingData else{return};pendingData=nil
        await identify(data)
    }
    let location=DeviceLocation()
    var store: HistoryStore?
    var sessionSeconds: Double=0
    var error: String?
    init(previewState:String? = nil) {
        var historyName="History"
        #if DEBUG
        if previewState != nil {historyName="PreviewHistory"}
        #endif
        #if DEBUG
        if UserDefaults.standard.bool(forKey:"uiTesting") || UserDefaults.standard.string(forKey:"fixtureState") != nil || UserDefaults.standard.string(forKey:"previewState") != nil {historyName="UITestHistory"}
        #endif
        do { store=try HistoryStore(dir:Models.support.appendingPathComponent(historyName)); history=try store!.all() }
        catch { self.error=String(localized:"读取历史失败：\(error.localizedDescription)") }
        #if DEBUG
        if let previewState {
            history=[];homePlace=nil
            let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/photo-0.jpg").path
            preparePreview(previewState,path:path);return
        }
        if UserDefaults.standard.bool(forKey:"uiTesting") && UserDefaults.standard.bool(forKey:"resetHistory") {for r in history {try? store?.delete(r)};history=[];homePlace=nil;UserDefaults.standard.removeObject(forKey:"homePlace");UserDefaults.standard.removeObject(forKey:"recentPlaceData")}
        if UserDefaults.standard.string(forKey:"fixtureState") != nil {previewing=true;return}
        if let state=UserDefaults.standard.string(forKey:"previewState"),let path=UserDefaults.standard.string(forKey:"previewImage") {
            preparePreview(state,path:path);return
        }
        #endif
        #if DEBUG
        // Hosted XCTest loads its own engine; avoid a second 600 MB tower in the test host UI.
        if NSClassFromString("XCTestCase") != nil {return}
        #endif
        Task { await load() }
    }
    #if DEBUG
    func pickFixture() async {
        guard let path=UserDefaults.standard.string(forKey:"fixtureImage") else {return}
        if let state=UserDefaults.standard.string(forKey:"fixtureState") {
            if state=="no-location",homePlace == nil {pendingFixtureState=state;needsPlace=true;return}
            preview=UIImage(contentsOfFile:path)
            busy=true;status="找鸟 → 认种"
            try? await Task.sleep(for:.seconds(1))
            preparePreview(state,path:path)
            if let r=current,let data=try? Data(contentsOf:URL(fileURLWithPath:path)) {try? store?.save(r,data:data);refresh()}
            if let r=current,let data=try? Data(contentsOf:URL(fileURLWithPath:path)) {
                for _ in 1..<max(1,min(8,UserDefaults.standard.integer(forKey:"historyFixtureCount"))) {var copy=r;copy.id=UUID();try? store?.save(copy,data:data)}
                refresh()
            }
            busy=state=="loading"
        } else if let data=try? Data(contentsOf:URL(fileURLWithPath:path)) { await identify(data) }
    }
    #endif
    func refresh() { do { history=try store?.all() ?? [] } catch { self.error=error.localizedDescription } }
    func load() async {
        guard Models.present else { status="安装包损坏或缺少模型，请重新安装完整 App。"; return }
        busy=true; status="正在检查并加载离线模型…"
        defer{busy=false}
        do {
            let invalid=try await Task.detached {try Models.invalidRequiredAssets()}.value
            guard invalid.isEmpty else {
                status="安装包损坏，请重新安装："+invalid.joined(separator:"、")
                return
            }
            engine=nil
            engine=try await Task.detached { try Engine(dir:Models.dir) }.value
            loadSeconds=engine!.loadSeconds
            status=engine?.rarity == nil ? "稀有度表未安装，当前显示数据不足" : ""
            #if DEBUG
            if let path=UserDefaults.standard.string(forKey:"debugImage") { busy=false; await identify(try Data(contentsOf:URL(fileURLWithPath:path))) }
            #endif
        } catch { self.error=String(localized:"加载模型失败：\(error.localizedDescription)"); status="安装包无法加载，请重新安装完整 App。" }
    }
    func identify(_ data: Data) async {
        guard !busy, let engine else { return }
        if let source=CGImageSourceCreateWithData(data as CFData,nil),let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1024] as CFDictionary) {preview=UIImage(cgImage:thumbnail)} else {preview=nil}
        busy=true; status="找鸟 → 认种"
        let started=Date()
        defer { busy=false }
        do {
            let shooting=Shooting(data:data)
            let place: Place?
            place=Place.resolve(photo:shooting.photoPlace,device:nil,manual:homePlace)
            status="找鸟"
            let made = try await Task.detached { () async throws -> (Record,Photo) in
                guard let photo=Photo(data:data) else { throw NSError(domain:"BirdCM",code:4,userInfo:[NSLocalizedDescriptionKey:"无法读取这张图。支持 JPEG、HEIC、PNG（含截图）；ProRAW/DNG 请先在照片中导出为 JPEG 或 HEIC。请换一张重试。"]) }
                let tick=Date(), boxes=try engine.detect(photo), detection=Date().timeIntervalSince(tick)
                await MainActor.run {self.status="认种"}
                var result: Identification?
                if let box=boxes.first { result=try engine.identify(photo,box:box,place:place,shooting:shooting); result?.diagnostics?.stages["检测"]=detection }
                let rel=boxes.map { [$0[0]/Double(photo.frame.w),$0[1]/Double(photo.frame.h),$0[2]/Double(photo.frame.w),$0[3]/Double(photo.frame.h)] }
                var record=Record(boxes:rel,selected:0,result:result,shooting:shooting,place:place)
                if let result { record.results["0"]=result }
                return (record,photo)
            }.value
            guard let store else { throw CocoaError(.fileWriteUnknown) }
            var record=made.0
            try store.save(record,data:data)
            if let source=CropSource(store.image(record)) {record.displayCrops=record.boxes.map{source.crop($0).normalized(in:source.size)};try store.save(record)}
            UIImpactFeedbackGenerator(style:.light).impactOccurred()
            current=record; photo=made.1; preview=UIImage(cgImage:made.1.frame.cgImage()); showing=true; refresh()
            sessionSeconds=Date().timeIntervalSince(started); status=""
        } catch { self.error=String(localized:"识别失败：\(error.localizedDescription)"); status="" }
    }
    func open(_ r: Record) {
        guard !busy, let store else { return }
        do {
            guard let decoded=Photo(data:try Data(contentsOf:store.image(r))) else { throw CocoaError(.fileReadCorruptFile) }
            current=r; photo=decoded; preview=UIImage(cgImage:decoded.frame.cgImage()); showing=true
        } catch { self.error=String(localized:"打开历史失败：\(error.localizedDescription)") }
    }
    func select(_ i: Int) async {
        guard !busy, var r=current, r.boxes.indices.contains(i) else { return }
        if let saved=r.results[String(i)] { r.selected=i; r.result=saved; persist(r); return }
        await analyze(index:i,box:r.boxes[i],manual:r.manual,newBox:false,place:r.place)
    }
    func analyze(index: Int,box: [Double],manual: Bool,newBox: Bool,place: Place?) async {
        #if DEBUG
        if previewing, var r=current {
            if newBox {r.boxes=[box];r.displayCrops=nil;r.selected=0;r.manual=true}
            r.place=place
            if r.result == nil { preparePreview("normal",path:UserDefaults.standard.string(forKey:"fixtureImage") ?? UserDefaults.standard.string(forKey:"previewImage") ?? "");r.result=current?.result }
            persist(r);return
        }
        #endif
        guard !busy, let engine, let photo, var r=current else { return }
        busy=true; status=String(localized:"识别当前主体…"); defer{busy=false;status=""}
        do {
            let result=try await Task.detached {
                try engine.identify(photo,box:[box[0]*Double(photo.frame.w),box[1]*Double(photo.frame.h),box[2]*Double(photo.frame.w),box[3]*Double(photo.frame.h)],place:place,shooting:r.shooting,manual:manual)
            }.value
            if r.place != place { r.results=[:] }
            if newBox { r.boxes=[box]; r.displayCrops=nil; r.results=[:]; r.selected=0; r.manual=true } else { r.selected=index }
            r.place=place; r.result=result; r.results[String(r.selected)]=result; persist(r)
        } catch { self.error=String(localized:"识别失败：\(error.localizedDescription)") }
    }
    func setPlace(_ p: Place) async {
        guard var r=current, !busy else { return }
        // An explicit result correction replaces even EXIF GPS; initial identification always prefers EXIF.
        busy=true;status="按地点更新候选…";defer{busy=false;status=""}
        do {
            if let engine {
                let saved=r
                let updated=try await Task.detached { () throws -> [String:Identification] in
                    var out=[String:Identification]()
                    if saved.results.isEmpty,let value=saved.result {out[String(saved.selected)]=try engine.rerank(value,place:p,shooting:saved.shooting)}
                    for (key,value) in saved.results {out[key]=try engine.rerank(value,place:p,shooting:saved.shooting)}
                    return out
                }.value
                r.results=updated; r.result=updated[String(r.selected)]
            }
            #if DEBUG
            if previewing, UserDefaults.standard.string(forKey:"fixtureState")=="location-rerank" {
                let visual=r.result!.visual!
                r.result=Confirm.decide(p:Confirm.posterior(visual,[0,0.95,0.03]),rows:Self.blackbirdRows,wide:[0,0.95,0.03],typical:[0,0.6,0.01]);r.result?.visual=visual
                r.results[String(r.selected)]=r.result
            }
            #endif
            r.place=p;persist(r)
        } catch {self.error=error.localizedDescription}
    }
    func persist(_ value: Record) {
        var r=value
        if r.displayCrops == nil, let url=store?.image(r), let source=CropSource(url) {r.displayCrops=r.boxes.map{source.crop($0).normalized(in:source.size)}}
        do { try store?.save(r); current=r; refresh() } catch { self.error=String(localized:"保存失败：\(error.localizedDescription)") }
    }
    func delete(_ r: Record) {
        do { try store?.delete(r); if current?.id==r.id { showing=false;current=nil;photo=nil;preview=nil };refresh() }
        catch { self.error=String(localized:"删除失败：\(error.localizedDescription)") }
    }
}

struct Home: View {
    @Environment(AppModel.self) var model
    @State private var pick: PhotosPickerItem?
    @State private var clear=false
    @State private var about=false
    @State private var diagnostics=false
    @State private var place=false
    @State private var map=false
    @State private var locating=false
    @Environment(\.dynamicTypeSize) private var systemType
    @State private var search=""
    @State private var speciesSort=false
    var locationButton:some View {
        Button(locating ? "正在定位…":"用我现在的位置",systemImage:"location.fill") {Task {
            locating=true
            if let p=await model.location.request() {model.chooseHome(p)} else {map=true}
            locating=false
        }}.disabled(locating).accessibilityIdentifier("home.locate").frame(maxWidth:.infinity,minHeight:44).buttonStyle(.bordered)
    }
    var mapButton:some View {
        Button("在地图上选",systemImage:"map"){map=true}.accessibilityIdentifier("home.map").frame(maxWidth:.infinity,minHeight:44).buttonStyle(.bordered)
    }
    var visible: [Record] {
        let found=model.history.filter{$0.matches(search)}
        return speciesSort ? found.sorted{($0.result.map(title) ?? "") < ($1.result.map(title) ?? "")} : found
    }
    var body: some View {
        @Bindable var model=model
        NavigationStack {
            Group {
                if !model.ready { ContentUnavailableView("离线识别",systemImage:"bird",description:Text(model.status)) }
                else {
                    List {
                        HStack(spacing:10) {Image(systemName:"bird.fill").font(.title2);Text("观羽 · 留住每一次相遇").font(.headline)}.foregroundStyle(Palette.green).listRowBackground(Color.clear)
                        Section {
                            VStack(alignment:.leading,spacing:12) {
                                Button {place=true} label: {
                                    if let p=model.homePlace {
                                        HStack {Image(systemName:"mappin.and.ellipse");Text(p.label).font(.headline);Text(p.sourceLabel).font(.caption).foregroundStyle(Palette.secondary);Spacer();Text("更改").font(.subheadline)}
                                    } else {
                                        Label("还没有地点 · 只凭图像识别容易认错",systemImage:"mappin.and.ellipse").foregroundStyle(Palette.ink)
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("home.place")
                                if model.homePlace == nil {
                                Text("地点只用于判断此地此季可能出现的鸟。定位失败或拒绝后可在地图上选。").font(.footnote).foregroundStyle(Palette.secondary)
                                ViewThatFits(in:.horizontal) {
                                    HStack {locationButton;mapButton}
                                    VStack(alignment:.leading) {locationButton;mapButton}
                                }
                                }
                            }.padding(.vertical,8)
                        }.listRowBackground(Palette.surface)
                        Section("识别历史") {
                            if model.history.count >= 8 || !search.isEmpty || speciesSort {
                                TextField("搜索鸟名或地点",text:$search,prompt:Text("搜索鸟名或地点").foregroundColor(Palette.secondary)).accessibilityIdentifier("history.search")
                                Toggle("按鸟种排序",isOn:$speciesSort).accessibilityIdentifier("history.sort")
                            }
                            if model.history.isEmpty { ContentUnavailableView("还没有记录",systemImage:"bird",description:Text("从相册选一张鸟的照片开始。")) .listRowBackground(Palette.surface) }
                            if !model.history.isEmpty && visible.isEmpty {ContentUnavailableView("没有匹配的记录",systemImage:"magnifyingglass",description:Text("试试中文名、英文名、学名或地点。"))}
                            ForEach(visible) { r in
                                Button { model.open(r) } label: { HistoryRow(record:r) }.buttonStyle(.plain).accessibilityIdentifier("history.item.\(r.id)").listRowBackground(Palette.surface)
                                .swipeActions { Button("删除",role:.destructive){model.delete(r)}.accessibilityIdentifier("history.delete.\(r.id)") }
                            }
                        }
                        if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(Palette.secondary) }
                    }.scrollContentBackground(.hidden)
                }
            }
            .background(Palette.paper)
            .navigationTitle("观羽").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) { Menu {
                    Button("关于与数据来源") {about=true}.accessibilityIdentifier("home.about")
                    #if DEBUG
                    Button("诊断"){diagnostics=true}.accessibilityIdentifier("home.diagnostics")
                    #endif
                    Button("清空历史",role:.destructive) {clear=true}.accessibilityIdentifier("history.clear").disabled(model.history.isEmpty)
                } label:{Image(systemName:"ellipsis").frame(width:44,height:44).accessibilityLabel("更多操作").accessibilityIdentifier("home.more")} }
            }
            .safeAreaInset(edge:.bottom) {
                if model.ready {
                    VStack(spacing:4) {
                        Text("系统选片无需相册访问授权；仅读取你选择的照片。").font(.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
                        PhotosPicker(selection:$pick,matching:.images,preferredItemEncoding:.current) { Label("从相册选择",systemImage:"photo.on.rectangle").frame(maxWidth:.infinity,minHeight:54) }
                            .accessibilityIdentifier("home.photos").buttonStyle(PrimaryActionStyle()).disabled(model.busy)

                    }.padding().background(Palette.paper)
                }
            }
            .overlay { if model.busy { IdentifyingView() } }
            .navigationDestination(isPresented:$model.showing) { if model.current != nil { ResultView() } }
            .sheet(isPresented:$place) {PlacePicker(onChoose:{p in model.chooseHome(p)})}
            .sheet(isPresented:$map) {MapPlacePicker(initial:model.homePlace){p in model.chooseHome(p)}}
            .sheet(isPresented:$model.needsPlace) {
                NavigationStack {VStack(alignment:.leading,spacing:20) {
                    Text("这张照片没有位置").font(.title2.bold())
                    Text("补充大致地点，能减少相似鸟种认错。")
                    PlacePickerActions(initial:model.homePlace) {p in model.chooseHome(p);Task{await model.identifyPending()}}
                    Button("先不设，直接识别"){Task{await model.identifyPending()}}.accessibilityIdentifier("place.skip")
                }.padding().toolbar{Button("取消"){model.needsPlace=false;model.pendingData=nil}}}.presentationDetents([.medium,.large])
            }
            .sheet(isPresented:$about) { AboutView() }
            .sheet(isPresented:$diagnostics) { DiagnosticsView() }
            .confirmationDialog("清空全部本机历史？此操作无法撤销。",isPresented:$clear,titleVisibility:.visible) {
                Button("清空历史",role:.destructive) {for r in model.history {model.delete(r)}}.accessibilityIdentifier("history.confirmClear")
                Button("取消",role:.cancel){}
            }
            .alert("未能完成",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button("好"){model.error=nil}} message:{Text(model.error ?? "")}
            .onChange(of:pick) { Task {
                guard let pick else{return}
                do { if let d=try await pick.loadTransferable(type:Data.self) {await model.receive(d)} }
                catch {model.error=String(localized:"读取照片失败：\(error.localizedDescription)")}
                self.pick=nil
            } }
        }.foregroundStyle(Palette.ink)
        #if DEBUG
        .preferredColorScheme(UserDefaults.standard.bool(forKey:"darkMode") ? .dark:nil)
        .dynamicTypeSize(UserDefaults.standard.bool(forKey:"largestType") ? .accessibility5 : systemType)
        #endif
    }
}
struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    @Environment(\.colorSchemeContrast) var contrast
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(Color.white)
            .padding(.horizontal,16).frame(minHeight:54)
            .background(enabled ? Palette.button:Color(white:0.35),in:RoundedRectangle(cornerRadius:16))
            .overlay {if contrast == .increased {RoundedRectangle(cornerRadius:16).stroke(.white,lineWidth:2)}}
            .overlay {if configuration.isPressed {RoundedRectangle(cornerRadius:16).fill(.black.opacity(0.18))}}
    }
}
struct IdentifyingView: View {
    @Environment(AppModel.self) var model
    var body:some View {
        VStack(spacing:20) {
            if let image=model.preview {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:280).background(.black)}
            ProgressView();Text(model.status).font(.headline)
            if model.status != "按地点更新候选…" {Text("找鸟 → 认种").font(.subheadline).foregroundStyle(Palette.secondary)}
        }.padding(24).background(Palette.surface,in:RoundedRectangle(cornerRadius:24)).padding().accessibilityIdentifier("identifying")
    }
}
struct HistoryRow: View {
    @Environment(AppModel.self) var model
    let record: Record
    @ViewBuilder func historyBadges(_ value:RarityValue) -> some View {
        let colors=ThemeContrast.rarity[value.label] ?? (0x000000,0xdddddd)
        Text(value.label).font(.caption).padding(.horizontal,8).padding(.vertical,4)
            .foregroundStyle(Palette.adaptive(colors.0,colors.0)).background(Palette.adaptive(colors.1,colors.1),in:Capsule())
        if let code=value.iucn {
            let colors=ThemeContrast.iucn[code] ?? (0x000000,0xdddddd)
            Text("IUCN · "+code).font(.caption).padding(.horizontal,8).padding(.vertical,4)
                .foregroundStyle(Palette.adaptive(colors.0,colors.0)).background(Palette.adaptive(colors.1,colors.1),in:Capsule())
        }
    }
    var body: some View {
        HStack(spacing:14) {
            CropThumbnail(url:model.store?.image(record),record:record).frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:16)).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:6) {
                Text(record.result.map(title) ?? "没找到鸟").font(.headline)
                Text(record.shooting.takenAt?.replacingOccurrences(of:"T",with:" ") ?? "拍摄时间未知").font(.caption).monospacedDigit()
                Text(record.place?.label ?? "没有地点").font(.caption).foregroundStyle(Palette.secondary)
                if let rarity=record.result?.rarity {
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:6) {historyBadges(rarity)}
                        VStack(alignment:.leading,spacing:6) {historyBadges(rarity)}
                    }
                }
            }
            Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(Palette.secondary)
        }.fixedSize(horizontal:false,vertical:true).padding(.vertical,6).accessibilityElement(children:.combine)
    }
}
