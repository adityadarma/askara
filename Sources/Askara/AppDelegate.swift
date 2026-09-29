import AppKit
import WebKit
import AskaraCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var services: BrowserServices { .shared }
    private let homeURL = AddressParser.defaultHomeURL

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(delegate: self)
        services.compileBlockList()
        // Find installed Safari extensions and load the ones the user enabled.
        services.extensions.start()

        // Restore session login cookies before tabs so sites open already logged in.
        SessionCookies.restore { [weak self] in
            guard let self else { return }
            // Restore the last session; tabs other than the active one are restored asleep.
            if !self.services.restoreSession() {
                self.services.makeWindow(isPrivate: false).newTab(url: self.homeURL)
            }
            NSApp.activate()
        }
        watchMemoryPressure()
        services.startHibernationTimer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Save session cookies before quitting (cookie reads are asynchronous).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        services.saveAll()
        var replied = false
        let finish = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        SessionCookies.save { finish() }
        // Ensure the app can still quit if WebKit never responds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { finish() } }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { services.saveAll() }

    /// Dock icon clicked while no windows are open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if services.windows.isEmpty { newWindowAction(nil) }
        return true
    }

    /// Opens links/files from other apps (when Askara is the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { services.open($0, newTab: true) }
    }

    /// When macOS is low on RAM, put all background tabs in all windows to sleep.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.services.enforceHibernation(underMemoryPressure: true) }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Actions

    @objc func newWindowAction(_ sender: Any?) {
        services.makeWindow(isPrivate: false).newTab(url: homeURL)
    }

    @objc func newPrivateWindowAction(_ sender: Any?) {
        services.makeWindow(isPrivate: true).openBlankTab()
    }

    /// ⌘T when there are no windows at all.
    @objc func newTabAction(_ sender: Any?) { newWindowAction(sender) }

    @objc func reopenClosedTabAction(_ sender: Any?) { services.reopenClosedTab() }

    @objc func updateBlockListAction(_ sender: Any?) {
        services.keyBrowserWindow?.showToast(String(localized: "Updating ad block list…"), duration: nil)
        services.blockListUpdater.update(force: true) { [weak self] message in
            self?.services.keyBrowserWindow?.showToast(message, duration: 4)
        }
    }
    @objc func showHistoryAction(_ sender: Any?) { LibraryWindowController.shared.show(.history) }
    @objc func showBookmarksAction(_ sender: Any?) { LibraryWindowController.shared.show(.bookmarks) }
    @objc func showDownloadsAction(_ sender: Any?) { LibraryWindowController.shared.show(.downloads) }

    @objc func openMenuURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.open(url, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(reopenClosedTabAction(_:)) { return !services.recentlyClosed.isEmpty }
        if item.action == #selector(updateBlockListAction(_:)) { return !services.blockListUpdater.isUpdating }
        return true
    }

    // MARK: - Extensions

    /// Clicking an extension name: enable it (after permission consent) or disable it.
    @objc func toggleExtensionAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? InstalledExtensionBox else { return }
        let manager = services.extensions
        if manager.isEnabled(item.value) {
            manager.disable(item.value)
            services.keyBrowserWindow?.showToast(String(localized: "\(item.value.name) disabled"), duration: 3)
            return
        }
        Task { @MainActor in
            do {
                let ext = try await manager.inspect(item.value)
                let alert = NSAlert()
                alert.messageText = String(localized: "Enable \(ext.displayName ?? item.value.name)?")
                alert.informativeText = String(localized: "This extension will be able to:") + "\n• "
                    + ExtensionManager.describe(ext).joined(separator: "\n• ")
                    + "\n\n" + String(localized: "Extensions don't run in private windows.")
                alert.addButton(withTitle: String(localized: "Enable"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await manager.enable(item.value)
                services.keyBrowserWindow?.showToast(
                    String(localized: "\(item.value.name) is enabled. Click its icon to the right of the address bar."), duration: 4)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = String(localized: "Couldn't enable \(item.value.name)")
                alert.runModal()
            }
        }
    }

    @objc func extensionOptionsAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? InstalledExtensionBox,
              let context = services.extensions.context(for: item.value) else { return }
        services.extensions.openOptions(context)
    }

    fileprivate func updateExtensionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = services.extensions
        guard !manager.installed.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No Safari extensions installed"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            let hint = NSMenuItem(title: String(localized: "Install an app with a Safari extension (e.g. Bitwarden) from the App Store"),
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return
        }
        for installed in manager.installed {
            let box = InstalledExtensionBox(installed)
            let enabled = manager.isEnabled(installed)
            let toggle = NSMenuItem(title: installed.name, action: #selector(toggleExtensionAction(_:)),
                                    keyEquivalent: "")
            toggle.target = self
            toggle.state = enabled ? .on : .off
            toggle.representedObject = box
            toggle.toolTip = enabled ? String(localized: "Click to disable") : String(localized: "Click to enable")
            menu.addItem(toggle)
            if enabled, manager.context(for: installed)?.optionsPageURL != nil {
                let options = NSMenuItem(title: String(localized: "Settings for \(installed.name)…"),
                                         action: #selector(extensionOptionsAction(_:)), keyEquivalent: "")
                options.target = self
                options.representedObject = box
                options.indentationLevel = 1
                menu.addItem(options)
            }
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: String(localized: "Extensions use extra RAM while enabled"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
    }

    // MARK: - Develop

    @objc func emptyCachesAction(_ sender: Any?) {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                  WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
        // Caches only; cookies, logins, and site storage are left untouched.
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            MainActor.assumeIsolated { self?.services.keyBrowserWindow?.showToast(String(localized: "Caches emptied"), duration: 2) }
        }
    }

    /// Opens Web Inspector for an extension's background page.
    @objc func inspectExtensionAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? InstalledExtensionBox,
              let context = services.extensions.context(for: box.value) else { return }
        let open = { (web: WKWebView?) in
            guard let web, DevTools.open(.console, for: web) else {
                self.services.keyBrowserWindow?.showToast(String(localized: "Background page for \(box.value.name) isn't running yet"), duration: 3)
                return
            }
        }
        if let web = DevTools.backgroundWebView(of: context) { return open(web) }
        context.loadBackgroundContent { _ in
            MainActor.assumeIsolated { open(DevTools.backgroundWebView(of: context)) }
        }
    }

    fileprivate func updateDevelopMenu(_ menu: NSMenu) {
        guard let header = menu.item(withTag: MainMenu.developExtensionHeaderTag) else { return }
        let start = menu.index(of: header) + 1
        while menu.items.count > start { menu.removeItem(at: start) }
        let loaded = services.extensions.loaded
        header.isHidden = loaded.isEmpty
        menu.items[max(0, start - 2)].isHidden = loaded.isEmpty // separator above the header
        for entry in loaded {
            let item = NSMenuItem(title: String(localized: "Background Page for \(entry.item.name)"),
                                  action: #selector(inspectExtensionAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = InstalledExtensionBox(entry.item)
            item.indentationLevel = 1
            menu.addItem(item)
        }
        let popupHint = NSMenuItem(title: String(localized: "Extension popups: right-click in the popup > Inspect Element"),
                                   action: nil, keyEquivalent: "")
        popupHint.isEnabled = false
        popupHint.isHidden = loaded.isEmpty
        popupHint.indentationLevel = 1
        menu.addItem(popupHint)

        // The JavaScript item title follows the active tab's state.
        if let js = menu.items.first(where: { $0.action == #selector(BrowserWindowController.toggleJavaScriptAction(_:)) }) {
            let enabled = services.keyBrowserWindow?.currentTab?.webView?
                .configuration.defaultWebpagePreferences.allowsContentJavaScript ?? true
            js.title = enabled ? String(localized: "Disable JavaScript") : String(localized: "Enable JavaScript")
        }
    }

    // MARK: - Dynamic menus (History & Bookmarks)

    /// Populated when the menu opens, so there is no cost while it is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == MainMenu.tabMenuID { return updateTabMenu(menu) }
        if menu.identifier == MainMenu.extensionMenuID { return updateExtensionMenu(menu) }
        if menu.identifier == MainMenu.developMenuID { return updateDevelopMenu(menu) }
        if menu.identifier == MainMenu.appMenuID {
            menu.item(withTag: MainMenu.blockStatusTag)?.title = services.blockListUpdater.statusText
            return
        }
        let isHistory = menu.identifier == MainMenu.historyMenuID
        let fixedCount = isHistory ? MainMenu.historyFixedItems : MainMenu.bookmarkFixedItems
        while menu.items.count > fixedCount { menu.removeItem(at: fixedCount) }

        let entries: [(String, URL)] = isHistory
            ? services.history.entries.prefix(15).map { ($0.title.isEmpty ? $0.url.absoluteString : $0.title, $0.url) }
            : services.bookmarks.bookmarks.suffix(30).reversed().map { ($0.title, $0.url) }

        if entries.isEmpty {
            let empty = NSMenuItem(title: isHistory ? String(localized: "No history yet") : String(localized: "No bookmarks yet"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (title, url) in entries {
            let short = title.count > 60 ? String(title.prefix(57)) + "…" : title
            let item = NSMenuItem(title: short, action: #selector(openMenuURL(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.absoluteString
            menu.addItem(item)
        }
    }
}

extension AppDelegate {
    /// Open tabs in the active window, with a checkmark on the active tab.
    fileprivate func updateTabMenu(_ menu: NSMenu) {
        while menu.items.count > MainMenu.tabFixedItems { menu.removeItem(at: MainMenu.tabFixedItems) }

        guard let window = services.keyBrowserWindow, !window.tabMenuEntries.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No tabs"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let entries = window.tabMenuEntries
        for (index, entry) in entries.enumerated() {
            let title = entry.title.count > 60 ? String(entry.title.prefix(57)) + "…" : entry.title
            let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.selectTabFromMenu(_:)),
                                  keyEquivalent: "")
            item.tag = index
            item.target = window
            item.state = entry.isActive ? .on : .off
            // Show the same shortcuts as the hidden items (⌘1–⌘8, ⌘9 = last tab).
            if index < 8 && !(index == entries.count - 1 && entries.count > 8) {
                item.keyEquivalent = "\(index + 1)"
            } else if index == entries.count - 1 {
                item.keyEquivalent = "9"
            }
            if entry.isSleeping {
                item.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: String(localized: "Sleeping"))
                item.toolTip = String(localized: "Sleeping: not using RAM")
            }
            menu.addItem(item)
        }
    }
}

extension NSMenuItem {
    func apply(_ body: (NSMenuItem) -> Void) { body(self) }
}

/// `representedObject` needs an object; the struct is boxed.
final class InstalledExtensionBox: NSObject {
    let value: InstalledExtension
    init(_ value: InstalledExtension) { self.value = value }
}

enum MainMenu {
    static let historyMenuID = NSUserInterfaceItemIdentifier("history")
    static let bookmarkMenuID = NSUserInterfaceItemIdentifier("bookmarks")
    static let tabMenuID = NSUserInterfaceItemIdentifier("tabs")
    static let appMenuID = NSUserInterfaceItemIdentifier("app")
    static let extensionMenuID = NSUserInterfaceItemIdentifier("extensions")
    static let developMenuID = NSUserInterfaceItemIdentifier("develop")
    static let developExtensionHeaderTag = 7002
    static let blockStatusTag = 7001
    static let historyFixedItems = 5
    static let bookmarkFixedItems = 3
    /// Next, Previous, 9 hidden shortcuts, separator.
    static let tabFixedItems = 12

    @MainActor
    static func make(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }

        func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }

        typealias B = BrowserWindowController
        typealias A = AppDelegate

        let blockStatus = NSMenuItem(title: String(localized: "Ad Blocker"), action: nil, keyEquivalent: "")
        blockStatus.isEnabled = false
        blockStatus.tag = blockStatusTag
        let appMenu = submenu("Askara", [
            item(String(localized: "About Askara"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            blockStatus,
            item(String(localized: "Update Ad Block List"), #selector(A.updateBlockListAction(_:))),
            .separator(),
            item(String(localized: "Hide Askara"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit Askara"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        appMenu.identifier = appMenuID
        appMenu.delegate = delegate
        submenu(String(localized: "File"), [
            item(String(localized: "New Tab"), #selector(B.newTabAction(_:)), "t"),
            item(String(localized: "New Window"), #selector(A.newWindowAction(_:)), "n"),
            item(String(localized: "New Private Window"), #selector(A.newPrivateWindowAction(_:)), "n", [.command, .shift]),
            item(String(localized: "Open Location…"), #selector(B.focusAddressBar(_:)), "l"),
            .separator(),
            item(String(localized: "Close Tab"), #selector(B.closeTabAction(_:)), "w"),
            item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item(String(localized: "Reopen Closed Tab"), #selector(A.reopenClosedTabAction(_:)), "t", [.command, .shift]),
            .separator(),
            item(String(localized: "Open This Page in Safari"), #selector(B.openInSafariAction(_:))),
            item(String(localized: "Print…"), #selector(B.printPageAction(_:)), "p"),
        ])
        // The Edit menu is required for copy/paste to work in the address bar and web pages.
        submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(String(localized: "Find…"), #selector(B.showFindBar(_:)), "f"),
            item(String(localized: "Find Next"), #selector(B.findNextAction(_:)), "g"),
            item(String(localized: "Find Previous"), #selector(B.findPreviousAction(_:)), "g", [.command, .shift]),
        ])
        submenu(String(localized: "View"), [
            item(String(localized: "Reload Page"), #selector(B.reloadAction(_:)), "r"),
            .separator(),
            item(String(localized: "Zoom In"), #selector(B.zoomInAction(_:)), "+"),
            item(String(localized: "Zoom In"), #selector(B.zoomInAction(_:)), "="), // ⌘= without Shift
            item(String(localized: "Zoom Out"), #selector(B.zoomOutAction(_:)), "-"),
            item(String(localized: "Actual Size"), #selector(B.zoomResetAction(_:)), "0"),
            .separator(),
            item(String(localized: "Sleep Background Tabs"), #selector(B.hibernateNowAction(_:)), "k", [.command, .shift]),
            .separator(),
            item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]).items[3].apply {
            // Duplicate ⌘= (without Shift) is only a shortcut; hidden from the menu.
            $0.isHidden = true
            $0.allowsKeyEquivalentWhenHidden = true
        }

        let history = submenu(String(localized: "History"), [
            item(String(localized: "Back"), #selector(B.backAction(_:)), "["),
            item(String(localized: "Forward"), #selector(B.forwardAction(_:)), "]"),
            item(String(localized: "Show All History"), #selector(A.showHistoryAction(_:)), "y"),
            .separator(),
            {
                let header = NSMenuItem(title: String(localized: "Recently Visited"), action: nil, keyEquivalent: "")
                header.isEnabled = false
                return header
            }(),
        ])
        history.identifier = historyMenuID
        history.delegate = delegate

        let bookmarks = submenu(String(localized: "Bookmarks"), [
            item(String(localized: "Add Bookmark"), #selector(B.toggleBookmarkAction(_:)), "d"),
            item(String(localized: "Show All Bookmarks"), #selector(A.showBookmarksAction(_:)), "b", [.command, .option]),
            .separator(),
        ])
        bookmarks.identifier = bookmarkMenuID
        bookmarks.delegate = delegate

        // ⌘1–⌘9 keep working via hidden items. The visible list only contains
        // tabs that are actually open, filled when the menu opens (menuNeedsUpdate).
        var tabItems = [
            item(String(localized: "Show Next Tab"), #selector(B.nextTabAction(_:)), "]", [.command, .shift]),
            item(String(localized: "Show Previous Tab"), #selector(B.previousTabAction(_:)), "[", [.command, .shift]),
        ]
        for n in 1...9 {
            let shortcut = item(String(localized: "Tab \(n)"), #selector(B.selectTabNumberAction(_:)), "\(n)", tag: n)
            shortcut.isHidden = true
            shortcut.allowsKeyEquivalentWhenHidden = true
            tabItems.append(shortcut)
        }
        tabItems.append(.separator())
        let tabs = submenu(String(localized: "Tab"), tabItems)
        tabs.identifier = tabMenuID
        tabs.delegate = delegate

        let extensions = submenu(String(localized: "Extensions"), [])
        extensions.identifier = extensionMenuID
        extensions.delegate = delegate

        // Same shortcuts as Safari.
        let develop = submenu(String(localized: "Develop"), [
            item(String(localized: "Show Web Inspector"), #selector(B.showWebInspectorAction(_:)), "i", [.command, .option]),
            item(String(localized: "Show JavaScript Console"), #selector(B.showConsoleAction(_:)), "c", [.command, .option]),
            item(String(localized: "Show Page Source"), #selector(B.viewSourceAction(_:)), "u", [.command, .option]),
            item(String(localized: "Show Page Resources"), #selector(B.showResourcesAction(_:)), "a", [.command, .option]),
            item(String(localized: "Start Element Selection"), #selector(B.selectElementAction(_:)), "c", [.command, .shift]),
            .separator(),
            item(String(localized: "Reload Page From Origin"), #selector(B.reloadIgnoringCacheAction(_:)), "r", [.command, .option]),
            item(String(localized: "Empty Caches"), #selector(A.emptyCachesAction(_:)), "e", [.command, .option]),
            item(String(localized: "Disable JavaScript"), #selector(B.toggleJavaScriptAction(_:))),
            .separator(),
            {
                let header = NSMenuItem(title: String(localized: "Inspect Extensions"), action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.tag = developExtensionHeaderTag
                return header
            }(),
        ])
        develop.identifier = developMenuID
        develop.delegate = delegate

        let windowMenu = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Downloads"), #selector(A.showDownloadsAction(_:)), "l", [.command, .option]),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu
        return main
    }
}
