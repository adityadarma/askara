import Foundation

public struct YouTubeAdRuleSet: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let selectors: [String]
    public let adElementSelectors: [String]
    public let wrapperSelectors: [String]
    public let adKeys: [String]
    public let wrapperKeys: [String]
    public let skipSelectors: [String]

    public init(schemaVersion: Int, revision: Int, selectors: [String], adElementSelectors: [String],
                wrapperSelectors: [String], adKeys: [String], wrapperKeys: [String], skipSelectors: [String]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.selectors = selectors
        self.adElementSelectors = adElementSelectors
        self.wrapperSelectors = wrapperSelectors
        self.adKeys = adKeys
        self.wrapperKeys = wrapperKeys
        self.skipSelectors = skipSelectors
    }

    public static let builtIn = YouTubeAdRuleSet(
        schemaVersion: 1, revision: 1,
        selectors: [
            "#masthead-ad", "#player-ads", "ytd-ad-slot-renderer", "ytd-in-feed-ad-layout-renderer",
            "ytd-search-pyv-renderer", "ytd-banner-promo-renderer", "ytd-statement-banner-renderer",
            "ytd-display-ad-renderer", "ytd-promoted-sparkles-web-renderer",
            "ytd-promoted-sparkles-text-search-renderer", "ytd-promoted-video-renderer",
            "ytd-companion-slot-renderer", "ytd-action-companion-ad-renderer",
            "ytd-video-masthead-ad-v3-renderer", "ytd-player-legacy-desktop-watch-ads-renderer",
            "ytd-engagement-panel-section-list-renderer[target-id=\"engagement-panel-ads\"]",
            ".ytp-ad-player-overlay", ".ytp-ad-player-overlay-layout", ".ytp-ad-overlay-container",
            ".ytp-ad-image-overlay",
        ],
        adElementSelectors: [
            "ytd-ad-slot-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-display-ad-renderer",
            "ytd-search-pyv-renderer", "ytd-promoted-sparkles-web-renderer",
            "ytd-promoted-sparkles-text-search-renderer", "ytd-promoted-video-renderer",
            "ytd-banner-promo-renderer", "ytd-statement-banner-renderer",
            "ytd-video-masthead-ad-v3-renderer",
        ],
        wrapperSelectors: ["ytd-rich-item-renderer", "ytd-rich-section-renderer"],
        adKeys: ["adPlacements", "adSlots", "playerAds", "adBreakHeartbeatParams"],
        wrapperKeys: ["playerResponse", "response", "data"],
        skipSelectors: [
            ".ytp-skip-ad-button", ".ytp-ad-skip-button", ".ytp-ad-skip-button-modern",
            ".ytp-skip-ad-button__text", "button[id^=\"skip-button\"]",
        ]
    )

    /// Remote data can tune the local engine, but cannot change its host or execute code.
    public func validated(minimumRevision: Int = 0) -> YouTubeAdRuleSet? {
        guard schemaVersion == 1, revision >= minimumRevision, revision > 0,
              selectors.count <= 128, adElementSelectors.count <= 64, wrapperSelectors.count <= 16,
              adKeys.count <= 32, wrapperKeys.count <= 16, skipSelectors.count <= 32 else { return nil }
        let dangerous = Set(["*", "html", "body", "ytd-app", "#content", "#page-manager"])
        let selectorGroups = [selectors, adElementSelectors, wrapperSelectors, skipSelectors]
        guard selectorGroups.allSatisfy({ group in
            !group.isEmpty && group.allSatisfy {
                ElementHideRule.isValidSelector($0) && !dangerous.contains($0.lowercased())
            }
        }) else { return nil }
        let keys = adKeys + wrapperKeys
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$-"))
        guard !adKeys.isEmpty, !wrapperKeys.isEmpty, keys.allSatisfy({ key in
            !key.isEmpty && key.count <= 64 && key.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        return YouTubeAdRuleSet(schemaVersion: schemaVersion, revision: revision,
                                selectors: unique(selectors), adElementSelectors: unique(adElementSelectors),
                                wrapperSelectors: unique(wrapperSelectors), adKeys: unique(adKeys),
                                wrapperKeys: unique(wrapperKeys), skipSelectors: unique(skipSelectors))
    }
}

/// Cosmetic YouTube ad rules. YouTube serves ads from its own domains, so domain blocking can't
/// catch them; these rules hide ad elements instead (`css-display-none` in the content rule list).
///
/// The rules also hide a probe element. The YouTube skip script checks whether the probe is hidden,
/// so it only runs where the rule list is active: per-site ad-block exceptions turn both off at once.
public enum YouTubeAdRules {
    /// Element ID the skip script creates to detect whether the rules apply to the page.
    public static let probeID = "askara-yt-adblock-probe"

    /// Matches youtube.com and its subdomains (www, m, music).
    static let urlFilter = "^https?://([^/]*\\.)?youtube\\.com[/:]"

    /// Plain CSS selectors only. WebKit rejects the whole rule list if one selector is invalid,
    /// so the test suite compiles the full list.
    public static let selectors = ["#\(probeID)"] + YouTubeAdRuleSet.builtIn.selectors

    /// Rules in WKContentRuleList format. `exclusions` are `unless-top-url` patterns.
    public static func rules(ruleSet: YouTubeAdRuleSet = .builtIn, exclusions: [String]) -> [[String: Any]] {
        (["#\(probeID)"] + ruleSet.selectors).map { selector in
            var trigger: [String: Any] = ["url-filter": urlFilter]
            if !exclusions.isEmpty { trigger["unless-top-url"] = exclusions }
            return [
                "trigger": trigger,
                "action": ["type": "css-display-none", "selector": selector],
            ]
        }
    }
}
