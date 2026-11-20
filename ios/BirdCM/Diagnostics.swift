import CoreML
import Foundation
import Darwin

struct DiagnosticRun: Codable {
    var stages: [String:Double] = [:]
    var peakBytes: UInt64 = 0
    var compute: String = Diagnostics.compute
}
enum Diagnostics {
    static let models = ["Detector", "BioCLIP", "Heads"]
    static let unitNames = ["all", "cpuAndNeuralEngine", "cpuAndGPU", "cpuOnly"]
    /// Per-model default until the 性能自测 on a real phone says otherwise (the simulator is CPU-only and decides nothing).
    static let defaultUnits = ["Detector": "all", "BioCLIP": "all", "Heads": "all"]
    /// 诊断 picker (UserDefaults "computeUnits.<model>"), else the launch argument -computeUnits, else the default.
    static func unitName(_ model: String) -> String {
        UserDefaults.standard.string(forKey: "computeUnits." + model) ?? UserDefaults.standard.string(forKey: "computeUnits") ?? defaultUnits[model] ?? "all"
    }
    static func units(_ name: String) -> MLComputeUnits {
        switch name {
        case "cpuOnly": .cpuOnly
        case "cpuAndGPU": .cpuAndGPU
        case "cpuAndNeuralEngine": .cpuAndNeuralEngine
        default: .all
        }
    }
    static func configuration(_ model: String) -> MLModelConfiguration {
        let cfg = MLModelConfiguration()
        #if targetEnvironment(simulator)
        cfg.computeUnits = .cpuOnly
        #else
        cfg.computeUnits = units(unitName(model))
        #endif
        return cfg
    }
    static var compute: String {
        #if targetEnvironment(simulator)
        return String(localized: "cpuOnly（模拟器）")
        #else
        return models.map { $0 + " " + unitName($0) }.joined(separator: " · ")
        #endif
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
final class MemorySample: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue:DispatchQueue(label:"memory-sample"))
        timer.schedule(deadline:.now(),repeating:.milliseconds(20))
        timer.setEventHandler { [weak self] in self?.sample() }; timer.resume()
    }
    func sample() { lock.lock(); peak=max(peak,Diagnostics.footprint()); lock.unlock() }
    func stop() -> UInt64 { timer.cancel(); sample(); lock.lock(); defer{lock.unlock()}; return peak }
    deinit { timer.cancel() }
}

/// Launch and stage timings measured from process start (kernel start time, so dyld and static init count).
/// Shown in 诊断; Debug builds also append them to Caches/perf.log so simulator runs can be read from the host.
enum Perf {
    static let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values = [String: Double]()
    static var marks: [String: Double] { lock.lock(); defer { lock.unlock() }; return values }
    static func since() -> Double { Date().timeIntervalSince(processStart) }
    /// Records `name` = seconds (default: now since process start); with `once` the first value wins.
    static func mark(_ name: String, _ seconds: Double? = nil, once: Bool = false) {
        let v = seconds ?? since()
        lock.lock(); defer { lock.unlock() }
        if once, values[name] != nil { return }
        values[name] = v
        log(String(format: "PERF %@ %.3f", name, v))
    }
    static func log(_ line: String) {
        #if DEBUG
        print(line)
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("perf.log")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() } else { try? data.write(to: url) }
        #endif
    }
    #if DEBUG
    /// Debug-only watchdog: pings the main queue every 50 ms and logs any wait over 100 ms (a visible hitch).
    static func watchMainThread() {
        Thread.detachNewThread {
            let ping = DispatchSemaphore(value: 0)
            while true {
                let sent = Date()
                DispatchQueue.main.async { ping.signal() }
                ping.wait()
                let lag = Date().timeIntervalSince(sent)
                if lag > 0.1 { log(String(format: "HITCH %.3f at %.1f", lag, since())) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    #endif
}
