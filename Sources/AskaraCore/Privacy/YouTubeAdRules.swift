import Foundation

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
    public static let selectors: [String] = [
        "#\(probeID)",
        "#masthead-ad",
        "#player-ads",
        "ytd-ad-slot-renderer",
        "ytd-in-feed-ad-layout-renderer",
        "ytd-banner-promo-renderer",
        "ytd-statement-banner-renderer",
        "ytd-display-ad-renderer",
        "ytd-promoted-sparkles-web-renderer",
        "ytd-promoted-video-renderer",
        "ytd-companion-slot-renderer",
        "ytd-player-legacy-desktop-watch-ads-renderer",
        "ytd-engagement-panel-section-list-renderer[target-id=\"engagement-panel-ads\"]",
        ".ytp-ad-overlay-container",
        ".ytp-ad-image-overlay",
    ]

    /// Rules in WKContentRuleList format. `exclusions` are `unless-top-url` patterns.
    public static func rules(exclusions: [String]) -> [[String: Any]] {
        selectors.map { selector in
            var trigger: [String: Any] = ["url-filter": urlFilter]
            if !exclusions.isEmpty { trigger["unless-top-url"] = exclusions }
            return [
                "trigger": trigger,
                "action": ["type": "css-display-none", "selector": selector],
            ]
        }
    }
}
