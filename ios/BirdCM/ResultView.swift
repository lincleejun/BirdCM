import PhotosUI
import SwiftUI
import MapKit
import CoreLocation

struct ResultView: View {
    @Environment(AppModel.self) var model
    @State private var marks=true
    @State private var draw=false
    @State private var place=false
    @State private var pick: PhotosPickerItem?
    @State private var candidate: CandidateSheet?
    var body: some View {
        if let r=model.current {
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
                            Text("在照片上拖出包含鸟的矩形。").foregroundStyle(Palette.rust)
                            Button("用整张照片识别") {draw=false;Task{await model.analyze(index:0,box:[0,0,1,1],manual:true,newBox:true,place:r.place)}}.accessibilityIdentifier("result.wholePhoto").frame(minHeight:44)
                        }
                        if let result=r.result { identification(result) }
                        else {
                            Text("没找到鸟").font(.largeTitle.bold())
                            Text("在照片上画框，或使用整张照片重试。").foregroundStyle(Palette.secondary)
                            Button("用整张照片识别") {Task{await model.analyze(index:0,box:[0,0,1,1],manual:true,newBox:true,place:r.place)}}.accessibilityIdentifier("result.wholePhoto").buttonStyle(.borderedProminent).frame(minHeight:44)
                        }
                        Divider()
                        VStack(alignment:.leading,spacing:14) {
                            Text("拍摄信息").font(.headline).accessibilityIdentifier("result.shooting")
                            ForEach(["相机","镜头","焦距","光圈","快门","ISO","曝光补偿"],id:\.self) { key in
                                if let value=r.shooting.fields[key] { LabeledContent(LocalizedStringKey(key)){Text(value).monospacedDigit().fixedSize(horizontal:false,vertical:true)} }
                            }
                            LabeledContent("拍摄时间"){Text(r.shooting.takenAt?.replacingOccurrences(of:"T",with:" ") ?? "未知").monospacedDigit()}
                        }.font(.subheadline).fixedSize(horizontal:false,vertical:true)
                        Divider()
                        VStack(alignment:.leading,spacing:12) {
                            Text("拍摄地点").font(.headline).accessibilityIdentifier("result.place")
                            if let p=r.place {
                                Text(p.label)
                                Text(p.sourceLabel).font(.caption).foregroundStyle(Palette.secondary)
                                Map(initialPosition:.region(MKCoordinateRegion(center:CLLocationCoordinate2D(latitude:p.lat,longitude:p.lon),latitudinalMeters:100000,longitudinalMeters:100000))) {Marker(p.label,coordinate:CLLocationCoordinate2D(latitude:p.lat,longitude:p.lon))}.id("\(p.lat),\(p.lon)").frame(height:140).allowsHitTesting(false).accessibilityLabel("识别使用的地点地图")
                            } else {Text("没有地点，当前仅按图像识别。") .foregroundStyle(Palette.secondary)}

                        }
                        Text("照片和识别历史仅保存在此设备。").font(.caption).foregroundStyle(Palette.secondary)
                    }.fixedSize(horizontal:false,vertical:true).padding(20)
                }.padding(.bottom,24)
            }
            .background(Palette.surface)
            .navigationTitle("识别结果").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.topBarTrailing){Menu {
                Button("删除这条记录",role:.destructive){model.delete(r)}
            } label:{Image(systemName:"ellipsis").frame(width:44,height:44).accessibilityLabel("结果操作")}}}
            .safeAreaInset(edge:.bottom) {
                HStack(spacing:16) {
                    PhotosPicker(selection:$pick,matching:.images,preferredItemEncoding:.current){Label("再选一张",systemImage:"photo.on.rectangle").frame(maxWidth:.infinity,minHeight:54)}.buttonStyle(PrimaryActionStyle()).accessibilityIdentifier("result.photos")
                    Button("改地点",systemImage:"mappin.and.ellipse"){place=true}.accessibilityIdentifier("result.bottomPlace").frame(minHeight:44)
                    Button("删除",systemImage:"trash",role:.destructive){model.delete(r)}.labelStyle(.iconOnly).accessibilityIdentifier("result.delete").frame(minWidth:44,minHeight:44)
                }.font(.subheadline).padding().background(Palette.paper).disabled(model.busy)
            }
            .sheet(isPresented:$place){PlacePicker()}
            .sheet(item:$candidate){c in
                NavigationStack{ScrollView{VStack(alignment:.leading,spacing:16){
                    Text(c.value.chinese.isEmpty ? "中文名未知":c.value.chinese).font(.title)
                    Text(c.value.english);Text(c.value.scientific).italic()
                    Text("候选把握 \(c.value.p.formatted(.percent.precision(.fractionLength(1))))")
                    let rarity=model.engine?.rarity?.lookup(c.value.scientific,place:r.place,month:r.shooting.month)
                    Text("当地当月：\(rarity?.label ?? "数据不足")")
                    Text("IUCN：\(Rarity.iucnLabel(rarity?.iucn))")
                    Text("候选并非已确认鉴定。当地频次来自观测记录，不代表实际种群数量。").foregroundStyle(Palette.secondary)
                }.fixedSize(horizontal:false,vertical:true).padding().accessibilityIdentifier("candidate.details")}.toolbar{Button("完成"){candidate=nil}.accessibilityIdentifier("candidate.done")}}.presentationDetents([.medium,.large])
            }
            .onChange(of:pick) { Task {
                guard let pick else{return}
                do{if let data=try await pick.loadTransferable(type:Data.self){await model.receive(data)}}catch{model.error=error.localizedDescription}
                self.pick=nil
            } }
            .overlay {if model.busy{IdentifyingView()}}
        }
    }
    @ViewBuilder func factChips(_ result:Identification) -> some View {
        if result.flying ?? 0 >= 0.5 {Label("在飞",systemImage:"bird.fill").font(.subheadline).padding(8).background(Palette.paper,in:Capsule())}
        let label=result.rarity?.label ?? "数据不足"
        let rarity=ThemeContrast.rarity[label] ?? (0x000000,0xdddddd)
        Text("本地 · "+label).font(.subheadline).foregroundStyle(Palette.adaptive(rarity.0,rarity.0)).padding(8).background(Palette.adaptive(rarity.1,rarity.1),in:Capsule())
        if let code=result.rarity?.iucn {
            let colors=ThemeContrast.iucn[code] ?? (0x000000,0xdddddd)
            Text("IUCN · "+Rarity.iucnLabel(code)).font(.subheadline.bold()).foregroundStyle(Palette.adaptive(colors.0,colors.0)).padding(8).background(Palette.adaptive(colors.1,colors.1),in:Capsule())
        }
        if result.level != "species" || result.reason != nil {Text("近似种请核对").font(.subheadline).foregroundStyle(Palette.rust)}
        if result.rare {Label("可能稀有 · 请核对",systemImage:"exclamationmark.triangle").font(.subheadline).foregroundStyle(Palette.rust)}
    }
    @ViewBuilder func identification(_ result: Identification) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title(result)).accessibilityIdentifier("result.name").accessibilityValue(result.level).font(.largeTitle.bold()).foregroundStyle(result.level=="uncertain" ? Palette.rust:Palette.ink).accessibilityAddTraits(.isHeader)
            if result.level=="species",let c=result.top5.first {
                Text(c.english).font(.title3)
                Text(c.scientific).italic().foregroundStyle(Palette.secondary)
                ViewThatFits(in:.horizontal) {
                HStack {factChips(result)}
                VStack(alignment:.leading) {factChips(result)}
            }
                ProgressView(value:c.p).tint(Palette.green)
                Text("把握 \(c.p.formatted(.percent.precision(.fractionLength(1))))").font(.subheadline).monospacedDigit()
            } else if result.level=="genus" {Text("可以判断到属，具体鸟种不确定。属级把握 \((result.genusP ?? 0).formatted(.percent.precision(.fractionLength(1))))")}
            else {Text("还不能确定是哪种鸟，看看这些可能。")}
            if result.level != "species" {ViewThatFits(in:.horizontal){HStack{factChips(result)};VStack(alignment:.leading){factChips(result)}}}
            if let r=model.current {
                VStack(alignment:.leading,spacing:8) {
                    Text("\(r.place?.label ?? "没有地点") · \(r.shooting.takenAt.map{String($0.prefix(10))} ?? "照片没有拍摄日期，按全年估计")").font(.subheadline)
                    if let p=r.place {Text(p.sourceLabel).font(.caption).foregroundStyle(Palette.secondary)}

                }
            }
            Button {place=true} label:{Text(result.priorUnknown == true ? "这个鸟种缺少当地资料，仅凭照片判断。" : model.current?.place == nil ? "没有位置，只凭图像。":"已按拍摄地点和季节修正。") .font(.caption).foregroundStyle(Palette.secondary).accessibilityIdentifier("result.prior")}.buttonStyle(.plain).frame(minHeight:44).accessibilityHint("设置拍摄地点")
            if result.rare {Text("本地少见 · 请核对").foregroundStyle(Palette.rust).font(.headline)}
            if let reason=result.reason{Text(reason).font(.subheadline).foregroundStyle(Palette.rust)}
        }
        Divider()
        VStack(spacing:16) {
            if result.clear == false {Text("鸟的特征不够清楚，请核对下面的候选。").foregroundStyle(Palette.rust)}

            Text("按 GBIF 观测记录的当地当月份额分级；记录数不是实际种群数量。覆盖不足的地区显示数据不足。") .font(.caption).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity,alignment:.leading)

        }.font(.subheadline).accessibilityIdentifier("result.facts")
        Divider()
        VStack(alignment:.leading,spacing:4) {
            Text("其他可能").accessibilityIdentifier("result.candidates").font(.headline).padding(.bottom,8)
            ForEach(Array(result.top5.enumerated()),id:\.offset){i,c in
                if result.level != "species" || i>0 {
                    Button {candidate=CandidateSheet(value:c)} label:{HStack{
                        VStack(alignment:.leading,spacing:4){Text(c.chinese.isEmpty ? c.english:c.chinese);Text(c.scientific).font(.caption).italic().foregroundStyle(Palette.secondary);ProgressView(value:c.p).tint(Palette.green)}
                        Spacer();Text(c.p.formatted(.percent.precision(.fractionLength(1)))).font(.subheadline).monospacedDigit();Image(systemName:"chevron.right").font(.caption)
                    }.frame(minHeight:48)}.accessibilityIdentifier("result.candidate.\(i)").buttonStyle(.plain)
                    Divider()
                }
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
            List {
                Section {PlacePickerActions(initial:model.current?.place ?? model.homePlace,onChoose:use)}
                if !recent.isEmpty {Section("最近地点") {ForEach(recent,id:\.stableCode) {p in Button(p.label){use(p)}.accessibilityIdentifier("place.recent."+p.stableCode)}}}
                Section("离线选择国家或地区") {
                    TextField("搜索中文或英文地区",text:$query,prompt:Text("搜索中文或英文地区").foregroundColor(Palette.secondary)).accessibilityIdentifier("place.search")
                    ForEach(Place.choices(query:query,recent:recent.map(\.label)),id:\.label) {p in
                        Button(p.label){use(p)}.accessibilityIdentifier("place.region."+p.stableCode)
                    }
                }
            }.navigationTitle("拍摄地点").toolbar{Button("完成"){dismiss()}.accessibilityIdentifier("sheet.done")}
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
