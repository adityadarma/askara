import AppKit
import WebKit
import AskaraCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var services: BrowserServices { .shared }
    private var homeURL: URL { services.homeURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(delegate: self)
        services.compileBlockList()
        services.downloads.requestNotificationPermission()
        // Retry removing website data of deleted profiles that was still in use last time.
        services.removeDataStores()
        services.sync.start()
        // Start with one fresh home-page tab. Profile cookies remain available, but prior windows
        // and tabs are not restored automatically.
        services.openProfile(services.profileList.lastUsedID, atLaunch: true)
        watchMemoryPressure()
        services.startHibernationTimer()
        AppUpdater.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Save session cookies before quitting (cookie reads are asynchronous).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmQuit() else { return .terminateCancel }
        services.beginTermination()
        services.saveAll()
        var replied = false
        let finish = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        let storageWrites = DispatchGroup()
        storageWrites.enter()
        services.saveSessionCookies { storageWrites.leave() }
        storageWrites.notify(queue: .main) { finish() }
        // Ensure the app can still quit if WebKit never responds.
        let timer = Timer(timeInterval: 2, repeats: false) { _ in MainActor.assumeIsolated { finish() } }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// ⌘Q with several tabs open or downloads running asks first, so a slip doesn't close everything.
    /// Logout, restart, and shutdown quit without asking.
    private func confirmQuit() -> Bool {
        guard services.preferences.confirmsQuit else { return true }
        if NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil {
            return true
        }
        let tabs = services.openTabCount
        let downloads = services.downloads.running.count
        guard tabs > 1 || downloads > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Askara?")
        var lines: [String] = []
        if tabs > 1 { lines.append(String(localized: "\(tabs) tabs will be closed.")) }
        if downloads > 0 {
            lines.append(downloads == 1 ? String(localized: "1 download is still in progress and will be cancelled.")
                                        : String(localized: "\(downloads) downloads are still in progress and will be cancelled."))
        }
        alert.informativeText = lines.joined(separator: " ")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on {
            services.updatePreferences { $0.confirmsQuit = false }
        }
        return quit
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.saveAll()
        CrashReporter.shared.finishCleanly()
    }

    /// Dock icon clicked while no windows are open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if services.windows.isEmpty { services.openProfile(services.profileList.lastUsedID) }
        return true
    }

    /// Opens links/files from other apps (when Askara is the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { services.open($0, newTab: true) }
    }

    /// macOS memory pressure. Warning: apply the tab limits strictly (recently used tabs are no longer
    /// spared). Critical: put every background tab in all windows to sleep.
    /// Warnings are common on 8 GB Macs, so they no longer sleep everything; that made tabs you'd
    /// just left reload when you came back.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let event = source?.data else { return }
                let pressure: MemoryPressure = event.contains(.critical) ? .critical
                    : event.contains(.warning) ? .warning : .normal
                guard pressure != .normal else { return }
                Log.notice("Askara: macOS memory pressure \(pressure.rawValue)")
                self?.services.enforceHibernation(pressure: pressure)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Actions

    /// New window for the profile in use.
    @objc func newWindowAction(_ sender: Any?) {
        services.makeWindow(profile: services.currentProfile).newTab(url: homeURL)
    }

    @objc func newPrivateWindowAction(_ sender: Any?) {
        services.makeWindow(profile: services.currentProfile, isPrivate: true).newTab(url: homeURL)
    }

    /// Profile chosen in the Profiles menu or the toolbar profile menu: go to its window, or open it.
    @objc func openProfileAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        services.openProfile(id)
    }

    @objc func addProfileAction(_ sender: Any?) { ProfileDialogs.add() }
    @objc func editProfileAction(_ sender: Any?) { ProfileDialogs.edit(services.currentProfile.id) }
    @objc func deleteProfileAction(_ sender: Any?) { ProfileDialogs.delete(services.currentProfile.id) }

    /// ⌘T when there are no windows at all.
    @objc func newTabAction(_ sender: Any?) { newWindowAction(sender) }

    @objc func reopenClosedTabAction(_ sender: Any?) { services.reopenClosedTab() }

    @objc func restorePreviousSessionAction(_ sender: Any?) { services.restorePreviousSession() }

    @objc func openSyncedTabsAction(_ sender: Any?) {
        let tabs = services.sync.syncedTabs
        guard !tabs.isEmpty else { return }
        let window = services.makeWindow(profile: services.currentProfile)
        window.restore(.init(tabs: tabs, activeIndex: 0))
    }

    @objc func updateBlockListAction(_ sender: Any?) {
        services.keyBrowserWindow?.showToast(String(localized: "Updating ad block list…"), duration: nil)
        services.blockListUpdater.update(force: true) { [weak self] message in
            self?.services.keyBrowserWindow?.showToast(message, duration: 4)
        }
    }
    @objc func showSettingsAction(_ sender: Any?) { services.settingsWindow.show() }
    @objc func showHistoryAction(_ sender: Any?) { LibraryWindowController.history.show() }
    @objc func showBookmarksAction(_ sender: Any?) { LibraryWindowController.bookmarks.show() }
    @objc func importAction(_ sender: Any?) {
        BrowserImporter.run(in: NSApp.keyWindow, profile: services.currentProfile)
    }
    @objc func showDownloadsAction(_ sender: Any?) { DownloadsWindowController.shared.show() }
    @objc func clearBrowsingDataAction(_ sender: Any?) {
        ClearDataDialog.present(for: services.currentProfile, in: NSApp.keyWindow)
    }
    @objc func showTaskManagerAction(_ sender: Any?) { TaskManagerWindowController.shared.show() }

    @objc func exportCrashReportAction(_ sender: Any?) {
        CrashReporter.shared.exportReport(relativeTo: NSApp.keyWindow)
    }

    @objc func deleteCrashReportAction(_ sender: Any?) { CrashReporter.shared.deleteReport() }

    @objc func openAllMenuURLs(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        urls.forEach { services.open($0, newTab: true) }
    }

    @objc func openMenuURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.open(url, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(reopenClosedTabAction(_:)) { return !services.currentProfile.recentlyClosed.isEmpty }
        if item.action == #selector(restorePreviousSessionAction(_:)) { return services.currentProfile.canRestorePreviousSession }
        if item.action == #selector(openSyncedTabsAction(_:)) { return !services.sync.syncedTabs.isEmpty }
        if item.action == #selector(deleteProfileAction(_:)) {
            return services.profileList.canRemove(services.currentProfile.id)
        }
        if item.action == #selector(updateBlockListAction(_:)) { return !services.blockListUpdater.isUpdating }
        if item.action == #selector(exportCrashReportAction(_:)), !CrashReporter.shared.hasReport { return false }
        if item.action == #selector(deleteCrashReportAction(_:)), !CrashReporter.shared.hasReport { return false }
        return true
    }

    // MARK: - Extensions

    /// Clicking an extension name: enable it (after permission consent) or disable it.
    @objc func toggleExtensionAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? InstalledExtensionBox else { return }
        let manager = services.currentProfile.extensions
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
              let context = services.currentProfile.extensions.context(for: item.value) else { return }
        services.currentProfile.extensions.openOptions(context)
    }

    // MARK: - Develop

    @objc func emptyCachesAction(_ sender: Any?) {
        // Caches only; cookies, logins, and site storage are left untouched.
        DeveloperCache.empty(services.currentProfile.dataStore) { [weak self] in
            self?.services.keyBrowserWindow?.showToast(String(localized: "Caches emptied"), duration: 2)
        }
    }

    // MARK: - Dynamic menus (History & Bookmarks)

    /// Populated when the menu opens, so there is no cost while it is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == MainMenu.tabMenuID { return updateTabMenu(menu) }
        if menu.identifier == OpenWithMenu.id { return OpenWithMenu.fill(menu) }
        if menu.identifier == MainMenu.profileMenuID {
            menu.removeAllItems()
            // The menu bar title already says "Profiles"; skip the duplicate header.
            ProfileMenu.fill(menu, current: services.currentProfile.id, target: self, showsHeader: false)
            return
        }
        if menu.identifier == MainMenu.appMenuID {
            menu.item(withTag: MainMenu.blockStatusTag)?.title = services.blockListUpdater.statusText
            return
        }
        if menu.identifier == MainMenu.viewMenuID {
            let freed = services.freedBytes
            menu.item(withTag: MainMenu.memorySaverStatusTag)?.title = freed > 0
                ? String(localized: "Memory Saver: freed about \(ProcessMemory.format(freed)) this session")
                : String(localized: "Memory Saver: no tabs slept yet")
            return
        }
        // Only History and Bookmarks are filled below; any other menu is left as built.
        guard menu.identifier == MainMenu.historyMenuID || menu.identifier == MainMenu.bookmarkMenuID else { return }
        let isHistory = menu.identifier == MainMenu.historyMenuID
        // History keeps everything up to its "Recently Visited" header; Bookmarks a fixed number of items.
        let fixedCount = isHistory
            ? (menu.items.firstIndex { $0.identifier == MainMenu.historyHeaderID }.map { $0 + 1 } ?? menu.items.count)
            : MainMenu.bookmarkFixedItems
        while menu.items.count > fixedCount { menu.removeItem(at: fixedCount) }

        if !isHistory {
            // Bookmarks menu: bar and Other Bookmarks, folders as submenus.
            let store = services.currentProfile.bookmarks
            if store.bar.isEmpty && store.other.isEmpty {
                let empty = NSMenuItem(title: String(localized: "No bookmarks yet"), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for node in store.bar {
                menu.addItem(BookmarkMenus.item(for: node, target: self, action: #selector(openMenuURL(_:)),
                                                openAll: #selector(openAllMenuURLs(_:))))
            }
            if !store.other.isEmpty {
                menu.addItem(.separator())
                let other = BookmarkNode.folder(BookmarkMenus.otherTitle, children: store.other)
                menu.addItem(BookmarkMenus.item(for: other, target: self, action: #selector(openMenuURL(_:)),
                                                openAll: #selector(openAllMenuURLs(_:))))
            }
            return
        }
        let entries: [(String, URL)] = services.currentProfile.history.entries.prefix(15)
            .map { ($0.title.isEmpty ? $0.url.absoluteString : $0.title, $0.url) }

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
        // Everything after the "Open Tabs" header is the tab list; the actions above it stay.
        guard let header = menu.items.firstIndex(where: { $0.identifier == MainMenu.openTabsHeaderID }) else { return }
        while menu.items.count > header + 1 { menu.removeItem(at: header + 1) }

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

extension NSMenu {
    func apply(_ body: (NSMenu) -> Void) { body(self) }
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
    static let blockStatusTag = 7001
    static let historyHeaderID = NSUserInterfaceItemIdentifier("history.recentlyVisitedHeader")
    static let bookmarkFixedItems = 4
    static let memorySaverStatusTag = 7003
    static let viewMenuID = NSUserInterfaceItemIdentifier("view")
    static let profileMenuID = NSUserInterfaceItemIdentifier("profiles")
    /// Header above the open-tab list in the Tab menu; items after it are rebuilt on open.
    static let openTabsHeaderID = NSUserInterfaceItemIdentifier("tabs.openTabsHeader")

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
            {
                let i = item(String(localized: "Check for Updates…"), #selector(AppUpdater.checkForUpdates(_:)))
                i.target = AppUpdater.shared
                return i
            }(),
            .separator(),
            item(String(localized: "Settings…"), #selector(A.showSettingsAction(_:)), ","),
            .separator(),
            blockStatus,
            item(String(localized: "Update Ad Block List"), #selector(A.updateBlockListAction(_:))),
            item(String(localized: "Export Previous Session Report…"), #selector(A.exportCrashReportAction(_:))),
            item(String(localized: "Delete Previous Session Report"), #selector(A.deleteCrashReportAction(_:))),
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
            item(String(localized: "Reopen Closed Tab or Window"), #selector(A.reopenClosedTabAction(_:)), "t", [.command, .shift]),
            item(String(localized: "Open Synced Tabs"), #selector(A.openSyncedTabsAction(_:))),
            .separator(),
            item(String(localized: "Open This Page in Safari"), #selector(B.openInSafariAction(_:))),
            item(String(localized: "Print…"), #selector(B.printPageAction(_:)), "p"),
            item(String(localized: "Save Page as PDF…"), #selector(B.savePageAsPDFAction(_:))),
            item(String(localized: "Share…"), #selector(B.sharePageAction(_:))),
        ])
        // The Edit menu is required for copy/paste to work in the address bar and web pages.
        submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            // Title switches to "Paste and Search" for plain text. ⇧⌘V is handled by the address bar
            // itself (AddressField), so pages like Google Docs keep it for "paste without formatting".
            item(String(localized: "Paste and Go"), #selector(B.pasteAndGoAction(_:))),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(String(localized: "Copy Page Address"), #selector(B.copyPageAddress(_:)), "c", [.command, .shift]),
            item(String(localized: "Copy Page as Markdown Link"), #selector(B.copyMarkdownLinkAction(_:)), "c",
                 [.command, .shift, .control]),
            .separator(),
            item(String(localized: "Find…"), #selector(B.showFindBar(_:)), "f"),
            item(String(localized: "Find Next"), #selector(B.findNextAction(_:)), "g"),
            item(String(localized: "Find Previous"), #selector(B.findPreviousAction(_:)), "g", [.command, .shift]),
        ])
        submenu(String(localized: "View"), [
            item(String(localized: "Reload Page"), #selector(B.reloadAction(_:)), "r"),
            .separator(),
            item(String(localized: "Show Bookmarks Bar"), #selector(B.toggleBookmarksBarAction(_:)), "b", [.command, .shift]),
            item(String(localized: "Take Full-Page Screenshot"), #selector(B.fullPageScreenshotAction(_:)), "s", [.command, .shift]),
            item(String(localized: "Show Reader"), #selector(B.toggleReaderAction(_:)), "r", [.command, .shift]),
            .separator(),
            item(String(localized: "Zoom In"), #selector(B.zoomInAction(_:)), "+"),
            item(String(localized: "Zoom In"), #selector(B.zoomInAction(_:)), "="), // ⌘= without Shift
            item(String(localized: "Zoom Out"), #selector(B.zoomOutAction(_:)), "-"),
            item(String(localized: "Actual Size"), #selector(B.zoomResetAction(_:)), "0"),
            .separator(),
            item(String(localized: "Sleep Background Tabs"), #selector(B.hibernateNowAction(_:)), "k", [.command, .shift]),
            item(String(localized: "Keep This Site Awake"), #selector(B.toggleKeepAwakeAction(_:))),
            {
                // Memory Saver status, updated when the View menu opens.
                let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                status.isEnabled = false
                status.tag = memorySaverStatusTag
                return status
            }(),
            .separator(),
            item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]).apply { view in
            view.identifier = viewMenuID
            view.delegate = delegate
            // Duplicate ⌘= (without Shift) is only a shortcut; hidden from the menu.
            view.items[3].isHidden = true
            view.items[3].allowsKeyEquivalentWhenHidden = true
        }

        let history = submenu(String(localized: "History"), [
            item(String(localized: "Back"), #selector(B.backAction(_:)), "["),
            item(String(localized: "Forward"), #selector(B.forwardAction(_:)), "]"),
            item(String(localized: "Show All History"), #selector(A.showHistoryAction(_:)), "y"),
            item(String(localized: "Restore Previous Session"), #selector(A.restorePreviousSessionAction(_:))),
            item(String(localized: "Clear Browsing Data…"), #selector(A.clearBrowsingDataAction(_:)), "\u{8}",
                 [.command, .shift]),
            .separator(),
            {
                let header = NSMenuItem(title: String(localized: "Recently Visited"), action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.identifier = historyHeaderID
                return header
            }(),
        ])
        history.identifier = historyMenuID
        history.delegate = delegate

        let bookmarks = submenu(String(localized: "Bookmarks"), [
            item(String(localized: "Add Bookmark"), #selector(B.toggleBookmarkAction(_:)), "d"),
            item(String(localized: "Show All Bookmarks"), #selector(A.showBookmarksAction(_:)), "b", [.command, .option]),
            item(String(localized: "Import Bookmarks and History…"), #selector(A.importAction(_:))),
            .separator(),
        ])
        bookmarks.identifier = bookmarkMenuID
        bookmarks.delegate = delegate

        // Top-level like Chrome (Bookmarks, Profiles, Tab). Filled when opened (menuNeedsUpdate),
        // like the toolbar profile button.
        let profiles = submenu(String(localized: "Profiles"), [])
        profiles.identifier = profileMenuID
        profiles.delegate = delegate

        // ⌘1–⌘9 keep working via hidden items. The visible list only contains
        // tabs that are actually open, filled when the menu opens (menuNeedsUpdate).
        var tabItems = [
            item(String(localized: "Show Next Tab"), #selector(B.nextTabAction(_:)), "]", [.command, .shift]),
            item(String(localized: "Show Previous Tab"), #selector(B.previousTabAction(_:)), "[", [.command, .shift]),
            .separator(),
            // Titles follow the active tab (validateMenuItem).
            item(String(localized: "Pin Tab"), #selector(B.togglePinTabAction(_:))),
            item(String(localized: "Mute Tab"), #selector(B.toggleMuteTabAction(_:)), "m", [.command, .control]),
            item(String(localized: "Duplicate Tab"), #selector(B.duplicateTabAction(_:))),
            item(String(localized: "Duplicate Tab in Background"), #selector(B.duplicateTabInBackgroundAction(_:))),
            item(String(localized: "Close Duplicate Tabs"), #selector(B.closeDuplicateTabsAction(_:))),
        ]
        for n in 1...9 {
            let shortcut = item(String(localized: "Tab \(n)"), #selector(B.selectTabNumberAction(_:)), "\(n)", tag: n)
            shortcut.isHidden = true
            shortcut.allowsKeyEquivalentWhenHidden = true
            tabItems.append(shortcut)
        }
        tabItems.append(.separator())
        // Section header, like the "Recently Visited" header in History, so tab names don't read as actions.
        let openTabsHeader = NSMenuItem(title: String(localized: "Open Tabs"), action: nil, keyEquivalent: "")
        openTabsHeader.isEnabled = false
        openTabsHeader.identifier = openTabsHeaderID
        tabItems.append(openTabsHeader)
        let tabs = submenu(String(localized: "Tab"), tabItems)
        tabs.identifier = tabMenuID
        tabs.delegate = delegate

        // Same shortcuts as Safari.
        _ = submenu(String(localized: "Develop"), [
            item(String(localized: "Show Web Inspector"), #selector(B.showWebInspectorAction(_:)), "i", [.command, .option]),
            item(String(localized: "Show JavaScript Console"), #selector(B.showConsoleAction(_:)), "c", [.command, .option]),
            item(String(localized: "Show Page Source"), #selector(B.viewSourceAction(_:)), "u", [.command, .option]),
            item(String(localized: "Show Page Resources"), #selector(B.showResourcesAction(_:)), "a", [.command, .option]),
            item(String(localized: "Start Element Selection"), #selector(B.selectElementAction(_:)), "c", [.command, .option, .shift]),
            .separator(),
            item(String(localized: "Reload Page From Origin"), #selector(B.reloadIgnoringCacheAction(_:)), "r", [.command, .option]),
            item(String(localized: "Empty Caches"), #selector(A.emptyCachesAction(_:)), "e", [.command, .option]),
            item(String(localized: "Disable Caches"), #selector(B.toggleDisableCachesAction(_:))),
            item(String(localized: "Clear Site Data"), #selector(B.clearSiteDataAction(_:))),
            .separator(),
            {
                let holder = NSMenuItem(title: String(localized: "Open Page With"), action: nil, keyEquivalent: "")
                let menu = NSMenu(title: String(localized: "Open Page With"))
                menu.identifier = OpenWithMenu.id
                menu.delegate = delegate
                holder.submenu = menu
                return holder
            }(),
            item(String(localized: "Show QR Code for Page"), #selector(B.showPageQRCodeAction(_:))),
            item(String(localized: "Copy as cURL"), #selector(B.copyAsCurlAction(_:))),
            .separator(),
            {
                // Like Safari's Develop > User Agent.
                let holder = NSMenuItem(title: String(localized: "User Agent"), action: nil, keyEquivalent: "")
                let menu = NSMenu(title: String(localized: "User Agent"))
                menu.addItem(item(String(localized: "Default (Askara)"), #selector(B.userAgentAction(_:)), tag: 0))
                menu.addItem(.separator())
                for (index, preset) in UserAgentPreset.all.enumerated() {
                    let entry = item(preset.name, #selector(B.userAgentAction(_:)), tag: index + 1)
                    entry.toolTip = preset.userAgent
                    menu.addItem(entry)
                }
                menu.addItem(.separator())
                menu.addItem(item(String(localized: "Other…"), #selector(B.customUserAgentAction(_:))))
                holder.submenu = menu
                return holder
            }(),
            // Title is set per site in validateMenuItem.
            item(String(localized: "Block JavaScript on This Site"), #selector(B.toggleSiteJavaScriptAction(_:))),
            item(String(localized: "Custom CSS & JavaScript…"), #selector(B.editSiteCodeAction(_:)), "j", [.command, .option, .shift]),
            {
                // Like Chrome's device toolbar (⇧⌘M).
                let holder = NSMenuItem(title: String(localized: "Device Mode"), action: nil, keyEquivalent: "")
                let menu = NSMenu(title: String(localized: "Device Mode"))
                menu.addItem(item(String(localized: "Off"), #selector(B.deviceModeAction(_:)), "m", [.command, .shift], tag: 0))
                menu.addItem(.separator())
                for (index, preset) in DevicePreset.all.enumerated() {
                    menu.addItem(item("\(preset.name) (\(preset.width)×\(preset.height))",
                                      #selector(B.deviceModeAction(_:)), tag: index + 1))
                }
                menu.addItem(item(String(localized: "Custom Size…"), #selector(B.customDeviceSizeAction(_:))))
                menu.addItem(.separator())
                menu.addItem(item(String(localized: "Landscape"), #selector(B.rotateDeviceAction(_:))))
                holder.submenu = menu
                return holder
            }(),
            {
                // Emulates prefers-color-scheme, like Chrome's Rendering panel.
                let holder = NSMenuItem(title: String(localized: "Page Appearance"), action: nil, keyEquivalent: "")
                let menu = NSMenu(title: String(localized: "Page Appearance"))
                menu.addItem(item(String(localized: "Follow System"), #selector(B.colorSchemeAction(_:)), tag: 0))
                menu.addItem(item(String(localized: "Light"), #selector(B.colorSchemeAction(_:)), tag: 1))
                menu.addItem(item(String(localized: "Dark"), #selector(B.colorSchemeAction(_:)), tag: 2))
                holder.submenu = menu
                return holder
            }(),
        ])

        let windowMenu = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Downloads"), #selector(A.showDownloadsAction(_:)), "l", [.command, .option]),
            item(String(localized: "Task Manager"), #selector(A.showTaskManagerAction(_:))),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu
        return main
    }
}
