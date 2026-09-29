import Foundation

/// One row in the address bar's suggestion list.
public struct AddressSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case history, bookmark }

    public var kind: Kind
    public var url: URL
    public var title: String

    public init(kind: Kind, url: URL, title: String) {
        self.kind = kind
        self.url = url
        self.title = title
    }
}

/// Ranks history and bookmarks for the text typed in the address bar, like Safari/Chrome:
/// address-prefix matches first, then matches at the start of a word, then anywhere; ties broken
/// by how often and how recently a page was visited.
public enum AddressSuggester {
    public static func suggestions(for rawQuery: String, history: [HistoryEntry], bookmarks: [Bookmark],
                                   now: Date = Date(), limit: Int = 6) -> [AddressSuggestion] {
        let query = stripPrefixes(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }

        // One candidate per URL; a bookmarked page that is also in history keeps its visit stats.
        struct Candidate { var title: String; var visits: Int; var date: Date; var isBookmark: Bool }
        var candidates: [URL: Candidate] = [:]
        for entry in history where HistoryStore.isRecordable(entry.url) {
            candidates[entry.url] = Candidate(title: entry.title, visits: entry.visitCount,
                                              date: entry.lastVisited, isBookmark: false)
        }
        for bookmark in bookmarks {
            if var existing = candidates[bookmark.url] {
                existing.isBookmark = true
                if existing.title.isEmpty { existing.title = bookmark.title }
                candidates[bookmark.url] = existing
            } else {
                candidates[bookmark.url] = Candidate(title: bookmark.title, visits: 0,
                                                     date: bookmark.created, isBookmark: true)
            }
        }

        let scored: [(suggestion: AddressSuggestion, score: Double, date: Date)] = candidates.compactMap { url, c in
            guard let match = matchScore(words: words, query: query, url: url, title: c.title) else { return nil }
            let days = max(0, now.timeIntervalSince(c.date)) / 86_400
            let recency: Double = days < 1 ? 10 : days < 7 ? 6 : days < 30 ? 3 : 0
            let score = match + log2(Double(c.visits) + 1) * 8 + recency + (c.isBookmark ? 15 : 0)
            let suggestion = AddressSuggestion(kind: c.isBookmark ? .bookmark : .history, url: url, title: c.title)
            return (suggestion, score, c.date)
        }
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.suggestion.url.absoluteString < $1.suggestion.url.absoluteString
            }
            .prefix(limit)
            .map(\.suggestion)
    }

    /// nil when the entry doesn't match every typed word.
    static func matchScore(words: [String], query: String, url: URL, title: String) -> Double? {
        let address = stripPrefixes(url.absoluteString.lowercased())
        let lowerTitle = title.lowercased()
        let haystack = lowerTitle + " " + address
        guard words.allSatisfy(haystack.contains) else { return nil }

        if address.hasPrefix(query) {
            // Among prefix matches, shorter addresses (the site root) come first.
            return 100 - min(15, Double(address.count) / 8)
        }
        if words.count == 1 {
            let word = words[0]
            let host = stripPrefixes(url.host?.lowercased() ?? "")
            let pathParts = url.path.lowercased().split(separator: "/")
            if host.split(separator: ".").contains(where: { $0.hasPrefix(word) })
                || pathParts.contains(where: { $0.hasPrefix(word) }) {
                return 60
            }
        }
        let titleWords = lowerTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 45 }
        return 20
    }

    /// "https://www.example.com" and "example.com" should match the same way.
    public static func stripPrefixes(_ text: String) -> String {
        var result = Substring(text)
        for scheme in ["https://", "http://"] where result.hasPrefix(scheme) {
            result = result.dropFirst(scheme.count)
        }
        if result.hasPrefix("www.") { result = result.dropFirst(4) }
        return String(result)
    }
}
