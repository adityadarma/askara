import Foundation

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
