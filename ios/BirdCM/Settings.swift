import SwiftUI
import UniformTypeIdentifiers

/// Settings gear sheet shared by all four tab roots (§6).
struct SettingsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var about = false
    @State private var diagnostics = false
    @State private var place = false
    @State private var clear = false
    var body: some View {
        let all = model.ledger.summary(nil)
        NavigationStack {
            List {
                Section("数据") {
                    NavigationLink("备份与恢复") { BackupView() }.accessibilityIdentifier("settings.backup")
                    LabeledContent("照片", value: "\(all.photos)")
                    LabeledContent("鸟种 · 观察记录", value: "\(all.species) · \(all.observations)")
                    LabeledContent("本机占用", value: ByteCountFormatter.string(fromByteCount: Int64(model.library?.storageBytes() ?? 0), countStyle: .file))
                }
                Section("地点") {
                    Button { place = true } label: { LabeledContent("默认地点", value: model.homePlace?.label ?? String(localized: "未设置")) }.accessibilityIdentifier("settings.place")
                }
                Section("关于") {
                    Button("关于与数据来源") { about = true }.accessibilityIdentifier("home.about")
                    #if DEBUG
                    Button("诊断") { diagnostics = true }.accessibilityIdentifier("home.diagnostics")
                    #endif
                }
                Section {
                    Button("清空本机记录", role: .destructive) { clear = true }.accessibilityIdentifier("history.clear").disabled(model.items.isEmpty)
                } footer: { Text("清空前可以先在“备份与恢复”导出一份备份。") }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("settings.done") } }
            .sheet(isPresented: $about) { AboutView() }
            .sheet(isPresented: $diagnostics) { DiagnosticsView() }
            .sheet(isPresented: $place) { PlacePicker(onChoose: { p in model.chooseHome(p) }) }
            .confirmationDialog("清空本机 \(all.photos) 张照片、\(all.observations) 条观察记录？", isPresented: $clear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { model.edit { try $0.deleteAll() } }.accessibilityIdentifier("history.confirmClear")
                Button("取消", role: .cancel) {}
            } message: { Text("记录从观羽中移除，无法在应用里撤销；相册或文件里的原图不受影响。建议先导出备份。") }
        }
    }
}

/// Manual single-file backup through Files; a user-granted document, not an iCloud capability (§2).
struct BackupView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    struct Staged: Identifiable { let id = UUID(); let url: URL; let info: Library.ArchiveInfo }
    struct Exported: Identifiable { let id = UUID(); let url: URL }
    @State private var exported: Exported?
    @State private var importing = false
    @State private var working = ""
    @State private var staged: Staged?
    @State private var confirmRestore = false
    @State private var message = ""
    func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    var body: some View {
        List {
            Section {
                Text("备份是一个 .birdcm 文件，含全部原图、识别结果、更正、日期与地点，未加密。只保存到你信任的位置，如“我的 iPhone”或 iCloud 云盘。").font(.footnote).foregroundStyle(Palette.secondary)
                LabeledContent("照片", value: "\(model.ledger.summary(nil).photos)")
                LabeledContent("本机占用", value: bytes(model.library?.storageBytes() ?? 0))
                Button("导出备份…", systemImage: "square.and.arrow.up") { Task { await export() } }.accessibilityIdentifier("backup.export").frame(minHeight: 44)
                Button("从备份导入…", systemImage: "square.and.arrow.down") { importing = true }.accessibilityIdentifier("backup.import").frame(minHeight: 44)
                #if DEBUG
                Button("导出后直接预览（测试）") { Task { await export(stageOnly: true) } }.accessibilityIdentifier("backup.selfTest").frame(minHeight: 44)
                #endif
                if !working.isEmpty { ProgressView(working) }
                if !message.isEmpty { Text(message).accessibilityIdentifier("backup.message") }
            }.disabled(!working.isEmpty)
            if let s = staged {
                Section("备份内容") {
                    LabeledContent("创建时间", value: String(s.info.created.prefix(19)).replacingOccurrences(of: "T", with: " ") + " UTC")
                    LabeledContent("有效照片记录", value: "\(s.info.records)")
                    LabeledContent("原图", value: "\(s.info.photos) · \(bytes(s.info.bytes))")
                    Text("合并：本机记录和更正全部保留，只加入本机没有的记录；同一张照片只统计一次。").font(.footnote)
                    Button("合并到本机") { Task { await apply(s, restore: false) } }.accessibilityIdentifier("backup.merge").frame(minHeight: 44)
                    Button("用备份替换本机记录…", role: .destructive) { confirmRestore = true }.accessibilityIdentifier("backup.restore").frame(minHeight: 44)
                }.disabled(!working.isEmpty)
            }
            let issues = model.library?.issues() ?? []
            if !issues.isEmpty {
                Section("待修复的旧记录 · \(issues.count)") {
                    Text("这些旧文件无法读取，已原样保存在记录库里，也随备份导出；修复前不计入统计。").font(.footnote)
                    ForEach(issues, id: \.0) { Text($0.0).font(.caption.monospaced()); Text($0.1).font(.caption2).foregroundStyle(Palette.secondary) }
                }
            }
        }
        .navigationTitle("备份与恢复")
        .sheet(item: $exported) { f in
            DocumentExporter(url: f.url) { ok in
                message = ok ? String(localized: "备份文件已写入；云端上传由文件提供方处理。") : String(localized: "已取消，未写入。")
                try? FileManager.default.removeItem(at: f.url); exported = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in Task { await stage(result) } }
        .confirmationDialog("用备份替换本机全部记录？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("先保存安全备份，再替换", role: .destructive) { if let s = staged { Task { await apply(s, restore: true) } } }.accessibilityIdentifier("backup.confirmRestore")
            Button("取消", role: .cancel) {}
        } message: { Text("本机 \(model.ledger.summary(nil).photos) 张照片的记录会被备份内容取代。替换前自动在本机保存一份安全备份。") }
    }
    func export(stageOnly: Bool = false) async {
        guard let library = model.library else { return }
        working = String(localized: "正在导出并校验…"); defer { working = "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BirdBackups")
        let url = dir.appendingPathComponent("BirdCM-\(f.string(from: Date()))-\(UUID().uuidString.lowercased()).birdcm")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await Task.detached { try library.export(to: url) }.value
            if stageOnly { staged = Staged(url: url, info: try Library.inspect(url)) } else { exported = Exported(url: url) }
        } catch { model.error = String(localized: "导出失败：\(error.localizedDescription)。本机记录未改动。") }
    }
    func stage(_ result: Result<URL, Error>) async {
        do {
            let picked = try result.get()
            // Copy into the sandbox while the provider grants access, then release; never read a live provider URL.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("BirdImports/\(UUID().uuidString).birdcm")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: picked, to: copy)
            working = String(localized: "正在校验备份…"); defer { working = "" }
            staged = Staged(url: copy, info: try await Task.detached { try Library.inspect(copy) }.value)
        } catch { message = String(localized: "无法使用这个文件：\(error.localizedDescription)。本机记录未改动。") }
    }
    func apply(_ s: Staged, restore: Bool) async {
        guard let library = model.library else { return }
        working = restore ? String(localized: "正在保存安全备份并替换…") : String(localized: "正在合并…"); defer { working = "" }
        do {
            let added = try await Task.detached { try library.importArchive(s.url, restore: restore) }.value
            model.refresh(); staged = nil
            message = restore ? String(localized: "已用备份替换，共 \(added) 条记录。替换前的本机记录已另存为安全备份。") : String(localized: "已合并，新增 \(added) 条记录。")
        } catch { message = String(localized: "导入失败：\(error.localizedDescription)。本机记录未改动。") }
    }
}

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let done: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forExporting: [url], asCopy: true); c.delegate = context.coordinator; return c
    }
    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (Bool) -> Void
        init(_ done: @escaping (Bool) -> Void) { self.done = done }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(true) }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { done(false) }
    }
}
