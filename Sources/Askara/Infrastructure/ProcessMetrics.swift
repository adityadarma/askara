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

    /// One process and its memory, for the Task Manager's "Other Processes" list.
    struct Usage: Equatable {
        let pid: pid_t
        /// Executable name, e.g. "com.apple.WebKit.GPU".
        let name: String
        let bytes: UInt64

        /// Readable name for the known WebKit helpers; other processes keep their own name.
        var displayName: String { ProcessMemory.displayName(for: name) }
    }

    /// Every process macOS attributes to `pid` (itself plus WebKit's page, extension, GPU, and
    /// network processes), largest first. Their sum is the figure Activity Monitor and tools like
    /// Stats show for the app. Nil when the system call is unavailable.
    static func responsibleProcesses(of pid: pid_t) -> [Usage]? {
        guard let responsible = responsiblePID else { return nil }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        return pids.prefix(Int(count))
            // The process itself always counts, even when macOS attributes it to another app
            // (e.g. when launched from a terminal).
            .filter { $0 > 0 && ($0 == pid || responsible($0) == pid) }
            .map { Usage(pid: $0, name: name(of: $0), bytes: footprint(pid: $0) ?? 0) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Sum of `responsibleProcesses(of:)`.
    static func responsibleFootprint(of pid: pid_t) -> UInt64? {
        responsibleProcesses(of: pid)?.reduce(UInt64(0)) { $0 + $1.bytes }
    }

    static func displayName(for processName: String) -> String {
        switch processName {
        case "com.apple.WebKit.WebContent":
            // Not one of the tabs: an extension's background page or popup, or a page process
            // WebKit keeps ready so the next tab opens faster.
            String(localized: "Extension or preloaded page")
        case "com.apple.WebKit.GPU": String(localized: "Graphics (WebKit)")
        case "com.apple.WebKit.Networking": String(localized: "Network (WebKit)")
        case "com.apple.SafariPlatformSupport.Helper", "com.apple.SafariPlatformSupport":
            String(localized: "Safari platform support")
        case "com.apple.audio.SandboxHelper": String(localized: "Audio helper")
        default: processName
        }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "PID \(pid)" }
        return String(cString: buffer)
    }

    /// `responsibility_get_pid_responsible_for_pid` (libsystem): which app a helper process
    /// belongs to. Looked up at runtime because it has no public header.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

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
