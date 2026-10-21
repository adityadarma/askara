import Foundation

/// Spotify web player ad rules (`open.spotify.com`). Ads are requested from Spotify's own domain, so
/// domain blocking can't catch them. Two kinds of rules:
/// - `block` for the ad-decision endpoints (`/ads/`, `/ad-logic/`);
/// - `css-display-none` for ad slots and upgrade banners.
///
/// Like `YouTubeAdRules`, the rules hide a probe element so the page script runs only where the rule
/// list is active: per-site ad-block exceptions turn both off at once.
public enum SpotifyAdRules {
    /// Element ID the page script creates to detect whether the rules apply to the page.
    public static let probeID = "askara-spotify-adblock-probe"

    /// Matches spotify.com and its subdomains (open, spclient.wg, ...).
    static let urlFilter = "^https?://([^/]*\\.)?spotify\\.com[/:]"

    /// Ad endpoints. WebKit content rules have no alternation, so each path is its own rule.
    static let blockedPaths = ["ads", "ad-logic"]

    /// Plain CSS selectors only. WebKit rejects the whole rule list if one selector is invalid.
    public static let selectors: [String] = [
        "#\(probeID)",
        "[data-testid=\"ad-slot\"]",
        "[data-testid=\"ads-container\"]",
        "[data-testid=\"upgrade-button\"]",
        ".ad-sidebar",
    ]

    /// Rules in WKContentRuleList format. `exclusions` are `unless-top-url` patterns.
    public static func rules(exclusions: [String]) -> [[String: Any]] {
        func trigger(_ filter: String) -> [String: Any] {
            var trigger: [String: Any] = ["url-filter": filter]
            if !exclusions.isEmpty { trigger["unless-top-url"] = exclusions }
            return trigger
        }
        let blocks: [[String: Any]] = blockedPaths.map { path in
            [
                "trigger": trigger("^https?://([^/]*\\.)?spotify\\.com/\(path)/"),
                "action": ["type": "block"],
            ]
        }
        let hides: [[String: Any]] = selectors.map { selector in
            [
                "trigger": trigger(urlFilter),
                "action": ["type": "css-display-none", "selector": selector],
            ]
        }
        return blocks + hides
    }
}
