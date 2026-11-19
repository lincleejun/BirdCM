import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main struct BirdCMApp: App {
    @State private var model = AppModel()
    init() {
        #if DEBUG
        Perf.log("LAUNCH"); Perf.watchMainThread()
        #endif
        Perf.mark("app.init")
    }
    var body: some Scene { WindowGroup { RootView().environment(model).tint(Palette.green)
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
/// Names are read-time derivations from the bundled catalogue, never the cached label in an old result.
func title(_ r: Identification) -> String {
    if r.level == "species", let k=r.name ?? r.top5.first?.scientific { return Catalogue.shared.name(k) }
    if r.level == "genus" { return "\(r.name ?? "") · 只到属" }
    return "不确定"
}

@MainActor @Observable final class AppModel {
    /// Names + detector (enough to start finding birds); `modelReady` once BioCLIP, heads and tables are in too.
    var engine: Engine?
    var previewing=false
    /// Model loading never blocks the UI and is not `busy` (an identification or re-rank in progress).
    var modelReady=false
    var modelError: String?
    /// A photo picked before the models were ready; kept through a load failure so 重试 continues it.
    var queued: Data?
    var picked: UIImage?
    var warmUpSeconds: Double?
    static let preparing=String(localized:"正在准备模型…")
    private var loading=false
    /// Bumped by cancel(): a cancelled identification or re-rank drops its result.
    private var run=0
    var status=""
    var busy=false
    var items=[PhotoItem]()
    var ledger=Ledger()
    let catalogue=Catalogue.shared
    var migration: Double?
    var libraryError: String?
    var current: Record?
    var photo: Photo?
    var preview: UIImage?
    enum Route: Hashable { case result(UUID), species(String) }
    enum Tab: Hashable { case identify, records, stats, explore }
    var tab=Tab.identify
    var paths=[Tab:[Route]]()
    var recordsMode="species"
    var settings=false
    /// Push a result on the initiating tab (identification always on 识别).
    func show(_ id:UUID,on t:Tab?=nil) {
        let t=t ?? tab;tab=t
        if paths[t]?.last != .result(id) {paths[t,default:[]].append(.result(id))}
    }
    var showing:Bool {
        get {paths.values.contains{$0.contains{if case .result=$0 {true} else {false}}}}
        set {if newValue,let id=current?.id {show(id,on:.identify)} else if !newValue {for t in paths.keys {paths[t]?.removeAll{if case .result=$0 {true} else {false}}}}}
    }
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
            return
        }
        #endif
        guard let data=pendingData else{return};pendingData=nil
        await identify(data)
    }
    let location=DeviceLocation()
    var library: Library?
    var sessionSeconds: Double=0
    var error: String?
    /// `history`: a separate store name for unit tests.
    init(previewState:String? = nil,history:String? = nil) {
        var historyName="History"
        #if DEBUG
        if previewState != nil {historyName="PreviewHistory"}
        #endif
        #if DEBUG
        if UserDefaults.standard.bool(forKey:"uiTesting") || UserDefaults.standard.string(forKey:"fixtureState") != nil || UserDefaults.standard.string(forKey:"previewState") != nil {historyName="UITestHistory"}
        #endif
        if let history {historyName=history}
        let dir=Models.support.appendingPathComponent(historyName)
        #if DEBUG
        if UserDefaults.standard.bool(forKey:"uiTesting") && UserDefaults.standard.bool(forKey:"resetHistory") {try? FileManager.default.removeItem(at:dir);homePlace=nil;UserDefaults.standard.removeObject(forKey:"homePlace");UserDefaults.standard.removeObject(forKey:"recentPlaceData")
            for k in ["backupFolderBookmark","backupFolderName","backupFolderOwn","backupFolderLast","backupFolderRevision","backupFolderError"] {UserDefaults.standard.removeObject(forKey:k)}}
        if let legacy=UserDefaults.standard.string(forKey:"legacyFixture") {Self.seedLegacy(dir,count:Int(legacy) ?? 3)}
        #endif
        openLibrary(dir)
        #if DEBUG
        if let previewState {
            items=[];homePlace=nil
            let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/photo-0.jpg").path
            preparePreview(previewState,path:path);return
        }
        if UserDefaults.standard.string(forKey:"fixtureState") != nil {previewing=true;return}
        if let state=UserDefaults.standard.string(forKey:"previewState"),let path=UserDefaults.standard.string(forKey:"previewImage") {
            preparePreview(state,path:path);return
        }
        #endif
        #if DEBUG
        // Hosted XCTest loads its own engine; avoid a second 600 MB tower in the test host UI.
        if NSClassFromString("XCTestCase") != nil {return}
        if let path=UserDefaults.standard.string(forKey:"debugImage"),let data=FileManager.default.contents(atPath:path) {Task{await identify(data)}}
        #endif
        load()
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
            if let r=current,let data=try? Data(contentsOf:URL(fileURLWithPath:path)) {
                // Distinct bytes, days and species: the library deduplicates identical originals.
                let pelican=Candidate(scientific:"Pelecanus occidentalis",english:"Brown Pelican",chinese:"褐鹈鹕",p:0.98)
                for i in 1..<max(1,min(8,UserDefaults.standard.integer(forKey:"historyFixtureCount"))) {
                    var copy=r;copy.id=UUID();copy.subjects=nil;copy.shooting.takenAt=String(format:"2026-10-%02dT10:26:00",20-i)
                    if i%2==1 {copy.result?.top5[0]=pelican;copy.result?.name=pelican.scientific;copy.results["0"]=copy.result}
                    _=try? library?.save(copy,data:data+Data([UInt8(i)]))
                }
                refresh()
            }
            busy=state=="loading"
        } else if let data=try? Data(contentsOf:URL(fileURLWithPath:path)) { await identify(data) }
    }
    #endif
    func openLibrary(_ dir:URL) {
        do {
            let library=try Library(dir:dir);self.library=library
            #if DEBUG
            let seed=UserDefaults.standard.integer(forKey:"seedSynthetic")
            if seed>0,!library.needsMigration,(try? library.query("SELECT count(*) FROM ll_record").first?.n(0)) == 0 {try library.seedSynthetic(seed,species:Array(catalogue.all.prefix(800).map(\.sci)))}
            #endif
            if library.needsMigration {migration=0;Task{await migrate()}} else {refresh()}
        } catch {libraryError=String(localized:"无法打开本机记录：\(error.localizedDescription)。旧文件未改动。")}
    }
    /// Old History JSON → library.sqlite off the main actor; mutations wait until it is verified.
    func migrate() async {
        guard let library else{return}
        migration=0;libraryError=nil
        do {
            try await Task.detached {try library.migrate {p in Task{@MainActor in if self.migration != nil {self.migration=p}}}}.value
            migration=nil;refresh()
        } catch {libraryError=String(localized:"整理旧记录未完成：\(error.localizedDescription)。旧文件保持原样，可以重试。")}
    }
    func refresh() {
        guard let library, migration == nil else {return}
        // A cleared/restored library must not leave a tombstoned record open in any tab.
        if let id=current?.id,(try? library.query("SELECT 1 FROM ll_record WHERE id=? AND deleted_utc IS NULL",[id.uuidString.lowercased()]).isEmpty) ?? false {showing=false;current=nil;photo=nil}
        let t0=Date()
        do { items=try library.items(); ledger=Ledger(items:items,edits:try library.groupEdits(),known:catalogue.contains) } catch { self.error=error.localizedDescription }
        Perf.mark("refresh",Date().timeIntervalSince(t0))
    }
    /// One shared commit path for every edit: write, reload the open record, refresh counts. False leaves the editor open.
    @discardableResult func edit(_ body:(Library) throws -> Void) -> Bool {
        guard let library, migration == nil else{return false}
        do {
            try body(library)
            if let id=current?.id,let r=try library.record(id) {var v=r;v.selected=current?.selected ?? r.selected;if let s=v.results[String(v.selected)] {v.result=s};current=v}
            refresh();UINotificationFeedbackGenerator().notificationOccurred(.success);return true
        } catch {self.error=String(localized:"保存失败：\(error.localizedDescription)");return false}
    }
    func url(_ id:UUID?) -> URL? {id.flatMap{library?.url($0)}}
    struct Effective {var name:String;var key:String?;var state:String;var model:Identification?;var count:Int?;var excluded:Bool;var subject:String?}
    /// Human correction outranks model/range/clarity; names come from the catalogue at read time.
    func effective(_ r:Record,_ i:Int) -> Effective {
        let model=r.results[String(i)] ?? (r.selected==i ? r.result:nil), e=r.subjects?[safe:i]
        let base=Effective(name:model.map(title) ?? String(localized:"鸟 \(i+1) · 未识别"),key:nil,state:e?.state ?? "none",model:model,count:e?.count,excluded:e?.excluded ?? false,subject:e?.id)
        switch e?.state {
        case "species": var v=base;v.name=catalogue.name(e?.key);v.key=e?.key;return v
        case "uncertain": var v=base;v.name=String(localized:"不确定");return v
        default: var v=base;if let m=model,Library.modelColumns(m).0=="species" {v.key=Library.modelColumns(m).1};return v
        }
    }
    @ObservationIgnored private var rarityCache=[String:RarityValue]()
    /// GBIF tier at the photo's own place and month, looked up now (never the stored label).
    func localRarity(_ key:String,_ r:Record) -> RarityValue {
        let item=items.first{$0.id==r.id}
        let month=item.flatMap{["photo","user"].contains($0.dateSource) ? Int($0.day.dropFirst(5).prefix(2)):nil} ?? r.shooting.month
        let id="\(key)|\(r.place.map{"\($0.lat),\($0.lon),\($0.regionCode ?? ""),\($0.source)"} ?? "-")|\(month ?? 0)|\(UserDefaults.standard.bool(forKey:"hideIUCN"))"
        if let v=rarityCache[id] {return v}
        // A region choice is evaluated by its ISO code (old region places stored only a label), never its representative point.
        var place=r.place
        if let p=place,p.source=="region",p.regionCode == nil {place?.regionCode=Library.regionCodes[p.label]}
        let v=catalogue.rarity?.lookup(key,place:place,month:month) ?? RarityValue(label:"数据不足",iucn:nil)
        rarityCache[id]=v;return v
    }
    /// Bird 1's effective name for lists: correction > model species; otherwise its pending state.
    func label(_ item:PhotoItem) -> String {
        guard let s=item.subjects.first else {return String(localized:"没找到鸟")}
        if s.excluded {return String(localized:"已排除")}
        if let k=s.key,catalogue.contains(k) {return catalogue.name(k)}
        return s.level=="genus" && s.state=="none" ? "\(s.modelKey ?? "") · 只到属":String(localized:"待确认")
    }
    func matches(_ item:PhotoItem,_ query:String) -> Bool {
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !q.isEmpty else {return true}
        let names=item.subjects.compactMap{$0.key ?? $0.modelKey}.compactMap{catalogue.species($0)}.flatMap{[$0.zh,$0.en,$0.sci]}
        return (names+[item.placeLabel ?? "",item.day]).contains{$0.localizedStandardContains(q)}
    }
    /// Background load, never blocking the UI: integrity (full hash once per build), names + detector (`engine`), then
    /// BioCLIP → heads → place model / rarity (`modelReady`), then a low-priority warm-up prediction.
    func load() {
        guard engine == nil || !modelReady, !loading, !previewing else {return}
        loading=true; modelError=nil
        Task {
            defer {loading=false}
            do {
                guard Models.present else {throw StoreError(message:String(localized:"安装包缺少模型，请重新安装完整 App。"))}
                #if DEBUG
                let delay=UserDefaults.standard.double(forKey:"delayModelLoad")
                if delay>0 {try await Task.sleep(for:.seconds(delay))}
                Self.loadAttempts+=1
                if Self.loadAttempts<=UserDefaults.standard.integer(forKey:"failModelLoad") {throw StoreError(message:String(localized:"测试：模拟加载失败"))}
                #endif
                let t0=Date()
                let check=try await Task.detached(priority:.userInitiated) {try Models.check()}.value
                Perf.mark(check.hashed ? "models.integrity.sha256":"models.integrity.sizes",Date().timeIntervalSince(t0))
                guard check.invalid.isEmpty else {throw StoreError(message:String(localized:"安装包损坏，请重新安装：")+check.invalid.joined(separator:"、"))}
                let e=try await Task.detached(priority:.userInitiated) {try Engine(dir:Models.dir)}.value
                engine=e;Perf.mark("models.detector")
                try await Task.detached(priority:.userInitiated) {try e.prepare()}.value
                modelReady=true;Perf.mark("models.ready")
                // A photo already waiting is its own warm-up; a second pass would only hold it up.
                if !busy {Task.detached(priority:.utility) {
                    guard let s=try? e.warmUp() else {return}
                    Perf.mark("models.warmup",s);Perf.mark("models.warm")
                    await MainActor.run {self.warmUpSeconds=s}
                }}
            } catch {
                engine=nil;modelReady=false
                modelError=String(localized:"模型加载失败：\(error.localizedDescription)")
            }
        }
    }
    #if DEBUG
    static var loadAttempts=0
    #endif
    /// 出错 → 重试: reload, and continue the photo that was waiting.
    func retry() {
        load()
        if let q=queued {Task{await identify(q)}}
    }
    /// Cancel the identification or re-rank on screen; its result, if it still arrives, is dropped.
    func cancel() {run+=1;busy=false;queued=nil;picked=nil;status=""}
    /// The engine for a job, waiting while the models load (the job's own photo stays on screen). nil: cancelled or failed.
    private func waitForEngine(_ job:Int) async -> Engine? {
        while job == run {
            if let engine {return engine}
            if modelError != nil {return nil}
            if !loading {load()}
            status=Self.preparing
            try? await Task.sleep(for:.milliseconds(100))     // ponytail: polling; a continuation list if this ever matters
        }
        return nil
    }
    func identify(_ data: Data) async {
        guard !busy, !(previewing && engine == nil) else { return }
        run+=1;let job=run
        if let source=CGImageSourceCreateWithData(data as CFData,nil),let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1024] as CFDictionary) {picked=UIImage(cgImage:thumbnail)} else {picked=nil}
        queued=data;busy=true;status=String(localized:"找鸟")
        let started=Date()
        defer { if job == run {busy=false} }
        guard let engine=await waitForEngine(job) else {
            if job == run {status=""}     // load failed: queued + picked stay on screen for 重试
            return
        }
        queued=nil
        if Date().timeIntervalSince(started)>0.2 {Perf.mark("identify.waitedForModels",Date().timeIntervalSince(started))}
        do {
            let shooting=Shooting(data:data)
            let place: Place?
            place=Place.resolve(photo:shooting.photoPlace,device:nil,manual:homePlace)
            status=String(localized:"找鸟")
            let made = try await Task.detached { () async throws -> (Record,Photo) in
                guard let photo=Photo(data:data) else { throw NSError(domain:"BirdCM",code:4,userInfo:[NSLocalizedDescriptionKey:"无法读取这张图。支持 JPEG、HEIC、PNG（含截图）；ProRAW/DNG 请先在照片中导出为 JPEG 或 HEIC。请换一张重试。"]) }
                let tick=Date(), boxes=try engine.detect(photo), detection=Date().timeIntervalSince(tick)
                let stage=engine.hasSpeciesModel ? String(localized:"认种"):String(localized:"认种（认种模型还在载入）")
                await MainActor.run {if job == self.run {self.status=stage}}
                var result: Identification?
                if let box=boxes.first { result=try engine.identify(photo,box:box,place:place,shooting:shooting); result?.diagnostics?.stages["检测"]=detection }
                let rel=boxes.map { [$0[0]/Double(photo.frame.w),$0[1]/Double(photo.frame.h),$0[2]/Double(photo.frame.w),$0[3]/Double(photo.frame.h)] }
                var record=Record(boxes:rel,selected:0,result:result,shooting:shooting,place:place)
                if let result { record.results["0"]=result }
                return (record,photo)
            }.value
            // Saving is an edit: it waits for a first-launch migration instead of failing.
            while migration != nil && libraryError == nil && job == run {status=String(localized:"等待旧记录整理完成…");try? await Task.sleep(for:.milliseconds(200))}
            guard job == run else {return}
            guard let library, migration == nil else { throw StoreError(message:String(localized:"本机记录还在整理，请稍后再试")) }
            var record=try library.save(made.0,data:data)
            if let url=library.url(record.id),let source=CropSource(url) {record.displayCrops=record.boxes.map{source.crop($0).normalized(in:source.size)};record=try library.save(record)}
            UIImpactFeedbackGenerator(style:.light).impactOccurred()
            current=record; photo=made.1; preview=UIImage(cgImage:made.1.frame.cgImage()); picked=nil; showing=true; refresh()
            sessionSeconds=Date().timeIntervalSince(started); status=""
            Perf.mark("identify.session",sessionSeconds)
            if let d=record.result?.diagnostics {Perf.log("PERF stages "+d.stages.sorted{$0.key<$1.key}.map{String(format:"%@=%.3f",$0.key,$0.value)}.joined(separator:" "))}
        } catch {
            guard job == run else {return}
            status=""
            if modelError != nil {queued=data;return}     // the load failed under us: keep the photo for 重试
            picked=nil;self.error=String(localized:"识别失败：\(error.localizedDescription)")
        }
    }
    /// Open a record, optionally at one subject (pending list), on the current tab.
    func open(_ id: UUID,subject:Int?=nil,push:Bool=true) {
        guard !busy, let library else { return }
        do {
            guard var r=try library.record(id) else { throw CocoaError(.fileReadNoSuchFile) }
            if let subject,r.boxes.indices.contains(subject) {r.selected=subject;r.result=r.results[String(subject)]}
            guard let url=library.url(id),let decoded=Photo(data:try Data(contentsOf:url)) else { throw StoreError(message:String(localized:"原图不可用，记录仍保留")) }
            current=r; photo=decoded; preview=UIImage(cgImage:decoded.frame.cgImage()); if push {show(id)}
        } catch { self.error=String(localized:"打开历史失败：\(error.localizedDescription)") }
    }
    func select(_ i: Int) async {
        guard !busy, var r=current, r.boxes.indices.contains(i) else { return }
        if let saved=r.results[String(i)] { r.selected=i; r.result=saved; current=r; return }
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
        guard !busy, let photo, var r=current else { return }
        run+=1;let job=run
        busy=true; defer{if job == run {busy=false;status=""}}
        guard let engine=await waitForEngine(job) else {if let e=modelError,job == run {self.error=e};return}
        status=String(localized:"识别当前主体…")
        do {
            let result=try await Task.detached {
                try engine.identify(photo,box:[box[0]*Double(photo.frame.w),box[1]*Double(photo.frame.h),box[2]*Double(photo.frame.w),box[3]*Double(photo.frame.h)],place:place,shooting:r.shooting,manual:manual)
            }.value
            guard job == run else {return}
            if r.place != place { r.results=[:] }
            // A hand-drawn box replaces only the selected subject (keeping its ID and edits); other birds stay.
            if newBox {
                if r.boxes.indices.contains(index) {r.boxes[index]=box;r.displayCrops=nil;r.results[String(index)]=nil;r.selected=index}
                else {r.boxes=[box];r.displayCrops=nil;r.results=[:];r.selected=0;r.subjects=nil}
                r.manual=true
            } else { r.selected=index }
            r.place=place; r.result=result; r.results[String(r.selected)]=result; persist(r)
        } catch { if job == run {self.error=String(localized:"识别失败：\(error.localizedDescription)")} }
    }
    func setPlace(_ p: Place) async {
        guard var r=current, !busy else { return }
        // An explicit result correction replaces even EXIF GPS; initial identification always prefers EXIF.
        run+=1;let job=run
        busy=true;defer{if job == run {busy=false;status=""}}
        // Never save a new place with candidates ranked for the old one: wait for the models (fixtures have none).
        let engine=previewing ? nil:await waitForEngine(job)
        guard job == run else {return}
        if !previewing && engine == nil {if let e=modelError {self.error=e};return}
        status="按地点更新候选…"
        do {
            if let engine {
                let saved=r
                let updated=try await Task.detached { () throws -> [String:Identification] in
                    var out=[String:Identification]()
                    if saved.results.isEmpty,let value=saved.result {out[String(saved.selected)]=try engine.rerank(value,place:p,shooting:saved.shooting)}
                    for (key,value) in saved.results {out[key]=try engine.rerank(value,place:p,shooting:saved.shooting)}
                    return out
                }.value
                guard job == run else {return}
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
        if r.displayCrops == nil, let url=url(r.id), let source=CropSource(url) {r.displayCrops=r.boxes.map{source.crop($0).normalized(in:source.size)}}
        guard let library else {current=r;return}
        do { current=try library.save(r); refresh() } catch { self.error=String(localized:"保存失败：\(error.localizedDescription)") }
    }
    func delete(_ id: UUID) {
        do { try library?.delete(id); if current?.id==id { showing=false;current=nil;photo=nil;preview=nil };refresh() }
        catch { self.error=String(localized:"删除失败：\(error.localizedDescription)") }
    }
}

/// Four native tabs, each with its own NavigationStack; settings is a gear sheet on every root (§6).
struct RootView: View {
    @Environment(AppModel.self) var model
    @Environment(\.scenePhase) private var phase
    func stack<V:View>(_ t:AppModel.Tab,@ViewBuilder _ root:()->V) -> some View {
        NavigationStack(path:Binding(get:{model.paths[t] ?? []},set:{model.paths[t]=$0})) {
            root().navigationDestination(for:AppModel.Route.self) {route in
                switch route {
                case .result(let id): ResultView(id:id)
                case .species(let key): SpeciesPage(key:key)
                }
            }
            .toolbar {ToolbarItem(placement:.topBarTrailing) {Button {model.settings=true} label:{Image(systemName:"gearshape").frame(width:44,height:44)}.accessibilityLabel("设置").accessibilityIdentifier("home.more")}}
        }
    }
    var body: some View {
        @Bindable var model=model
        Group {
            if let progress=model.migration {MigrationView(progress:progress)}
            else if model.library == nil,let e=model.libraryError {ContentUnavailableView("本机记录不可用",systemImage:"exclamationmark.triangle",description:Text(e))}
            else {
                TabView(selection:$model.tab) {
                    stack(.identify){IdentifyView()}.tabItem{Label("识别",systemImage:"camera.viewfinder").accessibilityIdentifier("tab.identify")}.tag(AppModel.Tab.identify)
                    stack(.records){RecordsView()}.tabItem{Label("记录",systemImage:"books.vertical").accessibilityIdentifier("tab.records")}.tag(AppModel.Tab.records)
                    stack(.stats){StatsView()}.tabItem{Label("统计",systemImage:"chart.bar").accessibilityIdentifier("tab.stats")}.tag(AppModel.Tab.stats)
                    stack(.explore){ExploreView()}.tabItem{Label("探索",systemImage:"magnifyingglass").accessibilityIdentifier("tab.explore")}.tag(AppModel.Tab.explore)
                }
            }
        }
        .background(Palette.paper)
        .sheet(isPresented:$model.settings) {SettingsView().debugAppearance()}
        .onChange(of:phase) {_,p in if p == .active && model.migration == nil {Task{await FolderBackup.shared.runIfDue(model.library)}}}
        .sheet(isPresented:$model.needsPlace) {
            NavigationStack {VStack(alignment:.leading,spacing:20) {
                Text("这张照片没有位置").font(.title2.bold())
                Text("补充大致地点，能减少相似鸟种认错。")
                PlacePickerActions(initial:model.homePlace) {p in model.chooseHome(p);Task{await model.identifyPending()}}
                Button("先不设，直接识别"){Task{await model.identifyPending()}}.accessibilityIdentifier("place.skip")
            }.padding().toolbar{Button("取消"){model.needsPlace=false;model.pendingData=nil}}}.presentationDetents([.medium,.large])
        }
        .alert("未能完成",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button("好"){model.error=nil}} message:{Text(model.error ?? "")}
        .foregroundStyle(Palette.ink)
        .debugAppearance()
    }
}
extension View {
    /// Debug-only acceptance overrides; applied to the root and to every sheet (sheets do not inherit them).
    @ViewBuilder func debugAppearance() -> some View {
        #if DEBUG
        let largest=UserDefaults.standard.bool(forKey:"largestType")
        self.preferredColorScheme(UserDefaults.standard.bool(forKey:"darkMode") ? .dark:nil)
            .transformEnvironment(\.dynamicTypeSize) {if largest {$0 = .accessibility5}}
        #else
        self
        #endif
    }
}

struct IdentifyView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pick: PhotosPickerItem?
    @State private var place=false
    @State private var map=false
    @State private var locating=false
    @State private var camera=false
    @State private var cameraNote:String?
    @State private var cameraDenied=false
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
    /// Native camera only when available; denied/unavailable never blocks the photo picker.
    func takePhoto() {
        cameraNote=nil;cameraDenied=false
        #if DEBUG
        if UserDefaults.standard.bool(forKey:"cameraFixture"),let path=UserDefaults.standard.string(forKey:"fixtureImage"),let data=FileManager.default.contents(atPath:path) {Task{await model.receive(data)};return}
        #endif
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {cameraNote=String(localized:"这台设备没有可用的相机，请从相册选择。");return}
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .denied,.restricted: cameraDenied=true;cameraNote=String(localized:"相机权限已关闭。可在设置里允许观羽使用相机，或从相册选择。")
        default: camera=true
        }
    }
    var body: some View {
        List {
            HStack(spacing:10) {Image("Mark").resizable().scaledToFit().frame(width:32,height:32).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true);Text("观羽 · 留住每一次相遇").font(.headline)}.foregroundStyle(Palette.green).listRowBackground(Color.clear)
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
                        ViewThatFits(in:.horizontal) {HStack {locationButton;mapButton};VStack(alignment:.leading) {locationButton;mapButton}}
                    }
                }.padding(.vertical,8)
            }.listRowBackground(Palette.surface)
            Section("最近记录") {
                if model.items.isEmpty {ContentUnavailableView("还没有记录",systemImage:"bird",description:Text("从相册选一张鸟的照片，或拍一张，开始第一条记录。")).listRowBackground(Palette.surface)}
                ForEach(model.items.prefix(3)) {r in
                    Button {model.open(r.id)} label:{HistoryRow(item:r)}.buttonStyle(.plain).accessibilityIdentifier("history.item.\(r.id)").listRowBackground(Palette.surface)
                }
                if !model.items.isEmpty {Button("查看全部 \(model.items.count) 张") {model.recordsMode="photos";model.tab = .records}.accessibilityIdentifier("home.allRecords").frame(minHeight:44)}
            }
            if typeSize.isAccessibilitySize {Text("系统选片无需相册访问授权；仅读取你选择的照片。").font(.caption).foregroundStyle(Palette.secondary).listRowBackground(Color.clear)}
            if let cameraNote {
                Section {
                    Text(cameraNote).accessibilityIdentifier(cameraDenied ? "camera.denied":"camera.unavailable")
                    if cameraDenied {Button("打开设置"){if let u=URL(string:UIApplication.openSettingsURLString) {UIApplication.shared.open(u)}}.frame(minHeight:44)}
                }
            }
        }
        .scrollContentBackground(.hidden).background(Palette.paper)
        .onAppear{Perf.mark("home.visible",once:true);DispatchQueue.main.async{Perf.mark("home.interactive",once:true)}}
        .navigationTitle("观羽").navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge:.bottom) {
            // Always usable: a photo picked while the models load waits on the identifying screen.
            VStack(spacing:6) {
                // At accessibility sizes the note moves into the list so the fixed bar stays short.
                if !typeSize.isAccessibilitySize {Text("系统选片无需相册访问授权；仅读取你选择的照片。").font(.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
                PhotosPicker(selection:$pick,matching:.images,preferredItemEncoding:.current) { Label("从相册选择",systemImage:"photo.on.rectangle").frame(maxWidth:.infinity,minHeight:54) }
                    .accessibilityIdentifier("home.photos").buttonStyle(PrimaryActionStyle()).disabled(model.busy)
                Button("拍照",systemImage:"camera"){takePhoto()}.accessibilityIdentifier("home.camera").frame(maxWidth:.infinity,minHeight:44).buttonStyle(.bordered).disabled(model.busy)
                ModelStatusLine()
            }.padding(.horizontal).padding(.vertical,8).background(Palette.paper)
        }
        .overlay { if model.busy || model.queued != nil { IdentifyingView() } }
        .sheet(isPresented:$place) {PlacePicker(onChoose:{p in model.chooseHome(p)}).debugAppearance()}
        .sheet(isPresented:$map) {MapPlacePicker(initial:model.homePlace){p in model.chooseHome(p)}}
        .fullScreenCover(isPresented:$camera) {CameraPicker(close:{camera=false}){data in Task{await model.receive(data)}}.ignoresSafeArea()}
        .onChange(of:pick) { Task {
            guard let pick else{return}
            do { if let d=try await pick.loadTransferable(type:Data.self) {await model.receive(d)} }
            catch {model.error=String(localized:"读取照片失败：\(error.localizedDescription)")}
            self.pick=nil
        } }
    }
}

/// UIImagePickerController camera; the capture is encoded once with its metadata and goes through the same receive path. Never saved to Photos.
struct CameraPicker: UIViewControllerRepresentable {
    let close:()->Void
    let done:(Data)->Void
    func makeUIViewController(context:Context) -> UIImagePickerController {let c=UIImagePickerController();c.sourceType = .camera;c.delegate=context.coordinator;return c}
    func updateUIViewController(_ c:UIImagePickerController,context:Context) {}
    func makeCoordinator() -> Coordinator {Coordinator(self)}
    final class Coordinator:NSObject,UIImagePickerControllerDelegate,UINavigationControllerDelegate {
        let parent:CameraPicker
        init(_ p:CameraPicker){parent=p}
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController) {parent.close()}
        func imagePickerController(_ picker:UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]) {
            defer{parent.close()}
            guard let image=info[.originalImage] as? UIImage,let cg=image.cgImage else{return}
            let orientation:[UIImage.Orientation:Int]=[.up:1,.upMirrored:2,.down:3,.downMirrored:4,.leftMirrored:5,.right:6,.rightMirrored:7,.left:8]
            var meta=(info[.mediaMetadata] as? [String:Any]) ?? [:]
            meta[kCGImagePropertyOrientation as String]=orientation[image.imageOrientation] ?? 1
            meta[kCGImageDestinationLossyCompressionQuality as String]=0.95
            let out=NSMutableData()
            guard let dest=CGImageDestinationCreateWithData(out,UTType.jpeg.identifier as CFString,1,nil) else{return}
            CGImageDestinationAddImage(dest,cg,meta as CFDictionary)
            if CGImageDestinationFinalize(dest) {parent.done(out as Data)}
        }
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
/// Quiet one-line model state on home: 准备中 / 就绪 / 出错 with 重试. Never an overlay, never disables anything.
struct ModelStatusLine: View {
    @Environment(AppModel.self) var model
    var body:some View {
        HStack(spacing:6) {
            if let e=model.modelError {
                Image(systemName:"exclamationmark.triangle").foregroundStyle(Palette.rust)
                Text(e).lineLimit(2).accessibilityIdentifier("home.modelStatus")
                Button("重试"){model.retry()}.font(.caption.bold()).frame(minHeight:44).accessibilityIdentifier("home.modelRetry")
            } else if model.modelReady || model.previewing {
                Image(systemName:"checkmark.circle")
                Text("离线模型就绪").accessibilityIdentifier("home.modelStatus")
            } else {
                ProgressView().controlSize(.mini)
                Text("正在准备离线模型，可以先选照片").accessibilityIdentifier("home.modelStatus")
            }
        }.font(.caption).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity)
    }
}
struct IdentifyingView: View {
    @Environment(AppModel.self) var model
    var body:some View {
        let failed = !model.busy && model.queued != nil
        VStack(spacing:16) {
            if let image=model.picked ?? model.preview {Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:280).background(.black)}
            if failed {
                Label("模型没有加载成功",systemImage:"exclamationmark.triangle").font(.headline).foregroundStyle(Palette.rust)
                Text(model.modelError ?? "").font(.footnote).multilineTextAlignment(.center)
                Text("照片还在这里，重试后会接着识别。").font(.footnote).foregroundStyle(Palette.secondary)
                Button("重试"){model.retry()}.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("identifying.retry")
            } else {
                ProgressView();Text(model.status).font(.headline).accessibilityIdentifier("identifying.stage")
                if model.status == AppModel.preparing {Text("模型就绪后自动继续：找鸟 → 认种").font(.subheadline).foregroundStyle(Palette.secondary)}
                else if model.status != "按地点更新候选…" {Text("找鸟 → 认种").font(.subheadline).foregroundStyle(Palette.secondary)}
            }
            Button("取消"){model.cancel()}.frame(minHeight:44).accessibilityIdentifier("identifying.cancel")
        }.padding(24).background(Palette.surface,in:RoundedRectangle(cornerRadius:24)).padding().accessibilityElement(children:.contain).accessibilityIdentifier("identifying")
    }
}
struct HistoryRow: View {
    @Environment(AppModel.self) var model
    let item: PhotoItem
    var body: some View {
        HStack(spacing:14) {
            CropThumbnail(url:model.url(item.id),id:item.id,boxes:item.boxes,crops:item.crops).frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:16)).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:6) {
                Text(model.label(item)).font(.headline)
                Text(item.dateSource=="photo" || item.dateSource=="user" ? item.wall.replacingOccurrences(of:"T",with:" "):item.day+" · 按识别日期").font(.caption).monospacedDigit()
                Text(item.placeLabel ?? String(localized:"没有地点")).font(.caption).foregroundStyle(Palette.secondary)
                if item.missing {Text("原图不可用").font(.caption).foregroundStyle(Palette.rust)}
                if item.subjects.contains(where:{$0.state != "none"}) {Text("已人工更正").font(.caption).foregroundStyle(Palette.green)}
            }
            Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(Palette.secondary)
        }.fixedSize(horizontal:false,vertical:true).padding(.vertical,6).accessibilityElement(children:.combine)
    }
}
struct MigrationView: View {
    @Environment(AppModel.self) var model
    let progress: Double
    var body: some View {
        VStack(spacing:16) {
            Text("正在整理旧记录").font(.title2.bold())
            ProgressView(value:progress).accessibilityIdentifier("migration.progress")
            Text("原图与旧文件都保留，完成并核对后才会启用新记录。期间不能修改记录。").font(.footnote).foregroundStyle(Palette.secondary)
            if let e=model.libraryError {Text(e).foregroundStyle(Palette.rust);Button("重试"){Task{await model.migrate()}}.frame(minHeight:44)}
        }.padding(24).accessibilityIdentifier("migration")
    }
}
