import SwiftUI
struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {NavigationStack{ScrollView{VStack(alignment:.leading,spacing:20){
        Text("观羽 · BirdCM").font(.largeTitle.bold())
        Text("开源代码 MIT。识别离线运行，照片与历史仅保存在设备。系统 PhotosPicker 无需授予整个相册权限。所有模型随安装包提供；只有 Apple 地图搜索和瓦片联网；不向我们上传照片、坐标或结果。Apple 获取地图浏览区域以提供瓦片。")
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
    var body: some View {NavigationStack{List{
        Section("本次运行 · 性能诊断") {
            LabeledContent("允许计算单元",value:Diagnostics.compute)
            LabeledContent("地点模型实际计算",value:"CPU · Accelerate")
            Text("配置不代表实际算子使用了 ANE/GPU。模拟器数据不能推断真机性能。") .font(.caption)
            LabeledContent("加载采样峰值",value:String(format:"%.1f MB",Double(model.engine?.loadPeakBytes ?? 0)/1e6))
            LabeledContent("模型加载",value:String(format:"%.3f s",model.loadSeconds))
            LabeledContent("选片到结果（含定位）",value:String(format:"%.3f s",model.sessionSeconds))
            if let d=model.current?.result?.diagnostics {
                ForEach(d.stages.keys.sorted(),id:\.self){key in LabeledContent(key,value:String(format:"%.3f s",d.stages[key]!))}
                LabeledContent("采样峰值内存",value:String(format:"%.1f MB",Double(d.peakBytes)/1e6))
                Text("每 20 ms 采样 phys_footprint；可能漏掉瞬时峰值。已有历史里的指标来自识别当时。") .font(.caption)
            }
        }
        #if DEBUG
        Section("验收夹具 · 仅 Debug") {
            if UserDefaults.standard.string(forKey:"fixtureImage") != nil {
                Button("载入 CC0 验收照片") {dismiss();model.settings=false;Task{await model.pickFixture()}}.accessibilityIdentifier("diagnostics.fixture")
            }
        }
        #endif
        Section("真机验收") {Text("测冷/热启动、每图耗时、峰值内存、连续 50 张、断网、相册/定位权限与 HEIC，并在完整评测集上测准确率。启动参数 -computeUnits all / cpuAndGPU / cpuAndNeuralEngine / cpuOnly。")}
    }.navigationTitle("诊断") .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}.accessibilityIdentifier("sheet.done")}}}}
}
