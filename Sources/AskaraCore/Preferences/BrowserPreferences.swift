import Foundation

/// User settings (Settings window, ⌘,). Missing keys in the saved file fall back to defaults,
/// so adding a setting never resets the others.
public struct BrowserPreferences: Codable, Equatable, Sendable {
    /// Minutes before a background tab sleeps. 0 = never by time (count and memory limits still apply).
    public static let sleepChoices = [0, 1, 5, 15, 30, 60]
    /// Minutes before a background tab dozes (page kept, media paused, caches freed). 0 = off.
    public static let dozeChoices = [0, 1, 2, 5, 10]
    /// Tabs that may be loaded at once. 0 = no limit.
    public static let maxLoadedTabRange = 0...20
    /// Share of RAM all loaded tabs may use before the least recently used sleep. 0 = no limit.
    public static let memoryBudgetChoices = [12, 25, 33, 50, 0]
    /// Recently used background tabs kept awake despite the tab-count and memory limits. 0 = no limit
    /// (every tab used within `recentGrace` is kept).
    public static let protectedTabRange = 0...10
    /// Background tabs used within this time are spared by the tab-count and memory limits.
    public static let recentGrace: TimeInterval = 5 * 60

    public var searchEngineID = "google"
    /// Empty = the search engine's home page.
    public var homePage = ""
    public var sleepAfterMinutes = 5
    public var dozeAfterMinutes = 1
    public var maxLoadedTabs = 5
    public var memoryBudgetPercent = 25
    public var protectedTabs = 2
    /// Upgrade http:// to https:// and warn before loading a site without HTTPS.
    public var httpsOnly = false
    /// Remove tracking parameters (utm_*, fbclid, gclid, ...) from opened and copied addresses.
    public var stripsTrackingParameters = true
    /// Ask before quitting when several tabs are open or downloads are running.
    public var confirmsQuit = true
    /// On launch, bring back the windows and tabs from last time instead of opening a new tab.
    public var restoresSession = false
    /// Offer the page in the active normal window to the user's other Apple devices (Handoff).
    /// Never used in private windows.
    public var handoffEnabled = true
    /// Memory Saver exceptions: tabs of these sites (and subdomains) never sleep.
    public private(set) var keepAwakeSites: [String] = []
    /// Bookmarks bar under the toolbar (View > Show Bookmarks Bar, ⇧⌘B).
    public var showsBookmarksBar = true
    /// Sync encrypted browser data through the user's iCloud account.
    public var syncEnabled = false
    /// Local path to a user-selected cloud-drive folder. Never copied into the sync snapshot.
    public var syncFolderPath = ""
    /// Security-scoped permission for the selected folder. Local to this Mac.
    public var syncFolderBookmark: Data?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case searchEngineID, homePage, sleepAfterMinutes, maxLoadedTabs, httpsOnly, keepAwakeSites, showsBookmarksBar,
             syncEnabled
        case syncFolderPath, syncFolderBookmark, dozeAfterMinutes, memoryBudgetPercent, protectedTabs
        case stripsTrackingParameters, confirmsQuit, restoresSession, handoffEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrowserPreferences()
        searchEngineID = try c.decodeIfPresent(String.self, forKey: .searchEngineID) ?? d.searchEngineID
        homePage = try c.decodeIfPresent(String.self, forKey: .homePage) ?? d.homePage
        sleepAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepAfterMinutes) ?? d.sleepAfterMinutes
        dozeAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .dozeAfterMinutes) ?? d.dozeAfterMinutes
        maxLoadedTabs = try c.decodeIfPresent(Int.self, forKey: .maxLoadedTabs) ?? d.maxLoadedTabs
        memoryBudgetPercent = try c.decodeIfPresent(Int.self, forKey: .memoryBudgetPercent) ?? d.memoryBudgetPercent
        protectedTabs = try c.decodeIfPresent(Int.self, forKey: .protectedTabs) ?? d.protectedTabs
        httpsOnly = try c.decodeIfPresent(Bool.self, forKey: .httpsOnly) ?? d.httpsOnly
        stripsTrackingParameters = try c.decodeIfPresent(Bool.self, forKey: .stripsTrackingParameters)
            ?? d.stripsTrackingParameters
        confirmsQuit = try c.decodeIfPresent(Bool.self, forKey: .confirmsQuit) ?? d.confirmsQuit
        restoresSession = try c.decodeIfPresent(Bool.self, forKey: .restoresSession) ?? d.restoresSession
        handoffEnabled = try c.decodeIfPresent(Bool.self, forKey: .handoffEnabled) ?? d.handoffEnabled
        keepAwakeSites = try c.decodeIfPresent([String].self, forKey: .keepAwakeSites) ?? d.keepAwakeSites
        showsBookmarksBar = try c.decodeIfPresent(Bool.self, forKey: .showsBookmarksBar) ?? d.showsBookmarksBar
        syncEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? d.syncEnabled
        syncFolderPath = try c.decodeIfPresent(String.self, forKey: .syncFolderPath) ?? d.syncFolderPath
        syncFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .syncFolderBookmark)
    }

    public var searchEngine: SearchEngine { SearchEngine.engine(id: searchEngineID) }

    /// Page for new tabs and new windows.
    public var homeURL: URL {
        let text = homePage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return searchEngine.homeURL }
        return AddressParser.url(from: text, searchTemplate: searchEngine.searchTemplate) ?? searchEngine.homeURL
    }

    /// Policy using the Settings memory limit (share of this Mac's RAM).
    public func hibernationPolicy(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> HibernationPolicy {
        hibernationPolicy(memoryBudget: HibernationPolicy.memoryBudget(percent: memoryBudgetPercent,
                                                                       physicalMemory: physicalMemory))
    }

    public func hibernationPolicy(memoryBudget: UInt64?) -> HibernationPolicy {
        let minutes = max(0, sleepAfterMinutes)
        let doze = max(0, dozeAfterMinutes)
        let loadedLimit = min(max(maxLoadedTabs, Self.maxLoadedTabRange.lowerBound), Self.maxLoadedTabRange.upperBound)
        let gracedLimit = min(max(protectedTabs, Self.protectedTabRange.lowerBound), Self.protectedTabRange.upperBound)
        return HibernationPolicy(idleTimeout: minutes == 0 ? .infinity : TimeInterval(minutes * 60),
                                 // 0 means no limit for both tab counts.
                                 maxLoadedTabs: loadedLimit == 0 ? .max : loadedLimit,
                                 memoryBudget: memoryBudget,
                                 // A tab you just left stays loaded, so going straight back doesn't reload it.
                                 recentGrace: Self.recentGrace,
                                 dozeAfter: doze == 0 ? .infinity : TimeInterval(doze * 60),
                                 maxGracedTabs: gracedLimit == 0 ? .max : gracedLimit)
    }

    // MARK: Memory Saver exceptions

    public func keepsAwake(host: String) -> Bool {
        let sites = Set(keepAwakeSites)
        return SiteSettings.candidates(for: host).contains(where: sites.contains)
    }

    /// Accepts "example.com", "https://www.example.com/path", etc. Returns the stored site, or nil
    /// when the text isn't a site or is already in the list.
    @discardableResult
    public mutating func addKeepAwakeSite(_ text: String) -> String? {
        guard let site = Self.siteKey(from: text), !keepAwakeSites.contains(site) else { return nil }
        keepAwakeSites.append(site)
        keepAwakeSites.sort()
        return site
    }

    public mutating func removeKeepAwakeSite(_ site: String) {
        keepAwakeSites.removeAll { $0 == site }
    }

    static func siteKey(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let host = trimmed.contains("://") ? URL(string: trimmed)?.host : URL(string: "https://" + trimmed)?.host
        guard let host, !host.isEmpty else { return nil }
        let key = SiteSettings.key(for: host)
        return key.isEmpty ? nil : key
    }
}
