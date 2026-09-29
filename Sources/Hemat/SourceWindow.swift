import AppKit

/// "Show Page Source" window: the current page's HTML (DOM after JavaScript has run).
@MainActor
enum SourceWindow {
    private static var open: [NSWindow] = []

    static func show(html: String, url: URL, relativeTo parent: NSWindow?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Source: \(url.absoluteString)")
        window.isReleasedWhenClosed = false

        let scroll = NSTextView.scrollableTextView()
        guard let text = scroll.documentView as? NSTextView else { return }
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isIncrementalSearchingEnabled = true
        text.usesFindBar = true // ⌘F in the source window
        text.string = html
        text.setAccessibilityLabel(String(localized: "Page source"))
        window.contentView = scroll

        if let parent {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 40, y: parent.frame.maxY - 40))
        } else {
            window.center()
        }
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        window.makeKeyAndOrderFront(nil)
    }
}
