import Darwin
import Foundation

/// Resident size, not Activity Monitor's footprint, which omits mmapped GGUF weights; the lifetime
/// max footprint is folded in to catch spikes between samples.
public final class ProcessMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0

    public init() {}

    public func start(pid: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let usage = Self.memoryUsage(of: pid) else { return }
            self?.lock.withLock { self?.peak = max(self?.peak ?? 0, usage) }
        }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    public func stop() -> UInt64? {
        lock.withLock {
            timer?.cancel()
            timer = nil
            return peak > 0 ? peak : nil
        }
    }

    private static func memoryUsage(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? max(info.ri_resident_size, info.ri_lifetime_max_phys_footprint) : nil
    }
}
