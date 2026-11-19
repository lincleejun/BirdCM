import SwiftUI
struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {NavigationStack{ScrollView{VStack(alignment:.leading,spacing:20){
        Text("观羽 · BirdCM").font(.largeTitle.bold())
        Text("开源代码 MIT。识别离线运行，照片与历史仅保存在设备。系统 PhotosPicker 无需授予整个相册权限。所有模型随安装包提供；只有 Apple 地图搜索、瓦片和地名（开启“用网络显示地名”时只发送坐标）联网；不向我们上传照片、坐标或结果。Apple 获取地图浏览区域以提供瓦片。")
        Link("github.com/lincleejun/BirdCM",destination:URL(string:"https://github.com/lincleejun/BirdCM")!)
        Text("眼嘴与飞行模型仅限非商业用途。BioCLIP 2.5：MIT；D-FINE nano：Apache-2.0；AviList v2026：CC BY 4.0；文本向量：CC0。")
        Text("中文鸟名：Gill F, D Donsker & P Rasmussen (Eds). 2026. IOC World Bird List v15.2. doi:10.14344/IOC.ML.15.2，CC BY 3.0。多语言表编纂 Peter Kovalik；中文来源与逐行归属见下方完整声明。少数 Wikidata 名称 CC0。")
        Text("GBIF.org (17 November 2026) GBIF Occurrence Download / search API。观测记录数不是鸟的实际数量。IUCN (2026). The IUCN Red List of Threatened Species. Version 2026-1. doi:10.15468/0qnb58。IUCN 再分发条款尚不明确；构建时 BIRDCM_BUNDLE_IUCN=0 可移除等级数据。")
        Text("BirdNET+ Geomodel v3.0.4：直接使用官方发布的模型。geomodel 仓库 LICENSE-MODELS.md 写 Apache-2.0，但 birdnet pip README 写 CC BY-NC-SA 4.0，两者冲突，需由所有者决定依据哪项声明。请引用 BirdNET。")
        Text("Clear 门控：CC BY / CC0 训练照片；不含非商用限制，完整训练照片署名与许可说明随 App 提供。")
        NavigationLink("完整模型与数据声明"){ResourceText(name:"NOTICE",ext:"md")}.accessibilityIdentifier("about.licences")
        NavigationLink("Clear 权重许可"){ResourceText(name:"CLEAR-WEIGHTS-LICENSE",ext:"md")}
        NavigationLink("Clear 训练照片署名"){ResourceText(name:"clear-training-photos",ext:"csv")}
    }.padding(24)}.navigationTitle("关于") .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}.accessibilityIdentifier("sheet.done")}}}}
}
struct ResourceText: View {
    @Environment(\.dismiss) var dismiss
    let name:String,ext:String
    var body:some View {ScrollView{Text((Bundle.main.url(forResource:name,withExtension:ext).flatMap{try? String(contentsOf:$0,encoding:.utf8)}) ?? "资源未找到").font(.caption).textSelection(.enabled).padding()}.navigationTitle(name).navigationBarBackButtonHidden().toolbar{ToolbarItem(placement:.topBarLeading){Button("返回"){dismiss()}.accessibilityIdentifier("resource.back")}}}
}
struct DiagnosticsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var verifying = false
    @State private var verified: String?
    var body: some View {NavigationStack{List{
        let marks = Perf.marks
        let seconds = { (key: String) in marks[key].map { String(format: "%.2f s", $0) } ?? "—" }
        #if DEBUG
        // First, so UI flows reach it without scrolling past the timings.
        if UserDefaults.standard.string(forKey:"fixtureImage") != nil {
            Section("验收夹具 · 仅 Debug") {
                Button("载入 CC0 验收照片") {dismiss();model.tab = .identify;Task{await model.pickFixture()}}.accessibilityIdentifier("diagnostics.fixture")
            }
        }
        #endif
        Section("本次启动 · 从进程启动算起") {
            LabeledContent("首页可操作", value: seconds("home.interactive"))
            LabeledContent("可以开始找鸟（名录 + 检测）", value: seconds("models.detector"))
            LabeledContent("全部模型就绪", value: seconds("models.ready"))
            LabeledContent("预热完成", value: seconds("models.warm"))
            LabeledContent("预热用时", value: seconds("models.warmup"))
            ForEach([("完整性 · SHA-256", "models.integrity.sha256"), ("完整性 · 只查大小", "models.integrity.sizes"), ("名录", "load.names"), ("检测模型", "load.detector"), ("BioCLIP", "load.bioclip"), ("眼嘴与飞行", "load.heads"), ("地点模型", "load.geo"), ("稀有度表", "load.rarity"), ("等待模型（选片早于就绪）", "identify.waitedForModels")], id: \.1) { title, key in
                if marks[key] != nil { LabeledContent(title, value: seconds(key)) }
            }
            let freed = UserDefaults.standard.object(forKey: "legacyModelsFreed") as? Int64 ?? 0
            if freed > 0 { LabeledContent("已删除早期版本下载的模型", value: ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)).accessibilityIdentifier("diagnostics.legacyFreed") }
            Text("首次安装或升级后完整计算一次 SHA-256，之后只核对文件大小（App 包有系统代码签名保护）。").font(.caption)
            Button(verifying ? "正在完整校验…" : "完整校验") {
                verifying = true
                Task {
                    let t = Date()
                    let r = try? await Task.detached { try Models.check(full: true) }.value
                    verified = r.map { $0.invalid.isEmpty ? String(format: "全部文件完好（%.1f s）", Date().timeIntervalSince(t)) : "损坏：" + $0.invalid.joined(separator: "、") } ?? "无法读取模型文件"
                    verifying = false
                }
            }.disabled(verifying).accessibilityIdentifier("diagnostics.verify")
            if let verified { Text(verified).font(.footnote).accessibilityIdentifier("diagnostics.verified") }
        }
        Section("本次运行 · 性能诊断") {
            LabeledContent("允许计算单元",value:Diagnostics.compute)
            LabeledContent("地点模型实际计算",value:"CPU · Accelerate")
            Text("配置不代表实际算子使用了 ANE/GPU。模拟器数据不能推断真机性能。") .font(.caption)
            LabeledContent("加载采样峰值",value:String(format:"%.1f MB",Double(model.engine?.loadPeakBytes ?? 0)/1e6))
            LabeledContent("选片到结果（含定位与等待模型）",value:String(format:"%.3f s",model.sessionSeconds))
            if let d=model.current?.result?.diagnostics {
                ForEach(d.stages.keys.sorted(),id:\.self){key in LabeledContent(key,value:String(format:"%.3f s",d.stages[key]!))}
                LabeledContent("采样峰值内存",value:String(format:"%.1f MB",Double(d.peakBytes)/1e6))
                Text("每 20 ms 采样 phys_footprint；可能漏掉瞬时峰值。已有历史里的指标来自识别当时。") .font(.caption)
            }
        }
        Section {
            NavigationLink("性能自测") { SelfTestView() }.accessibilityIdentifier("diagnostics.selfTest")
            ForEach(Diagnostics.models, id: \.self) { m in ComputePicker(model: m) }
        } header: { Text("计算单元") } footer: { Text("每个模型可单独选择；重新打开 App 后生效。先用“性能自测”比较各设置。模拟器始终只用 CPU。") }
        Section("真机验收") {Text("测冷/热启动、每图耗时、峰值内存、连续 50 张、断网、相册/定位权限与 HEIC，并在完整评测集上测准确率。启动参数 -computeUnits all / cpuAndGPU / cpuAndNeuralEngine / cpuOnly。")}
    }.navigationTitle("诊断") .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}.accessibilityIdentifier("sheet.done")}}}}
}

/// 诊断: one model's compute units (Diagnostics.unitName), stored per model; the engine reads it when it loads the model.
struct ComputePicker: View {
    let model: String
    @State private var value = ""
    var body: some View {
        Picker(SelfTestView.shortModels[model] ?? model, selection: $value) {
            ForEach(Diagnostics.unitNames, id: \.self) { Text(SelfTestView.shortUnits[$0] ?? $0).tag($0) }
        }
        .onAppear { value = Diagnostics.unitName(model) }
        .onChange(of: value) { _, v in if v != Diagnostics.unitName(model) { UserDefaults.standard.set(v, forKey: "computeUnits." + model) } }
        .accessibilityIdentifier("diagnostics.units." + model)
    }
}
