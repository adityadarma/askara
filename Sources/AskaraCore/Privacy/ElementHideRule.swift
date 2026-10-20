import Foundation

/// A user-made rule that hides page elements on one site, written as `site##selector`
/// (for example `example.com##a[href*="ads.example"]`). It becomes a `css-display-none`
/// rule in the content rule list, so it also covers subdomains of the site.
public struct ElementHideRule: Codable, Equatable, Hashable, Sendable {
    public let site: String
    public let selector: String

    public init(site: String, selector: String) {
        self.site = site
        self.selector = selector
    }

    /// The text form shown in Settings and accepted by `parse`.
    public var text: String { "\(site)##\(selector)" }

    /// Keeps the rule list small, so WebKit compilation stays fast.
    public static let maxRules = 500
    public static let maxSelectorLength = 200

    private static let allowedSelectorCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.#[]=\"'*^$~|:>+,()"
    )

    /// Reads one `site##selector` line. The site may be a bare domain or a URL.
    /// Returns nil if either part is invalid.
    public static func parse(_ input: String) -> ElementHideRule? {
        guard let separator = input.range(of: "##") else { return nil }
        guard let site = normalizeSite(String(input[..<separator.lowerBound])) else { return nil }
        let selector = String(input[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSelector(selector) else { return nil }
        return ElementHideRule(site: site, selector: selector)
    }

    /// One rule per line. Invalid lines are skipped; the result is deduplicated and sorted.
    public static func parseAll(_ text: String) -> [ElementHideRule] {
        var seen = Set<ElementHideRule>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard seen.count < maxRules, let rule = parse(String(line)) else { continue }
            seen.insert(rule)
        }
        return seen.sorted { ($0.site, $0.selector) < ($1.site, $1.selector) }
    }

    /// "https://Example.com/path" → "example.com".
    static func normalizeSite(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let end = value.firstIndex(where: { "/?#".contains($0) }) { value = String(value[..<end]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        if value.hasPrefix("*.") { value.removeFirst(2) }
        while value.hasSuffix(".") { value.removeLast() }
        return BlockListParser.isValidDomain(value) ? value : nil
    }

    /// Plain CSS selectors only. WebKit rejects the whole rule list if one selector is invalid,
    /// so this keeps out characters that could break the rule (braces, backslashes, semicolons)
    /// and requires brackets, parentheses and quotes to be balanced.
    public static func isValidSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= maxSelectorLength,
              selector.allSatisfy(allowedSelectorCharacters.contains) else { return false }
        func count(_ character: Character) -> Int { selector.filter { $0 == character }.count }
        return count("[") == count("]") && count("(") == count(")")
            && count("\"").isMultiple(of: 2) && count("'").isMultiple(of: 2)
            && !selector.hasPrefix(",") && !selector.hasSuffix(",")
    }

    /// Rules in WKContentRuleList format. `exclusions` are `unless-top-url` patterns.
    public static func rules(_ hideRules: [ElementHideRule], exclusions: [String]) -> [[String: Any]] {
        hideRules.map { rule in
            let escaped = NSRegularExpression.escapedPattern(for: rule.site)
            var trigger: [String: Any] = ["url-filter": "^https?://([^/]*\\.)?\(escaped)[/:]"]
            if !exclusions.isEmpty { trigger["unless-top-url"] = exclusions }
            return [
                "trigger": trigger,
                "action": ["type": "css-display-none", "selector": rule.selector],
            ]
        }
    }
}
