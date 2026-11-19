import PhotosUI
import SwiftUI
import MapKit
import CoreLocation

struct ResultView: View {
    @Environment(AppModel.self) var model
    var id: UUID?
    @State private var marks=true
    @State private var draw=false
    @State private var place=false
    @State private var pick: PhotosPickerItem?
    @State private var candidate: CandidateSheet?
    @State private var correcting=false
    @State private var counting=false
    @State private var dating=false
    @State private var deleting=false
    @State private var candidatesOpen:Bool?    // nil = the rule; never remembered across results
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if let r=model.current, id == nil || r.id == id {
            let item=model.items.first{$0.id==r.id}
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    BirdPager(record:r,marks:$marks,drawing:$draw).disabled(model.busy)
                    VStack(alignment:.leading,spacing:24) {
                        HStack {
                            Toggle("显示标记",isOn:$marks).toggleStyle(.button).accessibilityIdentifier("result.marks").frame(minHeight:44)
                            Spacer()
                            Button(draw ? "取消画框":"手动画框"){draw.toggle()}.accessibilityIdentifier("result.draw").frame(minHeight:44)
                        }.font(.subheadline)
                        if draw {
                            Text("在照片上拖出包含鸟的矩形；有选中的鸟时替换它的框，更正保留。").foregroundStyle(Palette.rust)
                            Button("用整张照片识别") {draw=false;Task{await model.analyze(index:r.selected,box:[0,0,1,1],manual:true,newBox:true,place:r.place)}}.accessibilityIdentifier("result.wholePhoto").frame(minHeight:44)
                        }
                        if r.boxes.isEmpty {
                            Text("没找到鸟").font(.largeTitle.bold()).accessibilityIdentifier("result.name")
                            Text("在照片上画框，或使用整张照片重试。这张照片仍保留在记录里，不计入鸟种。").foregroundStyle(Palette.secondary)
                            Button("用整张照片识别") {Task{await model.analyze(index:0,box:[0,0,1,1],manual:true,newBox:true,place:r.place)}}.accessibilityIdentifier("result.wholePhoto").buttonStyle(.borderedProminent).frame(minHeight:44)
                        } else { identification(r) }
                        Divider()
                        VStack(alignment:.leading,spacing:14) {
                            Text("拍摄信息").font(.headline).accessibilityIdentifier("result.shooting")
                            ForEach(["相机","镜头","焦距","光圈","快门","ISO","曝光补偿"],id:\.self) { key in
                                if let value=r.shooting.fields[key] { LabeledContent(LocalizedStringKey(key)){Text(value).monospacedDigit().fixedSize(horizontal:false,vertical:true)} }
                            }
                            LabeledContent("统计日期"){Text(item.map{$0.dateSource=="photo" || $0.dateSource=="user" ? $0.wall.replacingOccurrences(of:"T",with:" "):$0.day} ?? "未知").monospacedDigit().accessibilityIdentifier("result.date")}
                            if let item {Text(Self.dateNote(item)).font(.caption).foregroundStyle(Palette.secondary)}
                            Button(item?.dateSource=="user" ? "修改日期（已改过）":"修改日期",systemImage:"calendar"){dating=true}.accessibilityIdentifier("result.editDate").frame(minHeight:44)
                        }.font(.subheadline).fixedSize(horizontal:false,vertical:true)
                        Divider()
                        VStack(alignment:.leading,spacing:12) {
                            Text("拍摄地点").font(.headline).accessibilityIdentifier("result.place")
                            if let p=r.place {
                                Text(p.label)
                                Text(p.sourceLabel).font(.caption).foregroundStyle(Palette.secondary)
                                if p.source=="region" {Text("按地区统计，不是具体坐标。").font(.caption).foregroundStyle(Palette.secondary)}
                                else {Map(initialPosition:.region(MKCoordinateRegion(center:CLLocationCoordinate2D(latitude:p.lat,longitude:p.lon),latitudinalMeters:100000,longitudinalMeters:100000))) {Marker(p.label,coordinate:CLLocationCoordinate2D(latitude:p.lat,longitude:p.lon))}.id("\(p.lat),\(p.lon)").frame(height:140).allowsHitTesting(false).accessibilityLabel("识别使用的地点地图")}
                            } else {Text("没有地点，当前仅按图像识别；统计时同日地点未知的记录合并。") .foregroundStyle(Palette.secondary)}
                            if let gps=r.shooting.photoPlace,r.place != gps {Button("改回照片自带的位置",systemImage:"location"){Task{await model.setPlace(gps)}}.accessibilityIdentifier("result.photoPlace").frame(minHeight:44)}
                        }
                        let aliases=model.library?.aliases(r.id) ?? 0
                        if aliases>0 {Text("另有 \(aliases) 个旧识别版本：同一照片，只统计一次。").font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("result.aliases")}
                        if item?.missing == true {Text("原图不可用；记录与识别仍保留。").foregroundStyle(Palette.rust)}
                        Text("照片和识别记录仅保存在此设备。").font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("result.footer")
                    }.fixedSize(horizontal:false,vertical:true).padding(20)
                }.padding(.bottom,24)
            }
            .accessibilityIdentifier("result.scroll")
            .background(Palette.surface)
            .navigationTitle("识别结果").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.topBarTrailing){Menu {
                Button("删除这条记录",role:.destructive){deleting=true}
            } label:{Image(systemName:"ellipsis").frame(width:44,height:44).accessibilityLabel("结果操作")}}}
            .safeAreaInset(edge:.bottom) {
                // One bar above the tab bar; actions stack vertically at accessibility sizes instead of clipping.
                let photos=PhotosPicker(selection:$pick,matching:.images,preferredItemEncoding:.current){Label("再选一张",systemImage:"photo.on.rectangle").frame(maxWidth:.infinity,minHeight:54)}.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("result.photos")
                let placeButton=Button("改地点",systemImage:"mappin.and.ellipse"){place=true}.accessibilityIdentifier("result.bottomPlace").frame(minHeight:44)
                let delete=Button("删除",systemImage:"trash",role:.destructive){deleting=true}.labelStyle(.iconOnly).accessibilityIdentifier("result.delete").frame(minWidth:44,minHeight:44)
                Group {
                    if typeSize.isAccessibilitySize {VStack(spacing:4){photos;HStack{placeButton;Spacer();delete}}}
                    else {HStack(spacing:16){photos;placeButton;delete}}
                }.font(.subheadline).padding(.horizontal).padding(.vertical,8).background(Palette.paper).disabled(model.busy)
            }
            .confirmationDialog("删除这条记录？",isPresented:$deleting,titleVisibility:.visible) {
                Button("删除",role:.destructive){model.delete(r.id)}.accessibilityIdentifier("result.confirmDelete")
                Button("取消",role:.cancel){}
            } message:{Text("从观羽的记录与统计中移除这张照片；相册或文件里的原图不受影响。")}
            .sheet(isPresented:$place){PlacePicker().debugAppearance()}
            .sheet(isPresented:$correcting){CorrectionSheet(record:r,index:r.selected).debugAppearance()}
            .sheet(isPresented:$counting){CountSheet(record:r,index:r.selected).debugAppearance()}
            .sheet(isPresented:$dating){if let item {DateSheet(item:item)}}
            .sheet(item:$candidate){c in
                NavigationStack{ScrollView{VStack(alignment:.leading,spacing:16){
                    Text(model.catalogue.name(c.value.scientific)).font(.title)
                    Text(c.value.english);Text(c.value.scientific).italic()
                    Text("候选把握 \(c.value.p.formatted(.percent.precision(.fractionLength(1))))")
                    let rarity=model.localRarity(c.value.scientific,r)
                    Text("当地当月：\(rarity.label)")
                    if !UserDefaults.standard.bool(forKey:"hideIUCN") {Text("IUCN：\(Rarity.iucnLabel(rarity.iucn))")}
                    Text("候选并非已确认鉴定。当地频次来自观测记录，不代表实际种群数量。").foregroundStyle(Palette.secondary)
                }.fixedSize(horizontal:false,vertical:true).padding().accessibilityIdentifier("candidate.details")}.toolbar{Button("完成"){candidate=nil}.accessibilityIdentifier("candidate.done")}}.presentationDetents([.medium,.large])
            }
            .onChange(of:pick) { Task {
                guard let pick else{return}
                do{if let data=try await pick.loadTransferable(type:Data.self){await model.receive(data)}}catch{model.error=error.localizedDescription}
                self.pick=nil
            } }
            .overlay {if model.busy{IdentifyingView()}}
            .onChange(of:"\(r.id)-\(r.selected)") {candidatesOpen=nil}
        } else if let id {
            ProgressView().onAppear{model.open(id,push:false)}
        }
    }
    static func dateNote(_ item:PhotoItem) -> String {
        switch item.dateSource {
        case "user": return String(localized:"你修改过的日期。")
        case "identified": return String(localized:"拍摄日期缺失，按首次识别日期统计。")
        case "identified_legacy_zone": return String(localized:"拍摄日期缺失，按首次识别日期统计（旧记录按升级时本机时区换算）。")
        default: return item.offset == nil ? String(localized:"照片未记录时区，按相机日期统计。"):String(localized:"照片记录的拍摄时间。")
        }
    }
    @ViewBuilder func factChips(_ e:AppModel.Effective,_ r:Record) -> some View {
        if e.model?.flying ?? 0 >= 0.5 && e.state != "uncertain" {Label("在飞",systemImage:"bird.fill").font(.subheadline).padding(8).background(Palette.paper,in:Capsule())}
        if let key=e.key {
            let value=model.localRarity(key,r)
            let colors=ThemeContrast.rarity[value.label] ?? (0x000000,0xdddddd)
            // GBIF reporting tier at this photo's place and month (read now, not stored).
            Text("本地 · "+value.label).font(.subheadline).foregroundStyle(Palette.adaptive(colors.0,colors.0)).padding(8).background(Palette.adaptive(colors.1,colors.1),in:Capsule())
                .accessibilityIdentifier("result.localRarity").accessibilityValue(value.label)
            if let code=value.iucn {
                let colors=ThemeContrast.iucn[code] ?? (0x000000,0xdddddd)
                Text("IUCN · "+Rarity.iucnLabel(code)).font(.subheadline.bold()).foregroundStyle(Palette.adaptive(colors.0,colors.0)).padding(8).background(Palette.adaptive(colors.1,colors.1),in:Capsule())
            }
        }
        if e.state=="none",let m=e.model,m.level != "species" || m.reason != nil {Text("近似种请核对").font(.subheadline).foregroundStyle(Palette.rust)}
    }
    @ViewBuilder func identification(_ r: Record) -> some View {
        let e=model.effective(r,r.selected)
        VStack(alignment:.leading,spacing:8) {
            Text(e.name).accessibilityIdentifier("result.name").accessibilityValue(e.state=="none" ? e.model?.level ?? "unclassified":e.state).font(.largeTitle.bold()).foregroundStyle(e.key == nil ? Palette.rust:Palette.ink).accessibilityAddTraits(.isHeader)
            if let k=e.key,let sp=model.catalogue.species(k) {
                if !sp.en.isEmpty {Text(sp.en).font(.title3)}
                Text(sp.sci).italic().foregroundStyle(Palette.secondary)
                if sp.zh.isEmpty {Text("暂无中文名").font(.caption).foregroundStyle(Palette.secondary)}
            }
            if e.state=="species" {Label("已人工更正",systemImage:"person.crop.circle.badge.checkmark").font(.subheadline).foregroundStyle(Palette.green).accessibilityIdentifier("result.corrected")}
            ViewThatFits(in:.horizontal) {HStack {factChips(e,r)};VStack(alignment:.leading) {factChips(e,r)}}
            if e.state=="none",let result=e.model {
                if result.level=="species",let c=result.top5.first {
                    ProgressView(value:c.p).tint(Palette.green)
                    Text("把握 \(c.p.formatted(.percent.precision(.fractionLength(1))))").font(.subheadline).monospacedDigit()
                    if result.clear == false {Text("鸟的特征不够清楚，暂不计入鸟种；可以更正。").font(.subheadline).foregroundStyle(Palette.rust)}
                } else if result.level=="genus" {Text("可以判断到属，具体鸟种不确定。属级把握 \((result.genusP ?? 0).formatted(.percent.precision(.fractionLength(1))))")}
                else {Text("还不能确定是哪种鸟，看看这些可能。")}
            } else if e.state=="none" {
                Text("这只还没识别。").foregroundStyle(Palette.secondary)
                Button("识别这只"){Task{await model.select(r.selected)}}.accessibilityIdentifier("result.identifySubject").frame(minHeight:44)
            }
            if e.excluded {Text("已排除这个主体，不计入统计。").foregroundStyle(Palette.rust).accessibilityIdentifier("result.excluded")}
            let actions=Group {
                Button("更正鸟种",systemImage:"pencil"){correcting=true}.accessibilityIdentifier("result.correctSpecies")
                Button(e.count.map{"数量 \($0)（已改）"} ?? "数量 1",systemImage:"number"){counting=true}.accessibilityIdentifier("result.count")
                Button(e.excluded ? "恢复这个主体":"不是鸟 · 排除",systemImage:e.excluded ? "arrow.uturn.backward":"xmark.circle"){if let s=e.subject {model.edit{try $0.exclude(s,!e.excluded)}}}.accessibilityIdentifier("result.exclude")
            }.buttonStyle(.bordered).controlSize(.large)
            ViewThatFits(in:.horizontal) {HStack{actions};VStack(alignment:.leading){actions}}.font(.subheadline).disabled(e.subject == nil || model.busy)
            VStack(alignment:.leading,spacing:8) {
                Text("\(r.place?.label ?? "没有地点") · \(model.items.first{$0.id==r.id}?.day ?? "")").font(.subheadline)
                if let p=r.place {Text(p.sourceLabel).font(.caption).foregroundStyle(Palette.secondary)}
            }
            if let result=e.model {
                Button {place=true} label:{Text(result.priorUnknown == true ? "这个鸟种缺少当地资料，仅凭照片判断。" : r.place == nil ? "没有位置，只凭图像。":"已按拍摄地点和季节修正。") .font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("result.prior")}.buttonStyle(.plain).frame(minHeight:44).accessibilityHint("设置拍摄地点")
                // Geo-prior warning from the model; separate from the GBIF tier above.
                if result.rare {Label("地点模型：此地此季少见，请核对",systemImage:"exclamationmark.triangle").foregroundStyle(Palette.rust).font(.subheadline).accessibilityIdentifier("result.priorWarning")}
                if let reason=result.reason {Text(reason).font(.subheadline).foregroundStyle(Palette.rust).accessibilityIdentifier(reason.contains("此地此季") ? "result.priorWarning":"result.reason")}
            }
        }
        if let result=e.model {
            Divider()
            Text("按 GBIF 观测记录的当地当月份额分级；记录数不是实际种群数量。覆盖不足的地区显示数据不足。").font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("result.facts")
            Divider()
            // Owner rule: collapsed when the answer is settled (species, genus or a correction); open only for 不确定.
            let shown:Set<String>=e.state=="species" ? [e.key ?? ""] : e.state=="none" && result.level=="species" ? [result.top5.first?.scientific ?? ""] : []
            let others=Array(result.top5.enumerated()).filter{!shown.contains($0.element.scientific)}
            let open=candidatesOpen ?? (e.state=="uncertain" || (e.state=="none" && result.level=="uncertain"))
            VStack(alignment:.leading,spacing:4) {
                // The stable section id sits on the heading: a container id would overwrite result.candidate.N, and a container element swallows their taps.
                Text(e.state=="none" ? "其他可能":"模型原判断：\(title(result))").font(.headline).accessibilityIdentifier("result.candidates")
                Button {candidatesOpen = !open} label:{HStack{
                    Text(open ? "收起候选" : "\(others.count) 个候选 · 其余最高 \((others.map(\.element.p).max() ?? 0).formatted(.percent.precision(.fractionLength(0))))").font(.subheadline).foregroundStyle(Palette.secondary).monospacedDigit()
                    Spacer();Image(systemName:open ? "chevron.up":"chevron.down").font(.caption)
                }.frame(minHeight:44).contentShape(Rectangle())}.buttonStyle(.plain).accessibilityIdentifier("result.candidates.toggle").padding(.bottom,open ? 8:0)
                if open {ForEach(others,id:\.offset){i,c in
                        Button {candidate=CandidateSheet(value:c)} label:{HStack{
                            VStack(alignment:.leading,spacing:4){Text(model.catalogue.name(c.scientific));Text(c.scientific).font(.caption).italic().foregroundStyle(Palette.secondary);ProgressView(value:c.p).tint(Palette.green)}
                            Spacer();Text(c.p.formatted(.percent.precision(.fractionLength(1)))).font(.subheadline).monospacedDigit();Image(systemName:"chevron.right").font(.caption)
                        }.frame(minHeight:48)}.accessibilityIdentifier("result.candidate.\(i)").buttonStyle(.plain)
                        Divider()
                }}
            }
        }
    }
}
struct CandidateSheet: Identifiable {let id=UUID();let value:Candidate}

struct PlacePicker: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var onChoose:((Place)->Void)? = nil
    @State private var query=""
    var recent:[Place] {(UserDefaults.standard.data(forKey:"recentPlaceData").flatMap{try? JSONDecoder().decode([Place].self,from:$0)}) ?? []}
    func use(_ p:Place) {
        if let onChoose {onChoose(p)} else {model.chooseHome(p);Task{await model.setPlace(p)}}
        dismiss()
    }
    var body:some View {
        NavigationStack {
            // Native search field at the top: matching regions sit directly under it, above the keyboard, at any type size.
            List {
                if query.isEmpty {
                    Section {PlacePickerActions(initial:model.current?.place ?? model.homePlace,onChoose:use)}
                    if !recent.isEmpty {Section("最近地点") {ForEach(recent,id:\.stableCode) {p in Button(p.label){use(p)}.accessibilityIdentifier("place.recent."+p.stableCode).frame(minHeight:44)}}}
                }
                Section(query.isEmpty ? "离线选择国家或地区" : "匹配的地区") {
                    ForEach(Place.choices(query:query,recent:recent.map(\.label)),id:\.label) {p in
                        Button(p.label){use(p)}.accessibilityIdentifier("place.region."+p.stableCode).frame(minHeight:44)
                    }
                }
            }
            .searchable(text:$query,placement:.navigationBarDrawer(displayMode:.always),prompt:Text("搜索中文或英文地区"))
            .navigationTitle("拍摄地点").toolbar{Button("完成"){dismiss()}.accessibilityIdentifier("sheet.done")}
        }
    }
}
struct PlacePickerActions:View {
    @Environment(AppModel.self) var model
    var initial:Place?
    let onChoose:(Place)->Void
    @State private var map=false
    @State private var locating=false
    @State private var denied=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("定位用于判断附近当季的鸟；大致位置就够了，照片不会上传。地图搜索和浏览由 Apple 提供。").font(.footnote).foregroundStyle(Palette.secondary).accessibilityIdentifier("place.explanation")
            Button(locating ? "正在定位…":"用我现在的位置",systemImage:"location.fill") {Task {
                locating=true
                if let p=await model.location.request() {onChoose(p)} else {denied=true;map=true}
                locating=false
            }}.disabled(locating).accessibilityIdentifier("place.locate").frame(minHeight:44)
            if denied {Text("定位不可用，请在地图上选大致位置。").font(.footnote).accessibilityIdentifier("place.denied")}
            Button("在地图上选",systemImage:"map"){map=true}.accessibilityIdentifier("place.map").frame(minHeight:44)
        }.sheet(isPresented:$map){MapPlacePicker(initial:initial,onChoose:onChoose)}
    }
}
struct MapPlacePicker: View {
    @Environment(\.dismiss) var dismiss
    var initial:Place?
    let onChoose:(Place)->Void
    @State private var pin=CLLocationCoordinate2D(latitude:37.7749,longitude:-122.4194)
    @State private var tilesLoading=true
    @State private var query=""
    @State private var results=[MKMapItem]()
    @State private var label="地图选点"
    @State private var error=""
    @State private var search:MKLocalSearch?
    @State private var searching=false
    @FocusState private var searchFocused:Bool
    func find() async {
        searchFocused=false;searching=true;defer{searching=false}
        search?.cancel()
        let request=MKLocalSearch.Request();request.naturalLanguageQuery=query
        let job=MKLocalSearch(request:request);search=job
        do {results=try await job.start().mapItems;error=results.isEmpty ? "没有找到，试试离线地区列表。":""}
        catch {self.error="无法搜索，可移动地图选点或使用离线地区列表。"}
    }
    var body:some View {
        NavigationStack {
            VStack(spacing:12) {
                HStack {
                    TextField("搜索地点",text:$query,prompt:Text("Alaska、Bolsa Chica…").foregroundColor(Palette.secondary)).textFieldStyle(.roundedBorder).focused($searchFocused).submitLabel(.search).onSubmit{Task{await find()}}.accessibilityIdentifier("place.mapSearch")
                    Button("搜索"){Task{await find()}}.accessibilityIdentifier("place.mapFind")
                }.padding(.horizontal)
                if searching {ProgressView("正在搜索…")}
                if !error.isEmpty {Text(error).font(.footnote)}
                if !results.isEmpty {
                    ScrollView {VStack {ForEach(Array(results.enumerated()),id:\.offset) {i,item in
                        Button(item.name ?? "地点") {
                            pin=item.placemark.coordinate;label=item.name ?? query
                            results=[];searchFocused=false
                        }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).accessibilityIdentifier("place.mapResult.\(i)")
                    }}}.frame(maxHeight:160).padding(.horizontal)
                }
                Text("拖动地图或轻点放置图钉。圆圈约 25 公里，大致位置就够了。").font(.footnote).padding(.horizontal)
                PlaceMap(pin:$pin,label:$label,loading:$tilesLoading)
                    .accessibilityIdentifier("place.mapCanvas")
                    .overlay(alignment:.topTrailing){if tilesLoading {ProgressView("地图加载中").font(.caption).padding(8).background(Palette.paper,in:RoundedRectangle(cornerRadius:16)).padding(8)}}
                Text(String(format:"%.3f, %.3f",pin.latitude,pin.longitude)).font(.caption).monospacedDigit()
            }.navigationTitle("在地图上选").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge:.bottom) {
                Button("使用这个地点",systemImage:"checkmark") {
                    onChoose(Place(lat:pin.latitude,lon:pin.longitude,label:label+String(format:" · %.2f, %.2f",pin.latitude,pin.longitude),source:"map"));dismiss()
                }.frame(maxWidth:.infinity).buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("place.usePin").padding().background(Palette.paper)
            }
            .toolbar{Button("取消"){dismiss()}.accessibilityIdentifier("place.mapCancel")}
            .onAppear {
                if let initial {pin=CLLocationCoordinate2D(latitude:initial.lat,longitude:initial.lon);label=initial.label}

            }
        }
    }
}

/// Native delegate reports tile loading; SwiftUI Map has no tile-completion callback.
struct PlaceMap:UIViewRepresentable {
    @Binding var pin:CLLocationCoordinate2D
    @Binding var label:String
    @Binding var loading:Bool
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->MKMapView {
        let map=MKMapView();map.delegate=context.coordinator
        map.setRegion(MKCoordinateRegion(center:pin,latitudinalMeters:120000,longitudinalMeters:120000),animated:false)
        map.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:))))
        return map
    }
    func updateUIView(_ map:MKMapView,context:Context) {
        context.coordinator.parent=self
        if abs(map.centerCoordinate.latitude-pin.latitude)>0.0001 || abs(map.centerCoordinate.longitude-pin.longitude)>0.0001 {map.setCenter(pin,animated:false)}
        if let marker=map.annotations.first as? MKPointAnnotation {marker.coordinate=pin;marker.title=label}
        else {let marker=MKPointAnnotation();marker.coordinate=pin;marker.title=label;map.addAnnotation(marker)}
        if let circle=map.overlays.first as? MKCircle,abs(circle.coordinate.latitude-pin.latitude)<0.0001 && abs(circle.coordinate.longitude-pin.longitude)<0.0001 {return}
        map.removeOverlays(map.overlays);map.addOverlay(MKCircle(center:pin,radius:25000))
    }
    final class Coordinator:NSObject,MKMapViewDelegate {
        var parent:PlaceMap
        var movedByUser=false
        init(_ parent:PlaceMap){self.parent=parent}
        func mapViewWillStartLoadingMap(_ mapView:MKMapView){Task{@MainActor in parent.loading=true}}
        func mapViewDidFinishLoadingMap(_ mapView:MKMapView){Task{@MainActor in parent.loading=false}}
        func mapViewDidFailLoadingMap(_ mapView:MKMapView,withError error:Error){Task{@MainActor in parent.loading=false}}
        func mapView(_ mapView:MKMapView,regionWillChangeAnimated animated:Bool) {
            movedByUser=false
            for view in mapView.subviews {
                for gesture in view.gestureRecognizers ?? [] {
                    if gesture.state == .began || gesture.state == .changed {movedByUser=true}
                }
            }
        }
        func mapView(_ mapView:MKMapView,regionDidChangeAnimated animated:Bool) {
            guard movedByUser else{return}
            let center=mapView.centerCoordinate
            Task{@MainActor in
                if abs(center.latitude-parent.pin.latitude)>0.0001 || abs(center.longitude-parent.pin.longitude)>0.0001 {parent.label="地图选点";parent.pin=center}
            }
        }
        @objc func tap(_ gesture:UITapGestureRecognizer) {
            guard let map=gesture.view as? MKMapView else{return}
            parent.pin=map.convert(gesture.location(in:map),toCoordinateFrom:map);parent.label="地图选点"
        }
        func mapView(_ mapView:MKMapView,rendererFor overlay:MKOverlay)->MKOverlayRenderer {
            let renderer=MKCircleRenderer(overlay:overlay);renderer.fillColor=UIColor(Palette.green).withAlphaComponent(0.12);renderer.strokeColor=UIColor(Palette.green);renderer.lineWidth=2;return renderer
        }
    }
}
