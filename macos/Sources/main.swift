// 观羽 menu-bar app: a thin shell over `birdcm admin ...` (engine/birdcm/admin.py). Every decision about files,
// models, ports and stopping lives in the engine and its tests; this file only shows state and runs commands.
import AppKit
import ServiceManagement
import SwiftUI

// ---- JSON the engine prints -----------------------------------------------------------------------------------------

struct ModelFile: Decodable, Identifiable {
    let name, role, state, effect: String
    let bytes: Int64
    let optional, downloaded: Bool
    var id: String { name }
}
struct ModelsStatus: Decodable {
    let files: [ModelFile]
    let ready: Bool
    let presentBytes, downloadBytes: Int64
    let missing, notReleased: [String]
    let dir: String
}
struct Usage: Decodable { let img, models, db, singles, log: Int64 }
struct Paths: Decodable { let config, data, cache, models, db, log: String; let port: Int; let overridden: [String] }
struct EngineInfo: Decodable { let pid: Int?; let port: Int?; let exe: String? }
struct Health: Decodable { let running, ready: Bool; let engine: EngineInfo?; let port: Int }
struct Reply: Decodable { let error: String?; let message: String?; let suggest: Int?; let port: Int?; let engine: EngineInfo? }
struct Loaded: Decodable { let engine: String?; let loadError: String? }   // GET /api/models: the models in memory
struct Progress: Decodable { let file: String?; let state: String?; let done: Int64?; let total: Int64?; let error: String?; let finished: Bool? }

func decode<T: Decodable>(_ t: T.Type, _ line: String) -> T? {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try? d.decode(t, from: Data(line.utf8))
}
func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// ---- the engine ------------------------------------------------------------------------------------------------------

@MainActor final class Engine: ObservableObject {
    static let shared = Engine()
    enum State: Equatable { case stopped, starting, running(Int), stopping, failed(String) }

    @Published var state: State = .stopped { didSet { snapshot() } }
    @Published var suggestPort: Int? { didSet { snapshot() } }   // the configured port is busy: offer this one
    @Published var foreign: EngineInfo?             // an engine from another copy of the app holds the lock
    @Published var models: ModelsStatus? { didSet { snapshot() } }
    @Published var loaded: Loaded? { didSet { snapshot() } }   // the running engine loads its models in the background

    /// Testing: the menu's status lines as text (BIRDCM_SNAPSHOT=dir), since a menu cannot be captured.
    private func snapshot() {
        guard let dir = ProcessInfo.processInfo.environment["BIRDCM_SNAPSHOT"] else { return }
        let text = [statusLine, modelsLine] + (suggestPort.map { ["改用端口 \($0) 启动"] } ?? []) + (fetchNote.map { [$0] } ?? [])
        try? text.joined(separator: "\n").write(toFile: "\(dir)/menu.txt", atomically: true, encoding: .utf8)
    }
    @Published var usage: Usage?
    @Published var paths: Paths?
    @Published var fetching: (file: String, done: Int64, total: Int64)? { didSet { snapshot() } }
    @Published var fetchNote: String? { didSet { snapshot() } }
    @Published var busy: String?                    // a long admin command is running (move, clear ...)

    let launcher = Bundle.main.resourceURL!.appendingPathComponent("engine/birdcm")
    private var proc: Process?
    private var fetchProc: Process?
    private var stopping = false
    private var openWhenReady = false
    private var timer: Timer?

    var port: Int? { if case .running(let p) = state { return p }; return nil }
    var url: URL? { port.map { URL(string: "http://127.0.0.1:\($0)/")! } }

    /// Run `birdcm admin ARGS`; lines arrive as they are printed; returns (exit status, last line).
    nonisolated func admin(_ args: [String], started: ((Process) -> Void)? = nil,
                           line: ((String) -> Void)? = nil) async -> (Int32, String) {
        let p = Process()
        p.executableURL = launcher
        p.arguments = ["admin"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "{\"error\": \"\(error.localizedDescription)\"}") }
        started?(p)
        var last = ""
        do { for try await l in out.fileHandleForReading.bytes.lines { last = l; line?(l) } } catch {}
        p.waitUntilExit()
        return (p.terminationStatus, last)
    }

    func refresh() async {
        let (_, p) = await admin(["paths"]); paths = decode(Paths.self, p)
        let (_, u) = await admin(["usage"]); usage = decode(Usage.self, u)
        let (_, m) = await admin(["models-status"]); models = decode(ModelsStatus.self, m) ?? models
    }

    /// At launch / reopen: adopt an engine this app started earlier, else start one.
    func adoptOrStart(open: Bool) async {
        let (_, out) = await admin(["health"])
        if let h = decode(Health.self, out), h.running {
            let exe = h.engine?.exe ?? ""
            if exe.hasPrefix(Bundle.main.bundlePath + "/") {
                foreign = nil
                openWhenReady = open
                state = .starting
                poll(port: h.engine?.port ?? h.port)
            } else {
                foreign = h.engine
                state = .failed("另一个观羽引擎在运行（pid \(h.engine?.pid ?? 0)，\(exe)）")
            }
            return
        }
        start(port: nil, open: open)
    }

    func start(port: Int?, open: Bool) {
        if case .running = state { if open { openUI() }; return }
        if state == .starting || state == .stopping { openWhenReady = openWhenReady || open; return }
        state = .starting
        suggestPort = nil
        foreign = nil
        stopping = false
        openWhenReady = open
        let p = Process()
        p.executableURL = launcher
        p.arguments = ["admin", "serve"] + (port.map { ["--port", "\($0)"] } ?? [])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let exit = AsyncStream<Int32> { c in p.terminationHandler = { c.yield($0.terminationStatus); c.finish() } }
        do { try p.run() } catch { state = .failed("无法启动引擎：\(error.localizedDescription)"); return }
        proc = p
        Task {
            // {"event": "starting", "port": N} and then output goes to engine.log (EOF here), or an error line and exit
            var lines: [String] = []
            do {
                for try await l in out.fileHandleForReading.bytes.lines {
                    lines.append(l)
                    if let r = decode(Reply.self, l), r.error == nil, let port = r.port { poll(port: port) }
                }
            } catch {}
            for await code in exit { exited(p, code, lines) }
        }
    }

    private func exited(_ p: Process, _ code: Int32, _ lines: [String]) {
        guard p === proc else { return }
        proc = nil
        if stopping { return }
        let r = lines.compactMap { decode(Reply.self, $0) }.first { $0.error != nil }
        switch (code, r) {
        case (3, _): Task { await adoptOrStart(open: openWhenReady) }           // someone else started one first
        case (0, nil), (SIGTERM, nil): state = .stopped                         // stopped from elsewhere (`admin stop`)
        case (4, let r?): suggestPort = r.suggest; state = .failed(r.message ?? "端口被占用")
        case (_, let r?): state = .failed(r.message ?? r.error ?? "启动失败")
        default: state = .failed("引擎退出了（代码 \(code)），详情见日志")
        }
    }

    private func poll(port: Int) {
        Task {
            let url = URL(string: "http://127.0.0.1:\(port)/api/session")!
            for _ in 0..<600 {
                if state != .starting { return }
                if let (_, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                    state = .running(port)
                    if openWhenReady { openWhenReady = false; openUI() }   // the page is usable while the models load
                    watch()
                    await followLoad(port)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if state == .starting { state = .failed("引擎 3 分钟内没有就绪，详情见日志") }
        }
    }

    /// Until the models are in memory: 模型加载中 → 就绪 (or 出错, which a download or 重试 can still turn around).
    private func followLoad(_ port: Int) async {
        let url = URL(string: "http://127.0.0.1:\(port)/api/models")!
        while self.port == port {
            if let (d, _) = try? await URLSession.shared.data(from: url) { loaded = decode(Loaded.self, String(decoding: d, as: UTF8.self)) }
            if loaded?.engine == "ready" { return }
            try? await Task.sleep(nanoseconds: loaded?.engine == "error" ? 5_000_000_000 : 1_000_000_000)   // error: models downloaded, a retry
        }
    }

    /// Notice an engine that went away (crash, `birdcm admin stop` from a terminal).
    private func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                guard let url = self.url?.appendingPathComponent("api/session") else { return }
                if (try? await URLSession.shared.data(from: url)) == nil, self.port != nil {
                    let (_, out) = await self.admin(["health"])
                    if decode(Health.self, out)?.running != true, self.port != nil { self.state = .stopped }
                }
            }
        }
    }

    func stop() async {
        guard state != .stopped else { return }
        stopping = true
        loaded = nil
        state = .stopping
        _ = await admin(["stop"])
        proc = nil
        foreign = nil
        state = .stopped
    }

    func restart() async { await stop(); start(port: nil, open: false) }

    func openUI() {
        guard let url else { start(port: nil, open: true); return }
        if ProcessInfo.processInfo.environment["BIRDCM_NO_BROWSER"] == nil { NSWorkspace.shared.open(url) }
    }

    func openLog() {
        if let log = paths?.log { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
    }

    /// Something that needs the engine stopped (move, delete): stop, run, start again if it was running.
    func whileStopped(_ what: String, _ body: () async -> String?) async -> String? {
        let was = port != nil || state == .starting
        busy = what
        if was { await stop() }
        let err = await body()
        busy = nil
        await refresh()
        if was { start(port: nil, open: false) }
        return err
    }

    func run(_ args: [String]) async -> String? {
        let (code, out) = await admin(args)
        return code == 0 ? nil : (decode(Reply.self, out)?.error ?? "失败（代码 \(code)）")
    }

    func fetch() {
        guard fetchProc == nil else { return }
        fetchNote = nil
        fetching = ("", 0, 1)
        Task {
            _ = await admin(["models-fetch"], started: { p in Task { @MainActor in self.fetchProc = p } }) { line in
                guard let e = decode(Progress.self, line) else { return }
                Task { @MainActor in
                    if let f = e.file, let d = e.done, let t = e.total { self.fetching = (f, d, t) }
                    if e.state == "failed", let f = e.file { self.fetchNote = (self.fetchNote.map { $0 + "；" } ?? "下载失败：") + "\(f)：\(e.error ?? "")" }
                }
            }
            fetchProc = nil
            fetching = nil
            await refresh()
        }
    }

    func cancelFetch() { fetchProc?.terminate(); fetchNote = "已取消下载" }

    var statusLine: String {
        switch state {
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .running(let p):
            let m = loaded?.engine == "loading" ? " · 模型加载中…" : loaded?.engine == "error" ? " · 模型出错（页面顶栏可重试）" : loaded?.engine == "ready" ? " · 模型就绪" : ""
            return "运行中 · 端口 \(p)\(m)"
        case .stopping: return "正在停止…"
        case .failed(let why): return "出错：\(why)"
        }
    }

    var modelsLine: String {
        if let f = fetching { return f.total > 1 ? "模型下载中 \(Int(100 * Double(f.done) / Double(f.total)))% · \(f.file)" : "模型下载中…" }
        guard let m = models else { return "模型：检查中…" }
        var s = m.missing.isEmpty ? "模型：就绪（\(size(m.presentBytes))）" : "模型：缺 \(m.missing.count) 个（\(size(m.downloadBytes))）"
        if !m.notReleased.isEmpty { s += " · \(m.notReleased.count) 个尚未发布" }
        return s
    }
}

// ---- windows ---------------------------------------------------------------------------------------------------------

@MainActor enum Windows {
    static var open: [String: NSWindow] = [:]
    static func show<V: View>(_ id: String, _ title: String, _ view: V) {
        let w = open[id] ?? {
            let hc = NSHostingController(rootView: view)
            hc.sizingOptions = []             // else wrapped Text sends AppKit into a constraint-update loop (crash)
            let w = NSWindow(contentViewController: hc)
            w.setContentSize(hc.view.fittingSize)
            w.styleMask.remove(.resizable)
            w.title = title
            w.isReleasedWhenClosed = false
            w.center()
            open[id] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if let dir = ProcessInfo.processInfo.environment["BIRDCM_SNAPSHOT"] {    // testing: what the window shows, as PNG
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let r = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
                r.scale = 2
                guard let img = r.cgImage else { return }
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(id).png"))
            }
        }
    }
    static func close(_ id: String) { open[id]?.close() }
}

struct WelcomeView: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("欢迎使用观羽").font(.title2.bold())
            Text("观羽在这台 Mac 上运行，照片不会上传。它在后台运行一个本地服务，界面在浏览器里打开（http://127.0.0.1）。菜单栏的小鸟图标可以启动、停止服务，管理模型和缓存。")
            if let m = e.models {
                Text("首次使用要下载识别模型，共 \(size(m.downloadBytes))（来自 GitHub，逐个校验 sha256）。" +
                     (m.notReleased.isEmpty ? "" : "另有 \(m.notReleased.count) 个文件尚未发布，以后再下载，不影响使用。"))
            } else {
                Text("正在检查需要下载的模型…").foregroundStyle(.secondary)
            }
            if let p = e.paths {
                Text("模型、缩略图和预览：\(p.cache)\n数据库：\(p.data)\n都可以在“设置”里更改位置。").font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("开始使用") {
                    UserDefaults.standard.set(true, forKey: "welcomed")
                    if e.models?.missing.isEmpty == false { e.fetch() }
                    Windows.close("welcome")
                    Task { await e.adoptOrStart(open: true) }
                }.keyboardShortcut(.defaultAction)
            }
        }.fixedSize(horizontal: false, vertical: true).padding(24).frame(width: 520, height: 360, alignment: .top)
    }
}

struct SettingsView: View {
    @ObservedObject var e = Engine.shared
    @State private var error: String?

    var body: some View {
        Form {
            Section("服务") {
                LabeledContent("状态", value: e.statusLine)
                if let b = e.busy { LabeledContent("正在", value: b) }
                HStack { Button("查看日志") { e.openLog() }; Spacer() }
            }
            Section("模型") {
                ForEach(e.models?.files ?? []) { f in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.name).font(.callout)
                            if f.optional && f.state != "present" { Text(f.effect).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(size(f.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        Text(["present": "已就绪", "missing": "缺少", "not_released": "尚未发布"][f.state] ?? f.state)
                            .foregroundStyle(f.state == "present" ? .green : f.state == "missing" ? .orange : .secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                if let m = e.models { Text("已有 \(size(m.presentBytes))，待下载 \(size(m.downloadBytes))").font(.caption) }
                if let f = e.fetching {
                    ProgressView(value: Double(f.done), total: Double(max(f.total, 1))) { Text("下载 \(f.file)") }
                }
                if let n = e.fetchNote { Text(n).font(.caption).foregroundStyle(.orange) }
                HStack {
                    if e.fetching != nil { Button("取消下载") { e.cancelFetch() } }
                    else { Button("下载缺少的模型") { e.fetch() }.disabled(e.models?.missing.isEmpty != false) }
                    Button("重新校验") { Task { error = await e.run(["models-verify"]); await e.refresh() } }
                    Button("删除已下载的模型…") { removeModels() }.disabled(e.fetching != nil)
                    Button("打开模型文件夹") { reveal(e.models?.dir ?? e.paths?.models) }
                }
            }
            Section("缓存与数据") {
                LabeledContent("缩略图和预览", value: size(e.usage?.img ?? 0))
                LabeledContent("模型", value: size(e.usage?.models ?? 0))
                LabeledContent("数据库", value: size((e.usage?.db ?? 0) + (e.usage?.singles ?? 0)))
                LabeledContent("缓存位置") { pathRow(e.paths?.cache, kind: "cache") }
                LabeledContent("数据位置") { pathRow(e.paths?.data, kind: "data") }
                HStack {
                    Button("清空缓存") { Task { error = await e.run(["clear-cache"]); await e.refresh() } }
                    Button("删除数据库…") { deleteDatabase() }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped).frame(width: 600, height: 640)
        .task { await e.refresh() }
    }

    func pathRow(_ path: String?, kind: String) -> some View {
        HStack {
            Text(path ?? "").font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button("在访达中显示") { reveal(path) }
            Button("更改…") { move(kind) }.disabled(e.paths?.overridden.contains(kind == "cache" ? "BIRDCM_CACHE_DIR" : "BIRDCM_DATA_DIR") ?? false)
        }
    }

    func reveal(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func confirm(_ title: String, _ text: String, _ ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    func move(_ kind: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "移到这里"
        panel.message = kind == "cache" ? "选择缓存（模型、缩略图、预览）的新位置" : "选择数据库的新位置"
        guard panel.runModal() == .OK, let dest = panel.url?.path else { return }
        guard confirm("移动\(kind == "cache" ? "缓存" : "数据")", "内容会移到 \(dest)（不是空文件夹时放进其中的 BirdCM 子文件夹）。服务会先停止，完成后重新启动。", "移动") else { return }
        Task { error = await e.whileStopped("移动\(kind == "cache" ? "缓存" : "数据")") { await e.run(["move-\(kind)", dest]) } }
    }

    func removeModels() {
        guard confirm("删除已下载的模型", "删除缓存里下载的模型文件（\(size(e.usage?.models ?? 0))），以后可以重新下载。服务会先停止。", "删除") else { return }
        Task { error = await e.whileStopped("删除模型") { await e.run(["models-remove"]) } }
    }

    func deleteDatabase() {
        guard confirm("删除数据库？", "所有扫描记录、星级和单张识别的历史都会删除，照片本身不受影响。", "继续"),
              confirm("确定删除数据库？", "这一步不能撤销。", "删除数据库") else { return }
        Task { error = await e.whileStopped("删除数据库") { await e.run(["clear-cache", "--database"]) } }
    }
}

// ---- menu ------------------------------------------------------------------------------------------------------------

struct MenuView: View {
    @ObservedObject var e = Engine.shared
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(e.statusLine)
        if let p = e.suggestPort { Button("改用端口 \(p) 启动") { e.start(port: p, open: true) } }
        if e.foreign != nil { Button("停止那个引擎") { Task { await e.stop(); e.start(port: nil, open: false) } } }
        Button("打开观羽") { e.openUI() }.keyboardShortcut("o").disabled(e.port == nil)
        Divider()
        switch e.state {
        case .stopped, .failed: Button("启动") { e.start(port: nil, open: false) }
        default:
            Button("停止") { Task { await e.stop() } }.disabled(e.state == .stopping)
            Button("重新启动") { Task { await e.restart() } }.disabled(e.state == .stopping)
        }
        Divider()
        Text(e.modelsLine)
        if e.fetching != nil { Button("取消下载") { e.cancelFetch() } }
        else if e.models?.missing.isEmpty == false { Button("下载缺少的模型") { e.fetch() } }
        Button("设置…") { Windows.show("settings", "观羽 设置", SettingsView()) }.keyboardShortcut(",")
        Button("查看日志") { e.openLog() }
        Toggle("登录时启动", isOn: Binding(get: { login }, set: { on in
            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                NSAlert(error: error).runModal()
            }
            login = SMAppService.mainApp.status == .enabled
        }))
        Divider()
        Button("退出观羽") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = ev?.eventID == kAEOpenApplication &&
            ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Task { @MainActor in
            let e = Engine.shared
            let env = ProcessInfo.processInfo.environment
            if env["BIRDCM_OPEN_SETTINGS"] != nil { Windows.show("settings", "观羽 设置", SettingsView()) }   // testing
            if env["BIRDCM_TEST_FETCH"] != nil {                    // testing: start a download, cancel it after 5 s
                e.fetch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { e.cancelFetch() }
            }
            if UserDefaults.standard.bool(forKey: "welcomed") || ProcessInfo.processInfo.environment["BIRDCM_SKIP_WELCOME"] != nil {
                await e.adoptOrStart(open: !atLogin)
                await e.refresh()
            } else {
                Windows.show("welcome", "观羽", WelcomeView())
                await e.refresh()
            }
        }
    }

    /// A second launch (Finder, Dock, `open`) opens the web page, starting the engine when needed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in Engine.shared.openUI() }
        return false
    }

    /// Quit stops the engine first (graceful, then killed after a timeout by `admin stop`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await Engine.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct BirdCMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    static let icon: NSImage = {
        let i = NSImage(named: "MenuIcon") ?? NSImage(systemSymbolName: "bird", accessibilityDescription: "观羽")!
        i.isTemplate = true
        return i
    }()
    var body: some Scene {
        MenuBarExtra { MenuView() } label: { Image(nsImage: Self.icon) }
    }
}

BirdCMApp.main()
