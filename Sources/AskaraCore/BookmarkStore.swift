import Foundation

/// Flat view of one bookmarked page, used by search, address suggestions, and the Library list.
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

/// A bookmark (has a URL) or a folder (has children).
public struct BookmarkNode: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    /// nil for folders.
    public var url: URL?
    public var created: Date
    /// Folder contents; nil for bookmarks.
    public var children: [BookmarkNode]?

    public var isFolder: Bool { url == nil }

    public static func bookmark(url: URL, title: String, created: Date = Date()) -> BookmarkNode {
        BookmarkNode(id: UUID(), title: title, url: url, created: created, children: nil)
    }

    public static func folder(_ title: String, children: [BookmarkNode] = [], created: Date = Date()) -> BookmarkNode {
        BookmarkNode(id: UUID(), title: title, url: nil, created: created, children: children)
    }

    /// Number of bookmarks inside (all levels).
    public var bookmarkCount: Int {
        isFolder ? (children ?? []).reduce(0) { $0 + $1.bookmarkCount } : 1
    }
}

/// Where a bookmark or folder lives.
public enum BookmarkContainer: Hashable, Sendable {
    /// The bookmarks bar under the toolbar.
    case bar
    /// "Other Bookmarks": shown in the Bookmarks menu only.
    case other
    case folder(UUID)
}

/// Bookmarks in folders, like Chrome: the bookmarks bar plus "Other Bookmarks".
/// One bookmark per URL, so the star button can simply add or remove it.
public struct BookmarkStore: Codable, Equatable {
    public private(set) var bar: [BookmarkNode] = []
    public private(set) var other: [BookmarkNode] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case bar, other, bookmarks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.bar) || c.contains(.other) {
            bar = try c.decodeIfPresent([BookmarkNode].self, forKey: .bar) ?? []
            other = try c.decodeIfPresent([BookmarkNode].self, forKey: .other) ?? []
        } else {
            // Files from before folders existed: a flat list. It goes on the bar, so it stays visible.
            let old = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
            bar = old.map { BookmarkNode(id: $0.id, title: $0.title, url: $0.url, created: $0.created, children: nil) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bar, forKey: .bar)
        try c.encode(other, forKey: .other)
    }

    // MARK: - Reading

    /// Every bookmarked page, bar first, in folder order.
    public var bookmarks: [Bookmark] {
        var result: [Bookmark] = []
        func walk(_ nodes: [BookmarkNode]) {
            for node in nodes {
                if let url = node.url {
                    result.append(Bookmark(id: node.id, url: url, title: node.title, created: node.created))
                } else {
                    walk(node.children ?? [])
                }
            }
        }
        walk(bar)
        walk(other)
        return result
    }

    public func contains(_ url: URL) -> Bool { bookmarks.contains { $0.url == url } }

    public func children(of container: BookmarkContainer) -> [BookmarkNode] {
        switch container {
        case .bar: return bar
        case .other: return other
        case .folder(let id): return node(id)?.children ?? []
        }
    }

    public func node(_ id: UUID) -> BookmarkNode? {
        func find(_ nodes: [BookmarkNode]) -> BookmarkNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(bar) ?? find(other)
    }

    /// The bookmark saved for a page, if any.
    public func node(for url: URL) -> BookmarkNode? {
        bookmarks.first { $0.url == url }.flatMap { node($0.id) }
    }

    /// Parent container and position of a node.
    public func location(of id: UUID) -> (container: BookmarkContainer, index: Int)? {
        func find(_ nodes: [BookmarkNode], in container: BookmarkContainer) -> (BookmarkContainer, Int)? {
            for (index, node) in nodes.enumerated() {
                if node.id == id { return (container, index) }
                if node.isFolder, let found = find(node.children ?? [], in: .folder(node.id)) { return found }
            }
            return nil
        }
        return find(bar, in: .bar) ?? find(other, in: .other)
    }

    /// All places a bookmark can go, in display order, with nesting depth (for folder pickers).
    public func containers() -> [(container: BookmarkContainer, title: String?, depth: Int)] {
        var result: [(BookmarkContainer, String?, Int)] = []
        func walk(_ nodes: [BookmarkNode], depth: Int) {
            for node in nodes where node.isFolder {
                result.append((.folder(node.id), node.title, depth))
                walk(node.children ?? [], depth: depth + 1)
            }
        }
        result.append((.bar, nil, 0))
        walk(bar, depth: 1)
        result.append((.other, nil, 0))
        walk(other, depth: 1)
        return result
    }

    /// Folder names from the root, e.g. [.bar] + ["Work", "Docs"]. Titles for bar/other are supplied by the UI.
    public func path(of container: BookmarkContainer, barTitle: String, otherTitle: String) -> String {
        switch container {
        case .bar: return barTitle
        case .other: return otherTitle
        case .folder(let id):
            guard let folder = node(id), let parent = location(of: id)?.container else { return "" }
            return path(of: parent, barTitle: barTitle, otherTitle: otherTitle) + " / " + folder.title
        }
    }

    // MARK: - Editing

    @discardableResult
    public mutating func add(url: URL, title: String, to container: BookmarkContainer = .bar,
                             at index: Int? = nil) -> Bookmark? {
        guard !contains(url) else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = BookmarkNode.bookmark(url: url, title: clean.isEmpty ? (url.host ?? url.absoluteString) : clean)
        guard insert(node, into: container, at: index) else { return nil }
        return Bookmark(id: node.id, url: url, title: node.title, created: node.created)
    }

    @discardableResult
    public mutating func addFolder(title: String, to container: BookmarkContainer = .bar, at index: Int? = nil) -> UUID? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let folder = BookmarkNode.folder(clean)
        return insert(folder, into: container, at: index) ? folder.id : nil
    }

    public mutating func remove(url: URL) {
        func strip(_ nodes: inout [BookmarkNode]) {
            nodes.removeAll { $0.url == url }
            for i in nodes.indices where nodes[i].children != nil { strip(&nodes[i].children!) }
        }
        strip(&bar)
        strip(&other)
    }

    /// Removes a bookmark, or a folder with everything in it.
    @discardableResult
    public mutating func remove(id: UUID) -> BookmarkNode? {
        Self.take(id, from: &bar) ?? Self.take(id, from: &other)
    }

    public mutating func rename(id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(id) { $0.title = clean }
    }

    /// Changes a bookmark's address. Fails if another bookmark already has it.
    @discardableResult
    public mutating func setURL(id: UUID, to url: URL) -> Bool {
        guard let current = node(id), !current.isFolder else { return false }
        if current.url == url { return true }
        guard !contains(url) else { return false }
        update(id) { $0.url = url }
        return true
    }

    /// Moves a node into a container at an index (in the container's order before the move).
    /// A folder can't go inside itself.
    @discardableResult
    public mutating func move(id: UUID, to container: BookmarkContainer, at index: Int? = nil) -> Bool {
        guard let from = location(of: id) else { return false }
        if case .folder(let target) = container {
            guard let targetFolder = node(target), targetFolder.isFolder, target != id,
                  !Self.contains(target, in: node(id)?.children ?? []) else { return false }
        }
        var index = index
        if let i = index, from.container == container, from.index < i { index = i - 1 }
        guard let moved = remove(id: id) else { return false }
        if insert(moved, into: container, at: index) { return true }
        // Shouldn't happen (target checked above), but never lose the node.
        insert(moved, into: from.container, at: from.index)
        return false
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

    // MARK: - Import

    /// Adds imported bookmarks into a container. Pages that are already bookmarked are skipped,
    /// and folders left empty are dropped. Returns the number of bookmarks added.
    @discardableResult
    public mutating func importNodes(_ nodes: [BookmarkNode], into container: BookmarkContainer) -> Int {
        var known = Set(bookmarks.map(\.url))
        var added = 0
        func clean(_ list: [BookmarkNode]) -> [BookmarkNode] {
            list.compactMap { node in
                if let url = node.url {
                    guard HistoryStore.isRecordable(url), known.insert(url).inserted else { return nil }
                    added += 1
                    let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .bookmark(url: url, title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                                     created: node.created)
                }
                let children = clean(node.children ?? [])
                return children.isEmpty ? nil : .folder(node.title, children: children, created: node.created)
            }
        }
        let cleaned = clean(nodes)
        guard !cleaned.isEmpty else { return 0 }
        for node in cleaned { insert(node, into: container, at: nil) }
        return added
    }

    /// Imports another browser's bookmarks, like Chrome: onto the bar if it's empty, otherwise into
    /// one folder on the bar. Returns the number of bookmarks added.
    @discardableResult
    public mutating func importBrowser(_ imported: ImportedBookmarks, folderTitle: String) -> Int {
        if bar.isEmpty {
            var added = importNodes(imported.bar, into: .bar)
            if !imported.other.isEmpty {
                added += importNodes([.folder(folderTitle, children: imported.other)], into: .other)
            }
            return added
        }
        return importNodes([.folder(folderTitle, children: imported.bar + imported.other)], into: .bar)
    }

    // MARK: - Helpers

    @discardableResult
    private mutating func insert(_ node: BookmarkNode, into container: BookmarkContainer, at index: Int?) -> Bool {
        func put(_ list: inout [BookmarkNode]) {
            list.insert(node, at: min(max(0, index ?? list.count), list.count))
        }
        switch container {
        case .bar: put(&bar)
        case .other: put(&other)
        case .folder(let id):
            return Self.modifyFolder(id, in: &bar, put) || Self.modifyFolder(id, in: &other, put)
        }
        return true
    }

    private mutating func update(_ id: UUID, _ change: (inout BookmarkNode) -> Void) {
        func apply(_ nodes: inout [BookmarkNode]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id { change(&nodes[i]); return true }
                if nodes[i].children != nil, apply(&nodes[i].children!) { return true }
            }
            return false
        }
        if !apply(&bar) { _ = apply(&other) }
    }

    private static func modifyFolder(_ id: UUID, in nodes: inout [BookmarkNode],
                                     _ body: (inout [BookmarkNode]) -> Void) -> Bool {
        for i in nodes.indices where nodes[i].isFolder {
            if nodes[i].id == id {
                body(&nodes[i].children!)
                return true
            }
            if modifyFolder(id, in: &nodes[i].children!, body) { return true }
        }
        return false
    }

    private static func take(_ id: UUID, from nodes: inout [BookmarkNode]) -> BookmarkNode? {
        if let index = nodes.firstIndex(where: { $0.id == id }) { return nodes.remove(at: index) }
        for i in nodes.indices where nodes[i].children != nil {
            if let found = take(id, from: &nodes[i].children!) { return found }
        }
        return nil
    }

    private static func contains(_ id: UUID, in nodes: [BookmarkNode]) -> Bool {
        nodes.contains { $0.id == id || contains(id, in: $0.children ?? []) }
    }
}
