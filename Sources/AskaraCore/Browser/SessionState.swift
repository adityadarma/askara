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
        /// WKWebView's opaque `interactionState` blob (back/forward history + scroll position).
        /// Lets a restored tab feel like it was never closed, instead of reloading from `url`.
        public var interactionData: Data?
        public init(url: URL, title: String, isPinned: Bool = false, isMuted: Bool = false,
                    interactionData: Data? = nil) {
            self.url = url
            self.title = title
            self.isPinned = isPinned ? true : nil
            self.isMuted = isMuted ? true : nil
            self.interactionData = interactionData
        }
    }

    public struct SavedWindow: Codable, Equatable {
        public var tabs: [SavedTab]
        public var activeIndex: Int
        public var frame: SavedFrame?
        public var isFullScreen: Bool?

        public init(tabs: [SavedTab], activeIndex: Int, frame: SavedFrame? = nil, isFullScreen: Bool = false) {
            self.tabs = tabs
            self.activeIndex = tabs.isEmpty ? 0 : min(max(0, activeIndex), tabs.count - 1)
            self.frame = frame
            self.isFullScreen = isFullScreen ? true : nil
        }
    }

    /// Platform-neutral window geometry so AskaraCore stays independent of AppKit.
    public struct SavedFrame: Codable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var windows: [SavedWindow]

    public init(windows: [SavedWindow]) {
        // Windows without tabs are not worth restoring.
        self.windows = windows.filter { !$0.tabs.isEmpty }
    }

    public var isEmpty: Bool { windows.isEmpty }

    /// True for a session that holds nothing worth bringing back: no windows, or a single window
    /// with a single untouched home-page tab. Such a session never replaces a saved earlier one.
    public func isTrivial(homeURL: URL) -> Bool {
        guard let window = windows.first else { return true }
        guard windows.count == 1, window.tabs.count == 1 else { return false }
        func key(_ url: URL) -> String {
            var path = url.path
            while path.hasSuffix("/") { path.removeLast() }
            return SiteSettings.key(for: url.host ?? "") + path + "?" + (url.query ?? "")
        }
        return key(window.tabs[0].url) == key(homeURL)
    }

    /// The active tab of the most recently used window (saved first). Askara opens only this tab
    /// when a profile opens, so launching doesn't bring back a pile of tabs.
    public var startupTab: SavedTab? {
        guard let window = windows.first else { return nil }
        return window.tabs.indices.contains(window.activeIndex) ? window.tabs[window.activeIndex] : window.tabs.first
    }
}
