import Foundation

/// Ad/tracker block list in WKContentRuleList format.
/// Blocking these third-party scripts reduces RAM and CPU per page.
public enum BlockList {
    public static let domains: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "google-analytics.com",
        "googletagmanager.com",
        "googletagservices.com",
        "adservice.google.com",
        "amazon-adsystem.com",
        "adnxs.com",
        "adsrvr.org",
        "criteo.com",
        "criteo.net",
        "taboola.com",
        "outbrain.com",
        "scorecardresearch.com",
        "quantserve.com",
        "hotjar.com",
        "mixpanel.com",
        "segment.io",
        "facebook.net",
        "connect.facebook.net",
        "ads-twitter.com",
        "analytics.tiktok.com",
        "pubmatic.com",
        "rubiconproject.com",
        "openx.net",
        "moatads.com",
        "yieldmo.com",
        "zedo.com",
        "popads.net",
    ]

    /// Manual entries added on first launch (ad networks loaded by wasmarcade.com).
    /// They go into the user's own list, so the user can edit or remove them.
    public static let initialCustomDomains: [String] = [
        "al5sm.com",
        "calwhichherea.com",
        "croppasmotter.com",
        "d2f9q8zryik75d.cloudfront.net",
        "dd133.com",
        "omg10.com",
        "ratwapaleola.com",
        "sothssoapy.com",
        "ueuee.com",
    ]

    /// Built-in and downloaded lists merged, deduplicated and sorted.
    public static func merged(with downloaded: [String]) -> [String] {
        Array(Set(domains).union(downloaded)).sorted()
    }

    /// JSON rule list ready to be compiled by WKContentRuleListStore.
    public static func contentRuleListJSON(domains: [String] = domains, excludingSites: [String] = [],
                                           hiding: [ElementHideRule] = []) -> String {
        let exclusions = excludingSites.map { domain in
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return "^https?://([^/]*\\.)?\(escaped)(?::[0-9]+)?/"
        }
        let domainRules: [[String: Any]] = domains.map { domain in
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            var trigger: [String: Any] = [
                "url-filter": "^https?://([^/]*\\.)?\(escaped)[/:]",
                "load-type": ["third-party"],
            ]
            if !exclusions.isEmpty { trigger["unless-top-url"] = exclusions }
            return [
                "trigger": trigger,
                "action": ["type": "block"],
            ]
        }
        let rules = domainRules + YouTubeAdRules.rules(exclusions: exclusions)
            + SpotifyAdRules.rules(exclusions: exclusions)
            + ElementHideRule.rules(hiding, exclusions: exclusions)
        // Rules always serialize since they contain only String/Array/Dictionary.
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
