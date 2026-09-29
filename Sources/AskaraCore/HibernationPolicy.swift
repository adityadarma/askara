import Foundation

/// Compact tab state for hibernation decisions.
public struct TabSnapshot: Equatable {
    public let id: UUID
    public let lastActive: Date
    public let isLoaded: Bool
    public let isActive: Bool
    /// Page process memory (phys_footprint). 0 if unknown or the process is shared.
    public let memoryBytes: UInt64
    /// Tabs playing audio (music, calls) are not put to sleep unless RAM is critical.
    public let isPlayingAudio: Bool
    /// Has unsubmitted form input. This tab is never put to sleep so the input isn't lost.
    public let hasUnsavedInput: Bool

    public init(id: UUID, lastActive: Date, isLoaded: Bool, isActive: Bool,
                memoryBytes: UInt64 = 0, isPlayingAudio: Bool = false, hasUnsavedInput: Bool = false) {
        self.id = id
        self.lastActive = lastActive
        self.isLoaded = isLoaded
        self.isActive = isActive
        self.memoryBytes = memoryBytes
        self.isPlayingAudio = isPlayingAudio
        self.hasUnsavedInput = hasUnsavedInput
    }
}

/// Decides which tabs have their WebView discarded to free RAM.
/// Hibernated tabs keep only URL + title; they reload when opened.
public struct HibernationPolicy: Equatable {
    /// Background tabs idle longer than this are hibernated.
    public var idleTimeout: TimeInterval
    /// Maximum number of tabs with a live WebView (including active tabs).
    public var maxLoadedTabs: Int
    /// Total memory limit for all loaded tabs (including active tabs). nil = unlimited.
    public var memoryBudget: UInt64?

    public init(idleTimeout: TimeInterval = 5 * 60, maxLoadedTabs: Int = 3, memoryBudget: UInt64? = nil) {
        self.idleTimeout = idleTimeout
        self.maxLoadedTabs = max(1, maxLoadedTabs)
        self.memoryBudget = memoryBudget
    }

    /// 1/8 of physical RAM, clamped to 512 MB – 1.5 GB.
    public static func defaultMemoryBudget(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64 {
        let mb: UInt64 = 1_048_576
        return min(max(physicalMemory / 8, 512 * mb), 1_536 * mb)
    }

    public func tabsToHibernate(_ tabs: [TabSnapshot],
                                now: Date = Date(),
                                underMemoryPressure: Bool = false) -> [UUID] {
        // Candidates: loaded background tabs. Active tabs are never touched.
        // Tabs with unsubmitted form input are never touched, even when RAM is low.
        let allBackground = tabs.filter { $0.isLoaded && !$0.isActive && !$0.hasUnsavedInput }

        if underMemoryPressure {
            return allBackground.map(\.id)
        }
        let background = allBackground.filter { !$0.isPlayingAudio }

        var result = Set(background
            .filter { now.timeIntervalSince($0.lastActive) >= idleTimeout }
            .map(\.id))

        // If still over the count limit, discard the least recently used.
        // There can be more than one active tab with multiple windows.
        let activeLoaded = tabs.filter { $0.isLoaded && $0.isActive }.count
        let survivors = background
            .filter { !result.contains($0.id) }
            .sorted { $0.lastActive < $1.lastActive }
        let excess = survivors.count + activeLoaded - maxLoadedTabs
        if excess > 0 {
            survivors.prefix(excess).forEach { result.insert($0.id) }
        }

        // If total memory still exceeds the budget, discard the least recently used
        // until under budget. Tabs without memory data are skipped since they don't help.
        if let budget = memoryBudget {
            var total = tabs
                .filter { $0.isLoaded && !result.contains($0.id) }
                .reduce(UInt64(0)) { $0 + $1.memoryBytes }
            for tab in survivors where !result.contains(tab.id) && tab.memoryBytes > 0 {
                guard total > budget else { break }
                result.insert(tab.id)
                total -= min(total, tab.memoryBytes)
            }
        }

        // Stable order matching tab order.
        return background.map(\.id).filter(result.contains)
    }
}
