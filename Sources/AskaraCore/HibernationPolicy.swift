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
    /// Pinned tab or a Memory Saver exception site: never put to sleep.
    public let keepAwake: Bool

    public init(id: UUID, lastActive: Date, isLoaded: Bool, isActive: Bool,
                memoryBytes: UInt64 = 0, isPlayingAudio: Bool = false, hasUnsavedInput: Bool = false,
                keepAwake: Bool = false) {
        self.id = id
        self.lastActive = lastActive
        self.isLoaded = isLoaded
        self.isActive = isActive
        self.memoryBytes = memoryBytes
        self.isPlayingAudio = isPlayingAudio
        self.hasUnsavedInput = hasUnsavedInput
        self.keepAwake = keepAwake
    }
}

/// Memory pressure reported by macOS.
public enum MemoryPressure: String, Sendable {
    case normal, warning, critical
}

/// Why a tab was put to sleep (for logs).
public enum HibernationReason: String, Sendable {
    case idle, tabLimit, memoryBudget, memoryCritical
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
    /// Tabs used within this time are spared by the tab-count and memory limits, so switching
    /// away from a tab and straight back doesn't reload it. Ignored when macOS reports memory pressure.
    public var recentGrace: TimeInterval

    public init(idleTimeout: TimeInterval = 5 * 60, maxLoadedTabs: Int = 3, memoryBudget: UInt64? = nil,
                recentGrace: TimeInterval = 0) {
        self.idleTimeout = idleTimeout
        self.maxLoadedTabs = max(1, maxLoadedTabs)
        self.memoryBudget = memoryBudget
        self.recentGrace = max(0, recentGrace)
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
        decisions(tabs, now: now, pressure: underMemoryPressure ? .critical : .normal).map(\.id)
    }

    /// Tabs to put to sleep, with the reason, in tab order.
    /// - normal: idle timeout, then tab-count and memory limits (recently used tabs are spared).
    /// - warning: the same limits, but recently used tabs are no longer spared.
    /// - critical: every background tab.
    public func decisions(_ tabs: [TabSnapshot], now: Date = Date(),
                          pressure: MemoryPressure = .normal) -> [(id: UUID, reason: HibernationReason)] {
        // Candidates: loaded background tabs. Active tabs are never touched.
        // Tabs with unsubmitted form input, pinned tabs, and exception sites are never touched,
        // even when RAM is low.
        let allBackground = tabs.filter { $0.isLoaded && !$0.isActive && !$0.hasUnsavedInput && !$0.keepAwake }

        if pressure == .critical {
            return allBackground.map { ($0.id, .memoryCritical) }
        }
        let background = allBackground.filter { !$0.isPlayingAudio }

        var reasons: [UUID: HibernationReason] = [:]
        for tab in background where now.timeIntervalSince(tab.lastActive) >= idleTimeout {
            reasons[tab.id] = .idle
        }

        func evictable(_ tab: TabSnapshot) -> Bool {
            pressure == .warning || now.timeIntervalSince(tab.lastActive) >= recentGrace
        }

        // If still over the count limit, discard the least recently used.
        // There can be more than one active tab with multiple windows.
        // Tabs that always stay awake still count toward the limit.
        let activeLoaded = tabs.filter { $0.isLoaded && ($0.isActive || $0.keepAwake) }.count
        let survivors = background
            .filter { reasons[$0.id] == nil }
            .sorted { $0.lastActive < $1.lastActive }
        let excess = survivors.count + activeLoaded - maxLoadedTabs
        if excess > 0 {
            survivors.filter(evictable).prefix(excess).forEach { reasons[$0.id] = .tabLimit }
        }

        // If total memory still exceeds the budget, discard the least recently used
        // until under budget. Tabs without memory data are skipped since they don't help.
        if let budget = memoryBudget {
            var total = tabs
                .filter { $0.isLoaded && reasons[$0.id] == nil }
                .reduce(UInt64(0)) { $0 + $1.memoryBytes }
            for tab in survivors where reasons[tab.id] == nil && tab.memoryBytes > 0 && evictable(tab) {
                guard total > budget else { break }
                reasons[tab.id] = .memoryBudget
                total -= min(total, tab.memoryBytes)
            }
        }

        // Stable order matching tab order.
        return background.compactMap { tab in reasons[tab.id].map { (tab.id, $0) } }
    }
}
