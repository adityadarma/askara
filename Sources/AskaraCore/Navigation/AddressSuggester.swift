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
                                   now: Date = Date(), limit: Int = 6,
                                   isCancelled: () -> Bool = { false }) -> [AddressSuggestion] {
        let query = stripPrefixes(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }

        // One candidate per URL; a bookmarked page that is also in history keeps its visit stats.
        struct Candidate { var title: String; var visits: Int; var date: Date; var isBookmark: Bool }
        var candidates: [URL: Candidate] = [:]
        for (index, entry) in history.enumerated() where HistoryStore.isRecordable(entry.url) {
            if index.isMultiple(of: 128), isCancelled() { return [] }
            candidates[entry.url] = Candidate(title: entry.title, visits: entry.visitCount,
                                              date: entry.lastVisited, isBookmark: false)
        }
        for (index, bookmark) in bookmarks.enumerated() {
            if index.isMultiple(of: 128), isCancelled() { return [] }
            if var existing = candidates[bookmark.url] {
                existing.isBookmark = true
                if existing.title.isEmpty { existing.title = bookmark.title }
                candidates[bookmark.url] = existing
            } else {
                candidates[bookmark.url] = Candidate(title: bookmark.title, visits: 0,
                                                     date: bookmark.created, isBookmark: true)
            }
        }

        typealias Scored = (suggestion: AddressSuggestion, score: Double, date: Date)
        func ranksBefore(_ lhs: Scored, _ rhs: Scored) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.suggestion.url.absoluteString < rhs.suggestion.url.absoluteString
        }

        // The UI requests only six rows. Keep a bounded sorted top-N instead of allocating and
        // sorting every match (history alone can contain 5,000 entries).
        var best: [Scored] = []
        best.reserveCapacity(min(limit, candidates.count))
        for (index, element) in candidates.enumerated() {
            if index.isMultiple(of: 128), isCancelled() { return [] }
            let (url, c) = element
            guard let match = matchScore(words: words, query: query, url: url, title: c.title) else { continue }
            let days = max(0, now.timeIntervalSince(c.date)) / 86_400
            let recency: Double = days < 1 ? 10 : days < 7 ? 6 : days < 30 ? 3 : 0
            let score = match + log2(Double(c.visits) + 1) * 8 + recency + (c.isBookmark ? 15 : 0)
            let suggestion = AddressSuggestion(kind: c.isBookmark ? .bookmark : .history, url: url, title: c.title)
            let scored: Scored = (suggestion, score, c.date)
            let insertion = best.firstIndex { ranksBefore(scored, $0) } ?? best.endIndex
            guard insertion < limit else { continue }
            best.insert(scored, at: insertion)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.suggestion)
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
