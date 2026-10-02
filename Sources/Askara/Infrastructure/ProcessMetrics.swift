import Darwin
import Foundation

/// Reads process memory usage (the same number as the "Memory" column in Activity Monitor).
enum ProcessMemory {
    static func footprint(pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

}

/// Reads process CPU time (user + system), the same source as Activity Monitor's "% CPU" column.
/// CPU time only ever increases, so callers must poll twice and diff: see `CPUUsageTracker`.
enum ProcessCPU {
    /// Total CPU time consumed by the process since it started, in nanoseconds.
    static func time(pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_user_time + info.ri_system_time : nil
    }
}

/// Turns cumulative CPU time into a "% CPU" figure by diffing CPU and wall-clock samples.
@MainActor
final class CPUUsageTracker {
    private struct Sample { let cpuTime: UInt64; let wallTime: DispatchTime }
    private var samples: [pid_t: Sample] = [:]

    /// Percent of one core used since the last call for this pid (0 the first time it's seen).
    /// 100 means one full core saturated; can exceed 100 for multi-threaded processes.
    func usage(pid: pid_t) -> Double {
        guard let cpuTime = ProcessCPU.time(pid: pid) else { return 0 }
        let now = DispatchTime.now()
        defer { samples[pid] = Sample(cpuTime: cpuTime, wallTime: now) }
        guard let previous = samples[pid], cpuTime >= previous.cpuTime else { return 0 }
        let wallElapsed = now.uptimeNanoseconds &- previous.wallTime.uptimeNanoseconds
        guard wallElapsed > 0 else { return 0 }
        let cpuElapsed = cpuTime - previous.cpuTime
        return (Double(cpuElapsed) / Double(wallElapsed)) * 100
    }

    /// Drops samples for processes no longer seen, so a reused pid doesn't inherit a stale baseline.
    func prune(keeping pids: Set<pid_t>) {
        samples = samples.filter { pids.contains($0.key) }
    }
}
