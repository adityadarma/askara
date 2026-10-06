import Foundation

/// Removes tracking parameters (utm_*, fbclid, gclid, ...) from web addresses. Only parameters that
/// exist purely for ad/analytics attribution are removed, so pages keep working.
public enum URLCleaner {
    /// Removed when the name matches exactly (case-insensitive).
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "igsh", "li_fat_id", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp",
        "hsctatracking", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "rb_clickid",
        "s_cid", "_openstat", "ga_source", "ga_medium", "ga_campaign", "ga_content", "ga_term",
    ]
    /// Removed when the name starts with one of these (case-insensitive).
    static let trackingPrefixes = ["utm_", "pk_", "mtm_"]

    public static func isTrackingParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return trackingNames.contains(lower) || trackingPrefixes.contains { lower.hasPrefix($0) }
    }

    /// The same address without tracking parameters. Non-web URLs and URLs without tracking
    /// parameters are returned unchanged (byte for byte).
    public static func clean(_ url: URL) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return url }
        let kept = items.filter { !isTrackingParameter($0.name.removingPercentEncoding ?? $0.name) }
        guard kept.count != items.count else { return url }
        // Encoded items are kept as they were, so the rest of the query isn't re-encoded.
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }
}

/// Builds "Copy Link to Highlight" addresses (`#:~:text=`), which browsers scroll to and highlight.
public enum TextFragment {
    /// Short selections are matched exactly; longer ones by their first and last words.
    static let exactLimit = 80
    static let edgeWords = 4

    /// `selection` is the selected text (possibly truncated); `tail` is the end of the full selection,
    /// used when the selection is long. nil when there's no usable text.
    public static func url(for page: URL, selection: String, tail: String? = nil) -> URL? {
        let words = normalizedWords(selection)
        guard !words.isEmpty, var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        let directive: String
        let joined = words.joined(separator: " ")
        if joined.count <= exactLimit, !selection.contains("\n") {
            directive = encode(joined)
        } else {
            let endWords = normalizedWords(tail ?? selection)
            let start = words.prefix(edgeWords).joined(separator: " ")
            let end = endWords.suffix(edgeWords).joined(separator: " ")
            directive = end.isEmpty || words.count <= edgeWords ? encode(joined)
                : encode(start) + "," + encode(end)
        }
        // Any existing fragment is replaced: a text directive points at the selection instead.
        components.percentEncodedFragment = ":~:text=" + directive
        return components.url
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// Percent-encodes everything except ASCII letters, digits, and `._~`. `-`, `,`, and `&` have
    /// meaning in text directives, so they're always encoded; non-ASCII text becomes UTF-8 escapes.
    static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Page links formatted for pasting elsewhere.
public enum LinkFormat {
    /// `[Title](https://…)`. Brackets in the title and parentheses/spaces in the URL are escaped so
    /// the link stays intact; an empty title falls back to the address.
    public static func markdown(title: String, url: URL) -> String {
        let address = url.absoluteString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if text.isEmpty { text = url.absoluteString }
        text = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text)](\(address))"
    }
}

/// Finding tabs to close in bulk.
public enum TabCleanup {
    /// Indices of tabs whose page is already open in another tab. The tab at `preferring` (the
    /// active one) is kept over its duplicates; otherwise the first occurrence is kept. Fragments
    /// (#section) are ignored, so the same page scrolled elsewhere still counts as a duplicate.
    public static func duplicateIndices(urls: [URL?], preferring: Int? = nil) -> [Int] {
        func key(_ url: URL?) -> String? {
            guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.fragment = nil
            return components.url?.absoluteString
        }
        let keys = urls.map(key)
        var keeper: [String: Int] = [:]
        if let preferring, keys.indices.contains(preferring), let k = keys[preferring] { keeper[k] = preferring }
        for (index, k) in keys.enumerated() {
            guard let k, keeper[k] == nil else { continue }
            keeper[k] = index
        }
        return keys.indices.filter { index in keys[index].map { keeper[$0] != index } ?? false }
    }
}
