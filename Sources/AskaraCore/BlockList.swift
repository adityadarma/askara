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

    /// Built-in and downloaded lists merged, deduplicated and sorted.
    public static func merged(with downloaded: [String]) -> [String] {
        Array(Set(domains).union(downloaded)).sorted()
    }

    /// JSON rule list ready to be compiled by WKContentRuleListStore.
    public static func contentRuleListJSON(domains: [String] = domains, excludingSites: [String] = []) -> String {
        let exclusions = excludingSites.map { domain in
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return "^https?://([^/]*\\.)?\(escaped)(?::[0-9]+)?/"
        }
        let rules: [[String: Any]] = domains.map { domain in
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
        // Rules always serialize since they contain only String/Array/Dictionary.
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
