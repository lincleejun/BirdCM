import Foundation
import Darwin

struct DiagnosticRun: Codable {
    var stages: [String:Double] = [:]
    var peakBytes: UInt64 = 0
    var compute: String = Diagnostics.compute
}
enum Diagnostics {
    static var compute: String {
        #if targetEnvironment(simulator)
        return "cpuOnly（模拟器）"
        #else
        return UserDefaults.standard.string(forKey:"computeUnits") ?? "all"
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
