import AppKit
import WebKit

/// The right-clicked content, reported by `ContextMenuProbe` just before the menu appears.
struct ContextTarget {
    var link: URL?
    var image: URL?
    var selection = ""
}

/// Sends the link/image/selected text under the cursor on right-click. The `contextmenu` event fires
/// in the page process before WebKit requests the menu, so the data arrives before `willOpenMenu`.
enum ContextMenuProbe {
    static let handlerName = "hematContext"

    static let script = """
    document.addEventListener('contextmenu', (e) => {
      const handler = window.webkit && window.webkit.messageHandlers.hematContext;
      if (!handler) return;
      const el = e.target instanceof Element ? e.target : (e.target && e.target.parentElement);
      const link = el && el.closest('a[href]');
      const img = el && el.closest('img');
      handler.postMessage({
        link: link ? link.href : '',
        image: img ? (img.currentSrc || img.src || '') : '',
        selection: String(window.getSelection() || '').trim().slice(0, 500),
      });
    }, true);
    """
}

/// WKWebView with a fuller right-click menu (new tab, background tab, private window,
/// search text, copy address, bookmark, etc.).
final class HematWebView: WKWebView {
    weak var browser: BrowserWindowController?
    var contextTarget = ContextTarget()

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let target = contextTarget
        contextTarget = ContextTarget()
        guard let browser else { return }

        func find(_ id: String) -> Int? {
            menu.items.firstIndex { $0.identifier?.rawValue == id }
        }
        func item(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = browser
            item.representedObject = object
            return item
        }

        // WebKit's "Open in New Window" is already redirected to a new tab (createWebViewWith); the title
        // is adjusted so it isn't misleading.
        let renames = [
            "WKMenuItemIdentifierOpenLinkInNewWindow": String(localized: "Open Link in New Tab"),
            "WKMenuItemIdentifierOpenImageInNewWindow": String(localized: "Open Image in New Tab"),
            "WKMenuItemIdentifierOpenFrameInNewWindow": String(localized: "Open Frame in New Tab"),
            "WKMenuItemIdentifierOpenMediaInNewWindow": String(localized: "Open Video in New Tab"),
        ]
        for (id, title) in renames { if let index = find(id) { menu.items[index].title = title } }

        // WebKit's built-in search uses the system service (opens Safari). Replaced with search in Hemat.
        if let index = find("WKMenuItemIdentifierSearchWeb") { menu.removeItem(at: index) }

        if let link = target.link {
            var index = (find("WKMenuItemIdentifierOpenLinkInNewWindow") ?? -1) + 1
            var extra = [item(String(localized: "Open Link in Background Tab"),
                              #selector(BrowserWindowController.openLinkInBackgroundTab(_:)), link)]
            if !browser.isPrivate {
                extra.append(item(String(localized: "Open Link in New Private Window"),
                                  #selector(BrowserWindowController.openLinkInPrivateWindow(_:)), link))
            }
            if index == 0 {
                // Menu without the built-in link item: also add "Open Link in New Tab".
                extra.insert(item(String(localized: "Open Link in New Tab"),
                                  #selector(BrowserWindowController.openLinkInNewTab(_:)), link),
                             at: 0)
                extra.append(.separator())
            }
            for entry in extra {
                menu.insertItem(entry, at: index)
                index += 1
            }
        }

        if !target.selection.isEmpty {
            let short = target.selection.count > 30 ? String(target.selection.prefix(28)) + "…" : target.selection
            let search = item(String(localized: "Search with Google for “\(short)”"),
                              #selector(BrowserWindowController.searchSelection(_:)), target.selection)
            // Below "Copy" if present, to match Safari/Chrome.
            let copyIndex = find("WKMenuItemIdentifierCopy").map { $0 + 1 } ?? 0
            menu.insertItem(search, at: copyIndex)
        }

        // Page menu (not a link, image, or text): add page actions.
        if target.link == nil, target.image == nil, target.selection.isEmpty {
            let bookmarked = url.map(BrowserServices.shared.bookmarks.contains) ?? false
            let pageItems: [NSMenuItem] = [
                .separator(),
                item(bookmarked ? String(localized: "Remove Bookmark") : String(localized: "Add Bookmark"),
                     #selector(BrowserWindowController.toggleBookmarkAction(_:))),
                item(String(localized: "Copy Page Address"), #selector(BrowserWindowController.copyPageAddress(_:))),
                item(String(localized: "Open Page in Safari"),
                     #selector(BrowserWindowController.openInSafariAction(_:))),
                item(String(localized: "Print…"), #selector(BrowserWindowController.printPageAction(_:))),
            ]
            // Before "Inspect Element" (if present), so developer items stay at the bottom.
            var index = find("WKMenuItemIdentifierInspectElement") ?? menu.items.count
            for entry in pageItems {
                menu.insertItem(entry, at: index)
                index += 1
            }
        }

        // Clean up double / trailing separators.
        var previousWasSeparator = true
        for entry in menu.items {
            if entry.isSeparatorItem, previousWasSeparator { menu.removeItem(entry) } else {
                previousWasSeparator = entry.isSeparatorItem
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }
}

// MARK: - Developer tools (Web Inspector)

/// WebKit's built-in Web Inspector is opened via `_WKInspector` (the same private API as Safari's
/// Develop menu). Each call is checked for availability first.
enum DevTools {
    enum Panel: String {
        case inspector = "show"
        case console = "showConsole"
        case resources = "showResources"
        case elementSelection = "toggleElementSelection"
    }

    @discardableResult
    static func open(_ panel: Panel, for webView: WKWebView) -> Bool {
        guard webView.responds(to: Selector(("_inspector"))),
              let inspector = webView.value(forKey: "_inspector") as? NSObject else { return false }
        if panel == .elementSelection {
            // Element selection is only useful while the inspector is open.
            _ = inspector.perform(Selector((Panel.inspector.rawValue)))
        }
        let selector = Selector((panel.rawValue))
        guard inspector.responds(to: selector) else { return false }
        _ = inspector.perform(selector)
        return true
    }

    /// The extension's background WebView (background page), to inspect like a normal page.
    static func backgroundWebView(of context: WKWebExtensionContext) -> WKWebView? {
        guard context.responds(to: Selector(("_backgroundWebView"))) else { return nil }
        return context.value(forKey: "_backgroundWebView") as? WKWebView
    }

    /// Enables "Inspect Element" in the right-click menu and the inspector shortcuts.
    static func enable(on configuration: WKWebViewConfiguration) {
        let preferences = configuration.preferences
        if preferences.responds(to: Selector(("_setDeveloperExtrasEnabled:"))) {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
    }
}
