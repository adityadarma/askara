import Foundation

/// Turns block lists from the internet into a safe-to-use domain list.
/// Supported formats: hosts (`0.0.0.0 ads.com`), one domain per line, and `||ads.com^` (AdBlock).
public enum BlockListParser {
    /// Domain count limit so WebKit compilation stays fast and memory stays small.
    public static let maxDomains = 50_000

    /// Domains never blocked even if listed, so the browser stays usable.
    public static let neverBlock: Set<String> = [
        "localhost", "local", "google.com", "www.google.com", "apple.com", "icloud.com",
        "github.com", "raw.githubusercontent.com", "pgl.yoyo.org",
    ]

    public static func parseDomains(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard result.count < maxDomains else { break }
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            line = Substring(line.trimmingCharacters(in: .whitespaces))
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }

            let candidate: Substring
            if line.hasPrefix("||") {
                // AdBlock: only pure domain rules "||domain^", ignore those with options/paths.
                guard line.hasSuffix("^") else { continue }
                candidate = line.dropFirst(2).dropLast()
            } else {
                let parts = line.split(whereSeparator: \.isWhitespace)
                // hosts: "0.0.0.0 domain" / "127.0.0.1 domain"; otherwise one domain per line.
                candidate = parts.count >= 2 ? parts[1] : parts[0]
            }

            let domain = candidate.lowercased()
            guard isValidDomain(domain), !neverBlock.contains(domain), seen.insert(domain).inserted else { continue }
            result.append(domain)
        }
        return result
    }

    /// Only letters, digits, hyphens, and dots; at least two labels; not an IP address.
    /// This also keeps odd characters out of WebKit rule regex/JSON.
    public static func isValidDomain(_ domain: String) -> Bool {
        guard domain.count <= 253, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy(allowed.contains) else { return false }
        }
        // The last label (TLD) must contain a letter, so "0.0.0.0" is rejected.
        return labels.last?.contains(where: \.isLetter) ?? false
    }
}

/// Block list update metadata, stored on disk.
public struct BlockListMetadata: Codable, Equatable {
    public var lastChecked: Date?
    public var lastUpdated: Date?
    public var etag: String?
    public var lastModified: String?
    public var domainCount: Int

    public init(lastChecked: Date? = nil, lastUpdated: Date? = nil, etag: String? = nil,
                lastModified: String? = nil, domainCount: Int = 0) {
        self.lastChecked = lastChecked
        self.lastUpdated = lastUpdated
        self.etag = etag
        self.lastModified = lastModified
        self.domainCount = domainCount
    }

    /// Check once a day. The source list updates a few times a week.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public func needsCheck(now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= Self.checkInterval || lastChecked > now
    }
}
