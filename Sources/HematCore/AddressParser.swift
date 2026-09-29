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

        // localhost / local IPs usually have no TLS.
        if !hasSpace, lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") {
            return URL(string: "http://" + input)
        }

        // Looks like a domain (has a dot, no spaces, not at the ends).
        if !hasSpace, input.contains("."), !input.hasPrefix("."), !input.hasSuffix("."),
           let url = URL(string: "https://" + input), url.host != nil {
            return url
        }

        return searchURL(for: input, template: searchTemplate)
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
