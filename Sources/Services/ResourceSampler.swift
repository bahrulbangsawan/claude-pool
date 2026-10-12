import Darwin
import Foundation

/// CPU and memory counters read from the kernel (Mach host statistics and `proc_pid_rusage`).
/// Read-only: no process is signalled, attached to or inspected beyond these counters.
enum ResourceSampler {
    /// Cumulative CPU ticks of the whole machine, all cores.
    struct CPUTicks: Equatable, Sendable {
        var busy: UInt64
        var total: UInt64
    }

    /// Cumulative CPU time and current memory footprint of one process.
    struct ProcessCounters: Equatable, Sendable {
        var cpuNanoseconds: UInt64
        /// Physical footprint, the figure Activity Monitor shows as "Memory".
        var footprint: UInt64
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// Memory in use the way Activity Monitor counts it (app + wired + compressed), and installed RAM.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let anonymous = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// Counters of a process owned by the current user, or nil when it has exited or isn't readable.
    static func process(_ pid: Int32) -> ProcessCounters? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // rusage times are Mach absolute time units (not nanoseconds on Apple silicon).
        let ticks = Double(usage.ri_user_time) + Double(usage.ri_system_time)
        return ProcessCounters(cpuNanoseconds: UInt64(ticks * timebaseRatio), footprint: usage.ri_phys_footprint)
    }

    private static let timebaseRatio: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    // MARK: Rates

    /// Share of the machine's CPU time spent busy between two samples, 0–100.
    static func cpuPercent(from old: CPUTicks, to new: CPUTicks) -> Double? {
        guard new.total > old.total, new.busy >= old.busy else { return nil }
        return min(100, Double(new.busy - old.busy) / Double(new.total - old.total) * 100)
    }

    /// CPU used by one process between two samples, as Activity Monitor shows it: 100% is one
    /// full core, so a busy process can exceed 100%.
    static func processCPUPercent(cpuDelta: UInt64, wallDelta: TimeInterval) -> Double? {
        guard wallDelta > 0 else { return nil }
        return Double(cpuDelta) / (wallDelta * 1_000_000_000) * 100
    }
}
