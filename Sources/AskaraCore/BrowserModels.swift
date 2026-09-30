import Foundation

/// Session snapshot restored when the app is reopened.
/// Tabs are restored asleep: only the active tab loads, the rest wait to be clicked.
public struct SessionState: Codable, Equatable {
    // New fields are optional so session files from older versions still load.
    public struct SavedTab: Codable, Equatable {
        public var url: URL
        public var title: String
        public var isPinned: Bool?
        public var isMuted: Bool?
        public init(url: URL, title: String, isPinned: Bool = false, isMuted: Bool = false) {
            self.url = url
            self.title = title
            self.isPinned = isPinned ? true : nil
            self.isMuted = isMuted ? true : nil
        }
    }

    public struct SavedWindow: Codable, Equatable {
        public var tabs: [SavedTab]
        public var activeIndex: Int
        public init(tabs: [SavedTab], activeIndex: Int) {
            self.tabs = tabs
            self.activeIndex = tabs.isEmpty ? 0 : min(max(0, activeIndex), tabs.count - 1)
        }
    }

    public var windows: [SavedWindow]

    public init(windows: [SavedWindow]) {
        // Windows without tabs are not worth restoring.
        self.windows = windows.filter { !$0.tabs.isEmpty }
    }

    public var isEmpty: Bool { windows.isEmpty }
}

/// Stack of recently closed tabs, for "Reopen Closed Tab" (⌘⇧T).
public struct RecentlyClosed<Item> {
    public private(set) var items: [Item] = []
    public let capacity: Int

    public init(capacity: Int = 20) { self.capacity = max(1, capacity) }

    public mutating func push(_ item: Item) {
        items.append(item)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    public mutating func pop() -> Item? { items.popLast() }

    public var isEmpty: Bool { items.isEmpty }
}

/// Page zoom steps, similar to most browsers.
public enum ZoomLevels {
    public static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    public static func zoomIn(from current: Double) -> Double {
        steps.first { $0 > current + 0.001 } ?? steps.last!
    }

    public static func zoomOut(from current: Double) -> Double {
        steps.last { $0 < current - 0.001 } ?? steps.first!
    }

    public static func label(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }
}

/// Safe download file naming that never overwrites existing files.
public enum DownloadNaming {
    /// Strips dangerous characters/path separators from the server-suggested name.
    public static func sanitize(_ suggested: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        var name = suggested.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Prevent hidden files and ".." names
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }
        // Limit length to stay safe for the file system (255 bytes).
        while name.utf8.count > 200 { name.removeFirst() }
        return name
    }

    /// "a.pdf" becomes "a (1).pdf", "a (2).pdf", etc. if it already exists.
    public static func uniqueURL(in directory: URL, suggested: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = sanitize(suggested)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 1
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}
