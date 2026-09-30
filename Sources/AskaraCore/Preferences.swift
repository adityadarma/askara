import Foundation

/// A search engine for the address bar and "Search with…" in the context menu.
public struct SearchEngine: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// `%@` is replaced by the encoded query.
    public let searchTemplate: String
    public let homeURL: URL

    public init(id: String, name: String, searchTemplate: String, homeURL: URL) {
        self.id = id
        self.name = name
        self.searchTemplate = searchTemplate
        self.homeURL = homeURL
    }

    public static let all: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", searchTemplate: AddressParser.defaultSearchTemplate,
                     homeURL: AddressParser.defaultHomeURL),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", searchTemplate: "https://duckduckgo.com/?q=%@",
                     homeURL: URL(string: "https://duckduckgo.com")!),
        SearchEngine(id: "bing", name: "Bing", searchTemplate: "https://www.bing.com/search?q=%@",
                     homeURL: URL(string: "https://www.bing.com")!),
        SearchEngine(id: "brave", name: "Brave Search", searchTemplate: "https://search.brave.com/search?q=%@",
                     homeURL: URL(string: "https://search.brave.com")!),
        SearchEngine(id: "ecosia", name: "Ecosia", searchTemplate: "https://www.ecosia.org/search?q=%@",
                     homeURL: URL(string: "https://www.ecosia.org")!),
        SearchEngine(id: "startpage", name: "Startpage", searchTemplate: "https://www.startpage.com/do/search?q=%@",
                     homeURL: URL(string: "https://www.startpage.com")!),
    ]

    public static func engine(id: String) -> SearchEngine { all.first { $0.id == id } ?? all[0] }

    public func searchURL(for query: String) -> URL? {
        AddressParser.searchURL(for: query, template: searchTemplate)
    }
}

/// User settings (Settings window, ⌘,). Missing keys in the saved file fall back to defaults,
/// so adding a setting never resets the others.
public struct BrowserPreferences: Codable, Equatable, Sendable {
    /// Minutes before a background tab sleeps. 0 = never by time (count and memory limits still apply).
    public static let sleepChoices = [0, 1, 5, 15, 30, 60]
    public static let maxLoadedTabRange = 2...20

    public var searchEngineID = "google"
    /// Empty = the search engine's home page.
    public var homePage = ""
    public var sleepAfterMinutes = 5
    public var maxLoadedTabs = 5
    /// Upgrade http:// to https:// and warn before loading a site without HTTPS.
    public var httpsOnly = false
    /// Memory Saver exceptions: tabs of these sites (and subdomains) never sleep.
    public private(set) var keepAwakeSites: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case searchEngineID, homePage, sleepAfterMinutes, maxLoadedTabs, httpsOnly, keepAwakeSites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrowserPreferences()
        searchEngineID = try c.decodeIfPresent(String.self, forKey: .searchEngineID) ?? d.searchEngineID
        homePage = try c.decodeIfPresent(String.self, forKey: .homePage) ?? d.homePage
        sleepAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepAfterMinutes) ?? d.sleepAfterMinutes
        maxLoadedTabs = try c.decodeIfPresent(Int.self, forKey: .maxLoadedTabs) ?? d.maxLoadedTabs
        httpsOnly = try c.decodeIfPresent(Bool.self, forKey: .httpsOnly) ?? d.httpsOnly
        keepAwakeSites = try c.decodeIfPresent([String].self, forKey: .keepAwakeSites) ?? d.keepAwakeSites
    }

    public var searchEngine: SearchEngine { SearchEngine.engine(id: searchEngineID) }

    /// Page for new tabs and new windows.
    public var homeURL: URL {
        let text = homePage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return searchEngine.homeURL }
        return AddressParser.url(from: text, searchTemplate: searchEngine.searchTemplate) ?? searchEngine.homeURL
    }

    public func hibernationPolicy(memoryBudget: UInt64?) -> HibernationPolicy {
        let minutes = max(0, sleepAfterMinutes)
        return HibernationPolicy(idleTimeout: minutes == 0 ? .infinity : TimeInterval(minutes * 60),
                                 maxLoadedTabs: min(max(maxLoadedTabs, Self.maxLoadedTabRange.lowerBound),
                                                    Self.maxLoadedTabRange.upperBound),
                                 memoryBudget: memoryBudget)
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

/// Upgrades plain HTTP to HTTPS for public sites (HTTPS-Only Mode).
public enum HTTPSUpgrade {
    /// The https:// version of a public http:// URL, or nil when it shouldn't be upgraded.
    public static func upgradedURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host, isPublicHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }

    /// Local names and IP addresses usually have no certificate (routers, dev servers), so they're left alone.
    public static func isPublicHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard host.contains("."), !host.contains(":") else { return false } // single label or IPv6
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false } // IPv4
        let localSuffixes = [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".test", ".invalid"]
        return !localSuffixes.contains { host.hasSuffix($0) }
    }
}
