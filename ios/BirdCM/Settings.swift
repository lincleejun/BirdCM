import SwiftUI
import UniformTypeIdentifiers

/// 设置: the fifth tab root (owner 2026-11-18), replacing the gear sheet that sat on every tab.
struct SettingsView: View {
    @Environment(AppModel.self) var model
    @State private var about = false
    @State private var diagnostics = false
    @State private var place = false
    @State private var clear = false
    @State private var cleanup = false
    @AppStorage("placeNamesOnline") private var placeNamesOnline = true
    /// Directory size and the legacy-copy scan read every file: computed off the main actor, not in `body`.
    @State private var disk: (storage: Int, redundant: [URL], redundantBytes: Int)?
    func scanDisk() async {
        guard let library = model.library else { return }
        disk = await Task.detached {
            let redundant = library.redundantLegacyFiles()
            return (library.storageBytes(), redundant, redundant.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +))
        }.value
    }
    var body: some View {
        let all = model.ledger.summary(nil)
        List {
            Section("数据") {
                NavigationLink("备份与恢复") { BackupView() }.accessibilityIdentifier("settings.backup")
                LabeledContent("照片", value: "\(all.photos)")
                LabeledContent("鸟种 · 观察记录", value: "\(all.species) · \(all.observations)")
                LabeledContent("本机占用", value: disk.map { ByteCountFormatter.string(fromByteCount: Int64($0.storage), countStyle: .file) } ?? "…")
                if let disk, !disk.redundant.isEmpty {
                    Button("清理旧版本副本（\(disk.redundant.count) 个，\(ByteCountFormatter.string(fromByteCount: Int64(disk.redundantBytes), countStyle: .file))）") { cleanup = true }.accessibilityIdentifier("settings.cleanup")
                }
            }
            Section {
                Button { place = true } label: { LabeledContent("默认地点", value: model.placeName(model.homePlace) ?? String(localized: "未设置")) }.accessibilityIdentifier("settings.place")
                Toggle("用网络显示地名", isOn: $placeNamesOnline).accessibilityIdentifier("settings.placeNames")
            } header: { Text("地点") } footer: {
                Text("开启时只把坐标发给 Apple 换取英文地名（约 1 公里精度，存在本机）；关闭后显示离线的国家 · 州/省。")
            }
            Section {
                Button("关于与数据来源") { about = true }.accessibilityIdentifier("home.about")
                Button("诊断") { diagnostics = true }.accessibilityIdentifier("home.diagnostics")
            } header: { Text("关于") } footer: { Text("系统选片无需相册访问授权；仅读取你选择的照片。") }
            ReferenceSettingsSection()
            Section {
                Button("清空本机记录", role: .destructive) { clear = true }.accessibilityIdentifier("history.clear").disabled(model.items.isEmpty)
            } footer: { Text("清空前可以先在“备份与恢复”导出一份备份。") }
        }
        .scrollContentBackground(.hidden).background(Palette.paper)
        .navigationTitle("设置")
        .task(id: model.items.count) { await scanDisk() }
        .sheet(isPresented: $about) { AboutView().debugAppearance() }
        .sheet(isPresented: $diagnostics) { DiagnosticsView().debugAppearance() }
        .sheet(isPresented: $place) { PlacePicker(onChoose: { p in model.chooseHome(p) }).debugAppearance() }
        .confirmationDialog("删除旧版本的 JSON 副本？", isPresented: $cleanup, titleVisibility: .visible) {
            Button("删除副本", role: .destructive) {
                for u in disk?.redundant ?? [] { try? FileManager.default.removeItem(at: u) }
                model.refresh(); Task { await scanDisk() }
            }.accessibilityIdentifier("settings.confirmCleanup")
            Button("取消", role: .cancel) {}
        } message: { Text("这些是升级前每条记录的 JSON 文件，内容已逐字节保存在记录库里（也会随备份导出）。不删除任何原图。") }
        .confirmationDialog("清空本机 \(all.photos) 张照片、\(all.observations) 条观察记录？", isPresented: $clear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.edit { try $0.deleteAll() } }.accessibilityIdentifier("history.confirmClear")
            Button("取消", role: .cancel) {}
        } message: { Text("记录从观羽中移除，无法在应用里撤销；相册或文件里的原图不受影响。建议先导出备份。") }
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
    @State private var storage: Int?
    func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    var body: some View {
        List {
            Section {
                Text("备份是一个 .birdcm 文件，含全部原图、识别结果、更正、日期与地点，未加密。只保存到你信任的位置，如“我的 iPhone”或 iCloud 云盘。").font(.footnote).foregroundStyle(Palette.secondary)
                LabeledContent("照片", value: "\(model.ledger.summary(nil).photos)")
                LabeledContent("本机占用", value: storage.map(bytes) ?? "…")
                Button("导出备份…", systemImage: "square.and.arrow.up") { Task { await export() } }.accessibilityIdentifier("backup.export").frame(minHeight: 44)
                Button("从备份导入…", systemImage: "square.and.arrow.down") { importing = true }.accessibilityIdentifier("backup.import").frame(minHeight: 44)
                #if DEBUG
                Button("导出后直接预览（测试）") { Task { await export(stageOnly: true) } }.accessibilityIdentifier("backup.selfTest").frame(minHeight: 44)
                #endif
                if !working.isEmpty { ProgressView(working) }
                if !message.isEmpty { Text(message).accessibilityIdentifier("backup.message") }
            }.disabled(!working.isEmpty || model.migration != nil)
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
            FolderBackupSection(storage: storage)
            let issues = model.library?.issues() ?? []
            if !issues.isEmpty {
                Section {
                    Text("这些旧文件无法读取，已原样保存在记录库里，也随备份导出；修复前不计入统计。").font(.footnote)
                    ForEach(issues, id: \.0) { Text($0.0).font(.caption.monospaced()); Text($0.1).font(.caption2).foregroundStyle(Palette.secondary) }
                } header: { Text("待修复的旧记录 · \(issues.count)").accessibilityIdentifier("backup.issues") }
            }
        }
        .navigationTitle("备份与恢复")
        .task(id: model.items.count) { if let library = model.library { storage = await Task.detached { library.storageBytes() }.value } }
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

/// §2 opt-in foreground folder backup: user-chosen folder (minimal security-scoped bookmark), runs when the app comes to the
/// foreground if records changed and the last success is ≥24 h old, or on demand. Keeps the last three verified files this
/// installation wrote there; never touches other files. No background task, no claim about cloud upload.
@MainActor @Observable final class FolderBackup {
    static let shared = FolderBackup()
    private let d = UserDefaults.standard
    var running = false
    var lastError: String? { didSet { d.set(lastError, forKey: "backupFolderError") } }
    var folderName: String? { d.string(forKey: "backupFolderName") }
    var lastSuccess: Date? { d.object(forKey: "backupFolderLast") as? Date }
    var lastFile: String? { (d.stringArray(forKey: "backupFolderOwn") ?? []).last }
    init() { lastError = d.string(forKey: "backupFolderError") }
    var enabled: Bool { d.data(forKey: "backupFolderBookmark") != nil || fixture != nil }
    private var fixture: String? {
        #if DEBUG
        return d.string(forKey: "backupFolderFixture")
        #else
        return nil
        #endif
    }
    func choose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            d.set(try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "backupFolderBookmark")
            d.set(url.lastPathComponent, forKey: "backupFolderName"); d.removeObject(forKey: "backupFolderOwn"); d.removeObject(forKey: "backupFolderLast"); lastError = nil
        } catch { lastError = String(localized: "无法记住这个文件夹：\(error.localizedDescription)") }
    }
    func stop() { for k in ["backupFolderBookmark", "backupFolderName", "backupFolderOwn", "backupFolderLast", "backupFolderRevision", "backupFolderFixture"] { d.removeObject(forKey: k) }; lastError = nil }
    /// Resolves (and renews a stale) bookmark; nil means access was revoked and the folder must be chosen again.
    private func folder() -> URL? {
        if let fixture { return URL(fileURLWithPath: fixture, isDirectory: true) }
        guard let data = d.data(forKey: "backupFolderBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        // Renew only the bookmark; keep the own-file list and last success.
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let b = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) { d.set(b, forKey: "backupFolderBookmark") }
        }
        return url
    }
    func runIfDue(_ library: Library?, force: Bool = false) async {
        guard let library, !running, enabled else { return }
        let revision = (try? library.query("SELECT coalesce((SELECT max(updated_utc) FROM ll_record),'') || (SELECT count(*) FROM ll_record) || '|' || coalesce((SELECT max(updated_utc) FROM ll_group_edit),'') || (SELECT count(*) FROM ll_group_edit)").first?.s(0)) ?? ""
        let dirty = revision != d.string(forKey: "backupFolderRevision")
        guard force || (dirty && (lastSuccess.map { Date().timeIntervalSince($0) >= 86400 } ?? true)) else { return }
        guard let dir = folder() else { lastError = String(localized: "无法再访问所选文件夹（可能已移动或权限被撤销）。请重新选择文件夹；本机记录不受影响，也可以用“导出备份”。"); return }
        running = true; defer { running = false }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let name = "BirdCM-\(f.string(from: Date()))-\(UUID().uuidString.lowercased()).birdcm"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            try await Task.detached { try library.export(to: local) }.value
            let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            let scoped = dir.startAccessingSecurityScopedResource(); defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(name)
            try Self.coordinated(writing: dest) { try FileManager.default.copyItem(at: local, to: $0) }
            // Verified = the provider holds the full byte count we just verified locally; only then can older own files go.
            guard (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else { throw StoreError(message: String(localized: "写入后的文件大小不对")) }
            var own = (d.stringArray(forKey: "backupFolderOwn") ?? []) + [name]
            while own.count > 3 {
                let old = dir.appendingPathComponent(own.removeFirst())
                if FileManager.default.fileExists(atPath: old.path) { try? Self.coordinated(writing: old) { try FileManager.default.removeItem(at: $0) } }
            }
            d.set(own, forKey: "backupFolderOwn"); d.set(Date(), forKey: "backupFolderLast"); d.set(revision, forKey: "backupFolderRevision"); lastError = nil
        } catch {
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "。. "))
            lastError = String(localized: "这次没有备份成功：\(reason)。本机记录不受影响；之前的备份文件没有删除。")
        }
    }
    nonisolated static func coordinated(writing url: URL, _ body: (URL) throws -> Void) throws {
        var error: NSError?, inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in do { try body(u) } catch { inner = error } }
        if let e = error ?? inner { throw e }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let c = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false); c.delegate = context.coordinator; return c
    }
    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(_ done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { done(nil) }
    }
}

struct FolderBackupSection: View {
    @Environment(AppModel.self) var model
    @State private var choosing = false
    var storage: Int?
    var backup = FolderBackup.shared
    var body: some View {
        Section {
            if !backup.enabled {
                Text("关闭。选好文件夹（“我的 iPhone”或 iCloud 云盘等）后，App 回到前台时如果记录有变化、且距上次成功备份满 24 小时，会自动写一份新备份；只保留本应用在那里写的最近 3 份。").font(.footnote)
                Button("选择备份文件夹…", systemImage: "folder") { choosing = true }.accessibilityIdentifier("backup.chooseFolder").frame(minHeight: 44)
            } else {
                LabeledContent("文件夹", value: backup.folderName ?? "测试文件夹")
                LabeledContent("上次成功", value: backup.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "还没有"))
                LabeledContent("预计大小", value: storage.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                if let e = backup.lastError { Text(e).font(.footnote).foregroundStyle(Palette.rust).accessibilityIdentifier("backup.folderError") }
                else if backup.lastSuccess != nil { Text("备份文件已写入；云端上传由文件提供方处理。").font(.footnote).accessibilityIdentifier("backup.folderOK") }
                if backup.running { ProgressView("正在备份…") }
                Button("立即备份", systemImage: "arrow.clockwise") { Task { await backup.runIfDue(model.library, force: true) } }.disabled(backup.running || model.migration != nil).accessibilityIdentifier("backup.now").frame(minHeight: 44)
                Button("换一个文件夹…") { choosing = true }.frame(minHeight: 44)
                Button("停止定期备份", role: .destructive) { backup.stop() }.accessibilityIdentifier("backup.stopFolder").frame(minHeight: 44)
            }
        } header: { Text("定期备份到文件夹") } footer: { Text("只在 App 打开时进行，没有后台定时；系统不告诉我们云端何时上传完成。") }
        .sheet(isPresented: $choosing) { FolderPicker { url in choosing = false; if let url { backup.choose(url); Task { await backup.runIfDue(model.library, force: true) } } } }
    }
}
