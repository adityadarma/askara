import Foundation

public struct Bookmark: Codable, Equatable, Identifiable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var created: Date

    public init(id: UUID = UUID(), url: URL, title: String, created: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.created = created
    }
}

/// Flat bookmark list, ordered by time added. One bookmark per URL.
public struct BookmarkStore: Codable, Equatable {
    public private(set) var bookmarks: [Bookmark] = []

    public init() {}

    public func contains(_ url: URL) -> Bool { bookmarks.contains { $0.url == url } }

    @discardableResult
    public mutating func add(url: URL, title: String) -> Bookmark? {
        guard !contains(url) else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(url: url, title: clean.isEmpty ? (url.host ?? url.absoluteString) : clean)
        bookmarks.append(bookmark)
        return bookmark
    }

    public mutating func remove(url: URL) { bookmarks.removeAll { $0.url == url } }

    public mutating func remove(id: UUID) { bookmarks.removeAll { $0.id == id } }

    public mutating func rename(id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].title = clean
    }

    /// Adds if missing, removes if present. Returns the final state.
    @discardableResult
    public mutating func toggle(url: URL, title: String) -> Bool {
        if contains(url) {
            remove(url: url)
            return false
        }
        add(url: url, title: title)
        return true
    }
}
