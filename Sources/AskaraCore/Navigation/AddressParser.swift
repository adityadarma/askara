import Foundation

/// Turns address bar text into a URL: a direct address or a search.
public enum AddressParser {
    public static let defaultSearchTemplate = "https://www.google.com/search?q=%@"
    public static let defaultHomeURL = URL(string: "https://www.google.com")!

    private static let allowedSchemes: Set<String> = ["http", "https", "file", "about"]

    public static func url(from rawInput: String,
                           searchTemplate: String = defaultSearchTemplate) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // Already has a known scheme, use as is.
        if let url = URL(string: input),
           let scheme = url.scheme?.lowercased(),
           allowedSchemes.contains(scheme),
           scheme == "about" || scheme == "file" || url.host != nil {
            return url
        }

        let hasSpace = input.contains(" ")
        let lower = input.lowercased()

        // localhost usually has no TLS.
        if !hasSpace, lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") {
            return URL(string: "http://" + input)
        }

        // Looks like a domain (has a dot, no spaces, not at the ends).
        if !hasSpace, input.contains("."), !input.hasPrefix("."), !input.hasSuffix("."),
           let url = URL(string: "http://" + input), url.host != nil {
            // Typed addresses start on http:// so private hosts (.internal, .local, 192.168.x.x) work.
            // Public sites normally redirect to https://; with HTTPS-Only Mode on, the browser upgrades
            // them itself (see HTTPSUpgrade).
            return url
        }

        return searchURL(for: input, template: searchTemplate)
    }

    /// Text shown in the address bar. WebKit always normalizes "https://www.google.com" to
    /// "https://www.google.com/" (it's the same address, not a redirect); like Safari, the lone
    /// trailing slash of a site's root page is hidden. Other paths are shown unchanged.
    public static func displayString(for url: URL?) -> String {
        guard let url else { return "" }
        let text = url.absoluteString
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.path == "/", url.query == nil, url.fragment == nil, text.hasSuffix("/") else { return text }
        return String(text.dropLast())
    }

    public static func searchURL(for query: String,
                                 template: String = defaultSearchTemplate) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: template.replacingOccurrences(of: "%@", with: encoded))
    }
}
