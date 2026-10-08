import Foundation

/// Builds a `curl` command that repeats the page request (Develop > Copy as cURL).
public enum CurlCommand {
    public struct Cookie: Equatable, Sendable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let isSecure: Bool

        public init(name: String, value: String, domain: String, path: String, isSecure: Bool) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.isSecure = isSecure
        }
    }

    public static func make(url: URL, userAgent: String?, cookies: [Cookie]) -> String {
        var parts = ["curl", quote(url.absoluteString)]
        if let userAgent, !userAgent.isEmpty { parts += ["-H", quote("User-Agent: \(userAgent)")] }
        let sent = cookies.filter { matches($0, url: url) }
            // Longer paths first, like browsers (RFC 6265 5.4).
            .sorted { $0.path.count > $1.path.count }
        if !sent.isEmpty {
            parts += ["-H", quote("Cookie: " + sent.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))]
        }
        parts.append("--compressed")
        return parts.joined(separator: " ")
    }

    /// RFC 6265 domain and path matching, plus the Secure flag.
    public static func matches(_ cookie: Cookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        var domain = cookie.domain.lowercased()
        let includesSubdomains = domain.hasPrefix(".")
        while domain.hasPrefix(".") { domain.removeFirst() }
        guard host == domain || (includesSubdomains && host.hasSuffix("." + domain)) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return requestPath.count == cookiePath.count || cookiePath.hasSuffix("/")
            || requestPath.dropFirst(cookiePath.count).first == "/"
    }

    /// Single-quoted for POSIX shells: `'` becomes `'\''`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
