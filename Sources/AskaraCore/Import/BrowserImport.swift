import Foundation

/// Bookmarks read from another browser, split like Chrome: bookmarks bar and everything else.
public struct ImportedBookmarks: Equatable {
    public var bar: [BookmarkNode]
    public var other: [BookmarkNode]

    public init(bar: [BookmarkNode] = [], other: [BookmarkNode] = []) {
        self.bar = bar
        self.other = other
    }

    public var count: Int { (bar + other).reduce(0) { $0 + $1.bookmarkCount } }
}

/// A page visit read from another browser's history.
public struct ImportedVisit: Equatable {
    public var url: URL
    public var title: String
    public var lastVisited: Date
    public var visitCount: Int

    public init(url: URL, title: String, lastVisited: Date, visitCount: Int) {
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
        self.visitCount = max(1, visitCount)
    }
}

/// Parsers for other browsers' files. Pure functions so they can be tested without the browsers.
public enum BrowserImport {
    // MARK: Chrome

    /// Chrome's `Bookmarks` file (JSON). Timestamps are microseconds since 1601-01-01.
    public static func chromeBookmarks(from data: Data) throws -> ImportedBookmarks {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func nodes(_ value: Any?) -> [BookmarkNode] {
            guard let list = (value as? [String: Any])?["children"] as? [[String: Any]] else { return [] }
            return list.compactMap(node)
        }
        func node(_ item: [String: Any]) -> BookmarkNode? {
            let title = item["name"] as? String ?? ""
            let created = chromeDate(item["date_added"])
            switch item["type"] as? String {
            case "url":
                guard let text = item["url"] as? String, let url = URL(string: text) else { return nil }
                return .bookmark(url: url, title: title, created: created)
            case "folder":
                return .folder(title, children: nodes(item), created: created)
            default:
                return nil
            }
        }
        // "other" and "synced" (mobile) both go to Other Bookmarks.
        return ImportedBookmarks(bar: nodes(roots["bookmark_bar"]),
                                 other: nodes(roots["other"]) + nodes(roots["synced"]))
    }

    /// Chrome's WebKit-epoch timestamps: microseconds since 1601-01-01 UTC.
    public static func chromeDate(_ value: Any?) -> Date {
        let micros: Double
        if let text = value as? String, let number = Double(text) { micros = number }
        else if let number = value as? NSNumber { micros = number.doubleValue }
        else { return Date() }
        guard micros > 0 else { return Date() }
        return Date(timeIntervalSince1970: micros / 1_000_000 - 11_644_473_600)
    }

    // MARK: Safari

    /// Safari's `Bookmarks.plist`. The Reading List is skipped (it's a to-read queue, not bookmarks).
    public static func safariBookmarks(from data: Data) throws -> ImportedBookmarks {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func node(_ item: [String: Any]) -> BookmarkNode? {
            switch item["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let text = item["URLString"] as? String, let url = URL(string: text) else { return nil }
                let title = (item["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                return .bookmark(url: url, title: title)
            case "WebBookmarkTypeList":
                let children = (item["Children"] as? [[String: Any]] ?? []).compactMap(node)
                return .folder(item["Title"] as? String ?? "", children: children)
            default:
                return nil // proxies (History), separators
            }
        }
        var result = ImportedBookmarks()
        for child in root["Children"] as? [[String: Any]] ?? [] {
            let title = child["Title"] as? String
            if title == "com.apple.ReadingList" { continue }
            if title == "BookmarksBar" {
                result.bar += (child["Children"] as? [[String: Any]] ?? []).compactMap(node)
            } else if title == "BookmarksMenu" {
                result.other += (child["Children"] as? [[String: Any]] ?? []).compactMap(node)
            } else if let node = node(child) {
                result.other.append(node)
            }
        }
        return result
    }

    /// Safari history times: seconds since 2001-01-01 (Core Foundation reference date).
    public static func safariDate(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    // MARK: HTML export (any browser)

    /// "Netscape bookmark file" exported by Safari (File > Export > Bookmarks), Chrome, Firefox, Edge.
    /// A folder whose `<H3>` carries PERSONAL_TOOLBAR_FOLDER is the bookmarks bar.
    public static func htmlBookmarks(from data: Data) -> ImportedBookmarks {
        let html = String(decoding: data, as: UTF8.self)
        // Tokens: <DT><H3 ...>Folder</H3>, <DT><A HREF="..." ADD_DATE="...">Title</A>, <DL>, </DL>.
        let pattern = #"<H3([^>]*)>(.*?)</H3>|<A\s([^>]*)>(.*?)</A>|<DL>|</DL>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return ImportedBookmarks() }

        struct Level { var nodes: [BookmarkNode] = []; var title: String?; var isBar = false; var created = Date() }
        var stack = [Level()]
        var pending: Level?
        var bar: [BookmarkNode]?
        let ns = html as NSString

        func text(_ range: NSRange) -> String {
            range.location == NSNotFound ? "" : decodeEntities(ns.substring(with: range))
        }
        func attribute(_ name: String, in attrs: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: name + #"\s*=\s*"([^"]*)""#, options: .caseInsensitive),
                  let m = r.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
                  let range = Range(m.range(at: 1), in: attrs) else { return nil }
            return decodeEntities(String(attrs[range]))
        }
        func date(_ attrs: String) -> Date {
            attribute("ADD_DATE", in: attrs).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
        }

        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range).uppercased()
            if match.range(at: 2).location != NSNotFound {
                let attrs = text(match.range(at: 1))
                pending = Level(title: text(match.range(at: 2)),
                                isBar: attrs.uppercased().contains("PERSONAL_TOOLBAR_FOLDER"), created: date(attrs))
            } else if match.range(at: 4).location != NSNotFound {
                let attrs = ns.substring(with: match.range(at: 3))
                guard let href = attribute("HREF", in: attrs), let url = URL(string: href) else { continue }
                stack[stack.count - 1].nodes.append(.bookmark(url: url, title: text(match.range(at: 4)), created: date(attrs)))
            } else if token == "<DL>" {
                // The first <DL> is the file's root list; later ones open the folder named just before.
                if let folder = pending { stack.append(folder); pending = nil } else if stack.count > 1 || !stack[0].nodes.isEmpty {
                    stack.append(Level(title: ""))
                }
            } else if token == "</DL>", stack.count > 1 {
                let level = stack.removeLast()
                if level.isBar, bar == nil {
                    bar = level.nodes
                } else {
                    stack[stack.count - 1].nodes.append(.folder(level.title ?? "", children: level.nodes, created: level.created))
                }
            }
        }
        while stack.count > 1 {
            let level = stack.removeLast()
            stack[stack.count - 1].nodes.append(.folder(level.title ?? "", children: level.nodes, created: level.created))
        }
        // Safari's export wraps everything in a folder called "Favorites"/"Bookmarks Bar" without the attribute;
        // with no marked bar folder, everything goes to Other Bookmarks.
        return ImportedBookmarks(bar: bar ?? [], other: stack[0].nodes)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension HistoryStore {
    /// Merges visits from another browser. Existing entries keep the newest date and add the counts.
    /// Returns the number of pages added or updated.
    @discardableResult
    public mutating func importVisits(_ visits: [ImportedVisit]) -> Int {
        var byURL: [URL: HistoryEntry] = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0
        for visit in visits where Self.isRecordable(visit.url) {
            changed += 1
            if var entry = byURL[visit.url] {
                entry.visitCount += visit.visitCount
                if visit.lastVisited > entry.lastVisited { entry.lastVisited = visit.lastVisited }
                if entry.title.isEmpty { entry.title = visit.title }
                byURL[visit.url] = entry
            } else {
                byURL[visit.url] = HistoryEntry(url: visit.url, title: visit.title,
                                                lastVisited: visit.lastVisited, visitCount: visit.visitCount)
            }
        }
        replaceEntries(Array(byURL.values))
        return changed
    }
}
