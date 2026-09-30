import AppKit
import WebKit
import AskaraCore

extension Notification.Name {
    static let askaraHistoryChanged = Notification.Name("AskaraHistoryChanged")
    static let askaraBookmarksChanged = Notification.Name("AskaraBookmarksChanged")
    static let askaraDownloadsChanged = Notification.Name("AskaraDownloadsChanged")
    static let askaraBlockListReady = Notification.Name("AskaraBlockListReady")
    static let askaraDownloadEvent = Notification.Name("AskaraDownloadEvent")
    static let askaraPreferencesChanged = Notification.Name("AskaraPreferencesChanged")
}

struct ClosedTab {
    let url: URL
    let title: String
}

/// App-wide shared state: history, bookmarks, downloads, session, and the window list.
@MainActor
final class BrowserServices {
    static let shared = BrowserServices()

    private(set) var history: HistoryStore
    private(set) var bookmarks: BookmarkStore
    private(set) var ruleList: WKContentRuleList?
    private(set) var windows: [BrowserWindowController] = []
    var recentlyClosed = RecentlyClosed<ClosedTab>(capacity: 25)
    let downloads = DownloadManager()

    private let historyFile = JSONFile<HistoryStore>.inAppSupport("history.json")
    private let bookmarksFile = JSONFile<BookmarkStore>.inAppSupport("bookmarks.json")
    private let sessionFile = JSONFile<SessionState>.inAppSupport("session.json")
    private let siteSettingsFile = JSONFile<SiteSettings>.inAppSupport("site-settings.json")
    private let preferencesFile = JSONFile<BrowserPreferences>.inAppSupport("preferences.json")
    private let permissionsFile = JSONFile<SitePermissions>.inAppSupport("site-permissions.json")
    private var saveTasks: [String: Task<Void, Never>] = [:]
    /// Per-site JavaScript blocking and custom CSS/JavaScript. Kept when browsing data is cleared, like Chrome.
    private(set) var siteSettings: SiteSettings
    /// Settings window (⌘,).
    private(set) var preferences: BrowserPreferences
    /// Remembered camera/microphone/location choices.
    private(set) var permissions: SitePermissions

    private init() {
        history = historyFile.load() ?? HistoryStore()
        bookmarks = bookmarksFile.load() ?? BookmarkStore()
        siteSettings = siteSettingsFile.load() ?? SiteSettings()
        preferences = preferencesFile.load() ?? BrowserPreferences()
        permissions = permissionsFile.load() ?? SitePermissions()
    }

    // MARK: - Preferences & permissions

    func updatePreferences(_ change: (inout BrowserPreferences) -> Void) {
        let before = preferences
        change(&preferences)
        guard preferences != before else { return }
        do { try preferencesFile.save(preferences) } catch { Log.error("Askara: failed to save preferences: \(error)") }
        NotificationCenter.default.post(name: .askaraPreferencesChanged, object: nil)
        // Stricter limits apply right away.
        enforceHibernation()
    }

    /// Sites the user chose to open over HTTP despite HTTPS-Only Mode. Until quit only.
    var httpAllowedHosts: Set<String> = []

    var searchEngine: SearchEngine { preferences.searchEngine }
    var homeURL: URL { preferences.homeURL }

    func setPermission(_ choice: PermissionChoice?, for kind: PermissionKind, host: String) {
        permissions.set(choice, for: kind, host: host)
        savePermissions()
    }

    func removePermissions(host: String) {
        permissions.removeAll(host: host)
        savePermissions()
    }

    private func savePermissions() {
        do { try permissionsFile.save(permissions) } catch { Log.error("Askara: failed to save permissions: \(error)") }
        NotificationCenter.default.post(name: .askaraPreferencesChanged, object: nil)
    }

    // MARK: - Site settings

    func setJavaScriptBlocked(_ blocked: Bool, host: String) {
        siteSettings.setJavaScriptBlocked(blocked, host: host)
        saveSiteSettings()
    }

    func setCustomization(_ customization: SiteCustomization, host: String) {
        siteSettings.setCustomization(customization, host: host)
        saveSiteSettings()
    }

    private func saveSiteSettings() {
        do { try siteSettingsFile.save(siteSettings) } catch { Log.error("Askara: failed to save site settings: \(error)") }
    }

    // MARK: - Windows

    /// The browser window the user is currently using.
    var keyBrowserWindow: BrowserWindowController? {
        if let c = NSApp.keyWindow?.windowController as? BrowserWindowController { return c }
        if let c = NSApp.mainWindow?.windowController as? BrowserWindowController { return c }
        return windows.last
    }

    @discardableResult
    func makeWindow(isPrivate: Bool) -> BrowserWindowController {
        let controller = BrowserWindowController(isPrivate: isPrivate)
        if let last = windows.last?.window, let window = controller.window {
            let topLeft = NSPoint(x: last.frame.minX, y: last.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else {
            controller.window?.setFrameAutosaveName("AskaraMainWindow")
        }
        windows.append(controller)
        controller.showWindow(nil)
        return controller
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        if !controller.isPrivate {
            let remainingNormal = windows.filter { $0 !== controller && !$0.isPrivate }
            if remainingNormal.isEmpty {
                // Last normal window: save it so it is restored when the app reopens.
                saveSession(SessionState(windows: [controller.savedState()]))
            } else {
                controller.savedState().tabs.forEach {
                    recentlyClosed.push(ClosedTab(url: $0.url, title: $0.title))
                }
                scheduleSessionSave()
            }
        }
        windows.removeAll { $0 === controller }
    }

    /// Opens a URL in the active window. `nonPrivate` forces a normal window (e.g. reopening a tab).
    func open(_ url: URL, newTab: Bool, nonPrivate: Bool = false) {
        var target = keyBrowserWindow
        if nonPrivate, target?.isPrivate == true { target = windows.last { !$0.isPrivate } }
        let controller = target ?? makeWindow(isPrivate: false)
        controller.showWindow(nil)
        if newTab { controller.newTab(url: url) } else { controller.load(url) }
    }

    /// Settings window (⌘,).
    lazy var settingsWindow = SettingsWindowController()

    func reopenClosedTab() {
        guard let closed = recentlyClosed.pop() else { return }
        open(closed.url, newTab: true, nonPrivate: true)
    }

    // MARK: - Hibernation (global, across windows)

    /// Sleep timeout and tab count come from Settings; total tab memory ≤ 1/8 RAM (512 MB–1.5 GB).
    var hibernationPolicy: HibernationPolicy {
        preferences.hibernationPolicy(memoryBudget: HibernationPolicy.defaultMemoryBudget())
    }
    /// RAM freed by putting tabs to sleep since launch (Memory Saver, shown in the View menu).
    private(set) var freedBytes: UInt64 = 0
    func recordFreed(_ bytes: UInt64) { freedBytes += bytes }
    private var hibernationTimer: Timer?

    func startHibernationTimer() {
        guard hibernationTimer == nil else { return }
        // Large tolerance so the timer rarely wakes the CPU.
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let services = BrowserServices.shared
                services.enforceHibernation()
                services.windows.forEach { $0.refreshTabStrip() } // audio icon
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        hibernationTimer = timer
    }

    func enforceHibernation(pressure: MemoryPressure = .normal) {
        var seen = Set<pid_t>()
        let snapshots = windows.flatMap { $0.hibernationSnapshots(seenProcesses: &seen) }
        let decisions = hibernationPolicy.decisions(snapshots, pressure: pressure)
        guard !decisions.isEmpty else { return }
        let reasons = Dictionary(decisions.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        windows.forEach { $0.hibernate(tabIDs: Set(reasons.keys), reasons: reasons) }
    }

    /// Memory that closing this WebView actually frees: its process footprint, or 0 when the
    /// process is shared with another loaded tab (then nothing is freed until all of them sleep).
    func exclusiveFootprint(of webView: WKWebView?) -> UInt64 {
        guard let webView, let pid = webView.askaraProcessID else { return 0 }
        let sharers = windows.flatMap(\.loadedWebViews).filter { $0 !== webView && $0.askaraProcessID == pid }
        guard sharers.isEmpty else { return 0 }
        return ProcessMemory.footprint(pid: pid) ?? 0
    }

    // MARK: - Ad blocker

    let blockListUpdater = BlockListUpdater()
    let extensions = ExtensionManager()

    /// Loads the saved blocklist, then updates it automatically once a day.
    func compileBlockList() {
        blockListUpdater.onCompiled = { [weak self] list in
            guard let self else { return }
            self.ruleList = list
            // Replace the old list in all loaded tabs; new tabs use the new one directly.
            self.windows.forEach { $0.applyRuleList(list) }
            NotificationCenter.default.post(name: .askaraBlockListReady, object: nil)
        }
        blockListUpdater.start()
    }

    // MARK: - History

    func recordVisit(url: URL, title: String?) {
        history.record(url: url, title: title)
        historyChanged()
    }

    func updateHistoryTitle(_ title: String, for url: URL) {
        history.updateTitle(title, for: url)
        historyChanged()
    }

    func removeHistory(urls: [URL]) {
        urls.forEach { history.remove(url: $0) }
        historyChanged()
    }

    /// Clears history, closed tabs, cookies, cache, and other website data.
    func clearBrowsingData(completion: @escaping @MainActor () -> Void) {
        history.clear()
        recentlyClosed = RecentlyClosed(capacity: 25)
        historyChanged()
        saveHistory()
        SessionCookies.delete()
        FaviconStore.shared.removeAll()
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            MainActor.assumeIsolated { completion() }
        }
    }

    private func historyChanged() {
        NotificationCenter.default.post(name: .askaraHistoryChanged, object: nil)
        scheduleSave("history") { $0.saveHistory() }
    }

    private func saveHistory() {
        do { try historyFile.save(history) } catch { Log.error("Askara: failed to save history: \(error)") }
    }

    // MARK: - Bookmarks

    @discardableResult
    func toggleBookmark(url: URL, title: String) -> Bool {
        let added = bookmarks.toggle(url: url, title: title)
        bookmarksChanged()
        return added
    }

    func removeBookmarks(ids: [UUID]) {
        ids.forEach { bookmarks.remove(id: $0) }
        bookmarksChanged()
    }

    func renameBookmark(id: UUID, to title: String) {
        bookmarks.rename(id: id, to: title)
        bookmarksChanged()
    }

    private func bookmarksChanged() {
        NotificationCenter.default.post(name: .askaraBookmarksChanged, object: nil)
        // Bookmarks change rarely and matter: save immediately.
        do { try bookmarksFile.save(bookmarks) } catch { Log.error("Askara: failed to save bookmarks: \(error)") }
    }

    // MARK: - Session

    func scheduleSessionSave() {
        scheduleSave("session") { services in
            services.saveSession(services.currentSession())
        }
    }

    private func currentSession() -> SessionState {
        SessionState(windows: windows.filter { !$0.isPrivate }.map { $0.savedState() })
    }

    private func saveSession(_ state: SessionState) {
        saveTasks["session"]?.cancel()
        do { try sessionFile.save(state) } catch { Log.error("Askara: failed to save session: \(error)") }
    }

    /// Restores windows from the last session. Tabs are restored asleep.
    func restoreSession() -> Bool {
        guard let state = sessionFile.load(), !state.isEmpty else { return false }
        for saved in state.windows {
            makeWindow(isPrivate: false).restore(saved)
        }
        return true
    }

    /// Called when the app quits: write everything pending.
    func saveAll() {
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        saveHistory()
        if !windows.filter({ !$0.isPrivate }).isEmpty { saveSession(currentSession()) }
    }

    /// Debounces disk writes so rapid successive changes are written once.
    private func scheduleSave(_ key: String, _ action: @escaping @MainActor (BrowserServices) -> Void) {
        saveTasks[key]?.cancel()
        saveTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.saveTasks[key] = nil
            action(self)
        }
    }
}
