import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var title: String
    public var lastVisited: Date
    public var visitCount: Int

    public init(url: URL, title: String, lastVisited: Date, visitCount: Int = 1) {
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = visitCount
    }
}

/// Visit history. One entry per URL (revisits update the entry), count-limited
/// so file and memory stay small.
public struct HistoryStore: Codable, Equatable {
    public private(set) var entries: [HistoryEntry] = []   // newest first
    public var limit: Int

    public init(limit: Int = 5_000) { self.limit = max(1, limit) }

    public static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public mutating func record(url: URL, title: String?, at date: Date = Date()) {
        guard Self.isRecordable(url) else { return }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = entries.firstIndex(where: { $0.url == url }) {
            var entry = entries.remove(at: index)
            entry.lastVisited = date
            entry.visitCount += 1
            if !cleanTitle.isEmpty { entry.title = cleanTitle }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(HistoryEntry(url: url, title: cleanTitle, lastVisited: date), at: 0)
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        }
    }

    /// Updates the title without counting a new visit (titles often arrive after the URL).
    public mutating func updateTitle(_ title: String, for url: URL) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[index].title = clean
    }

    /// Case-insensitive search over title and URL. All words must match.
    public func search(_ query: String, limit: Int = .max) -> [HistoryEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(entries.prefix(limit)) }
        var result: [HistoryEntry] = []
        for entry in entries {
            let haystack = (entry.title + " " + entry.url.absoluteString).lowercased()
            if words.allSatisfy(haystack.contains) {
                result.append(entry)
                if result.count >= limit { break }
            }
        }
        return result
    }

    public mutating func remove(url: URL) { entries.removeAll { $0.url == url } }

    public mutating func clear(since date: Date? = nil) {
        if let date { entries.removeAll { $0.lastVisited >= date } } else { entries.removeAll() }
    }
}
