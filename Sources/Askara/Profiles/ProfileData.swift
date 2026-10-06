import AppKit
import WebKit
import AskaraCore

/// Browser data of one profile: website data store (cookies, logins, cache, localStorage), history,
/// bookmarks, session, site permissions, recently closed tabs, and extensions.
/// Loaded only when a window of the profile opens; extensions unload again when its last window closes.
@MainActor
final class ProfileData {
    let id: UUID
    let dataStore: WKWebsiteDataStore
    let sessionCookies: SessionCookies

    private(set) var history: HistoryStore
    private(set) var bookmarks: BookmarkStore
    /// Remembered camera/microphone/location choices.
    private(set) var permissions: SitePermissions
    var recentlyClosed = RecentlyClosed<RecentlyClosedEntry>(capacity: 25)

    private let historyFile: JSONFile<HistoryStore>
    private let bookmarksFile: JSONFile<BookmarkStore>
    private let sessionFile: JSONFile<SessionState>
    private let permissionsFile: JSONFile<SitePermissions>
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var cookiesRestored = false
    /// Set when the profile is deleted, so pending saves don't recreate its folder.
    private(set) var isDiscarded = false

    private let services: BrowserServices

    init(id: UUID, services suppliedServices: BrowserServices? = nil,
         dataStore suppliedDataStore: WKWebsiteDataStore? = nil, storageDirectory: URL? = nil) {
        self.id = id
        self.services = suppliedServices ?? .shared
        let folder = Profile.folder(for: id)
        // The first profile keeps WebKit's default store, so logins from before profiles existed stay.
        dataStore = suppliedDataStore ?? (id == Profile.defaultID ? .default() : WKWebsiteDataStore(forIdentifier: id))
        if let storageDirectory {
            historyFile = JSONFile(url: storageDirectory.appendingPathComponent("history.json"))
            bookmarksFile = JSONFile(url: storageDirectory.appendingPathComponent("bookmarks.json"))
            sessionFile = JSONFile(url: storageDirectory.appendingPathComponent("session.json"))
            permissionsFile = JSONFile(url: storageDirectory.appendingPathComponent("site-permissions.json"))
        } else {
            historyFile = .inAppSupport(folder + "history.json")
            bookmarksFile = .inAppSupport(folder + "bookmarks.json")
            sessionFile = .inAppSupport(folder + "session.json")
            permissionsFile = .inAppSupport(folder + "site-permissions.json")
        }
        let cookieURL = storageDirectory?.appendingPathComponent("session-cookies.plist")
            ?? JSONFile<Int>.inAppSupport(folder + "session-cookies.plist").url
        sessionCookies = SessionCookies(store: dataStore.httpCookieStore, fileURL: cookieURL)
        history = historyFile.load() ?? HistoryStore()
        bookmarks = bookmarksFile.load() ?? BookmarkStore()
        permissions = permissionsFile.load() ?? SitePermissions()
    }

    var profile: Profile {
        services.profileList.profile(id) ?? Profile(id: id, name: "", colorIndex: 0)
    }

    /// Browser windows of this profile, normal and private.
    var windows: [BrowserWindowController] { services.windows.filter { $0.profile === self } }

    // MARK: - Opening

    /// Restores login cookies without an expiry date (saved on quit) before the first tab loads.
    func prepare(completion: @escaping @MainActor () -> Void) {
        guard !cookiesRestored else { return completion() }
        cookiesRestored = true
        sessionCookies.restore(completion: completion)
    }

    /// Restores every normal window. Background tabs remain asleep, so this does not cause a load storm.
    func restoreSession() -> Bool {
        guard let session = sessionFile.load(), !session.isEmpty else { return false }
        restore(session: session)
        return true
    }

    func restore(session: SessionState) {
        for (index, saved) in session.windows.enumerated() {
            // Keep one global loaded-tab slot for the active tab of each window still to restore.
            let remainingActiveTabs = session.windows.count - index - 1
            services.makeWindow(profile: self, restoring: true)
                .restore(saved, reservedLoadedSlots: remainingActiveTabs)
        }
    }

    // MARK: - Extensions

    private var extensionManager: ExtensionManager?
    var loadedExtensions: ExtensionManager? { extensionManager }

    /// Created (and extensions loaded) when a normal window of this profile first needs it.
    var extensions: ExtensionManager {
        if let extensionManager { return extensionManager }
        let manager = ExtensionManager(profile: self)
        extensionManager = manager
        manager.start()
        return manager
    }

    /// Frees extension background pages when no window of this profile is left.
    func unloadExtensions() {
        extensionManager?.shutDown()
        extensionManager = nil
    }

    // MARK: - Permissions

    func setPermission(_ choice: PermissionChoice?, for kind: PermissionKind, host: String) {
        permissions.set(choice, for: kind, host: host)
        guard !isDiscarded else { return }
        do { try permissionsFile.save(permissions) } catch { Log.error("Askara: failed to save permissions: \(error)") }
        NotificationCenter.default.post(name: .askaraPreferencesChanged, object: nil)
    }

    func resetPermissions(host: String) {
        permissions.removeAll(host: host)
        guard !isDiscarded else { return }
        do { try permissionsFile.save(permissions) } catch { Log.error("Askara: failed to save permissions: \(error)") }
        NotificationCenter.default.post(name: .askaraPreferencesChanged, object: nil)
    }

    // MARK: - History

    func recordVisit(url: URL, title: String?) {
        history.record(url: url, title: title)
        historyChanged()
    }

    func updateHistoryTitle(_ title: String, for url: URL) {
        guard history.updateTitle(title, for: url) else { return }
        historyChanged()
    }

    func removeHistory(urls: [URL]) {
        urls.forEach { history.remove(url: $0) }
        historyChanged()
    }

    /// Clears this profile's history, closed tabs, cookies, cache, and other website data.
    func clearBrowsingData(completion: @escaping @MainActor () -> Void) {
        history.clear()
        recentlyClosed = RecentlyClosed(capacity: 25)
        historyChanged()
        saveHistory()
        sessionCookies.delete()
        FaviconStore.shared.removeAll()
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            MainActor.assumeIsolated { completion() }
        }
    }

    private func historyChanged() {
        NotificationCenter.default.post(name: .askaraHistoryChanged, object: self)
        scheduleSave("history") { $0.saveHistory() }
        services.sync.localDataChanged()
    }

    private func saveHistory() {
        guard !isDiscarded else { return }
        do { try historyFile.save(history) } catch { Log.error("Askara: failed to save history: \(error)") }
    }

    /// Visits from another browser. Saved right away. Returns the number of pages added or updated.
    func importHistory(_ visits: [ImportedVisit]) -> Int {
        let count = history.importVisits(visits)
        NotificationCenter.default.post(name: .askaraHistoryChanged, object: self)
        if !isDiscarded {
            do { try historyFile.save(history) } catch { Log.error("Askara: failed to save history: \(error)") }
        }
        return count
    }

    // MARK: - Bookmarks

    @discardableResult
    func toggleBookmark(url: URL, title: String) -> Bool {
        let added = bookmarks.toggle(url: url, title: title)
        bookmarksChanged()
        return added
    }

    /// Any other bookmark change (folders, moving, editing, importing). Saved right away.
    @discardableResult
    func editBookmarks<T>(_ change: (inout BookmarkStore) -> T) -> T {
        let result = change(&bookmarks)
        bookmarksChanged()
        return result
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
        NotificationCenter.default.post(name: .askaraBookmarksChanged, object: self)
        // Bookmarks change rarely and matter: save immediately.
        guard !isDiscarded else { return }
        do { try bookmarksFile.save(bookmarks) } catch { Log.error("Askara: failed to save bookmarks: \(error)") }
        services.sync.localDataChanged()
    }

    // MARK: - Session

    /// Normal windows of this profile, most recently used first (its active tab opens next launch).
    private var sessionWindows: [BrowserWindowController] {
        windows.filter { !$0.isPrivate }.sorted { $0.lastFocused > $1.lastFocused }
    }

    var hasNormalWindows: Bool { !sessionWindows.isEmpty }

    func scheduleSessionSave() {
        scheduleSave("session") { $0.saveSession($0.currentSession()) }
    }

    /// Structural tab/window changes are checkpointed immediately for app-crash recovery.
    func checkpointSession() { saveSession(currentSession()) }

    func currentSession() -> SessionState {
        SessionState(windows: sessionWindows.map { $0.savedState() })
    }

    func saveSession(_ state: SessionState) {
        saveTasks["session"]?.cancel()
        guard !isDiscarded else { return }
        do { try sessionFile.save(state) } catch { Log.error("Askara: failed to save session: \(error)") }
    }

    /// Called when the app quits: write everything pending.
    func saveAll() {
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        saveHistory()
        if hasNormalWindows { saveSession(currentSession()) }
    }


    func replaceSyncedData(history: HistoryStore, bookmarks: BookmarkStore) {
        self.history = history
        self.bookmarks = bookmarks
        saveHistory()
        if !isDiscarded {
            do { try bookmarksFile.save(bookmarks) } catch { Log.error("Askara: failed to save synced bookmarks: \(error)") }
        }
        NotificationCenter.default.post(name: .askaraHistoryChanged, object: self)
        NotificationCenter.default.post(name: .askaraBookmarksChanged, object: self)
    }

    func syncedSession() -> SessionState { hasNormalWindows ? currentSession() : (sessionFile.load() ?? SessionState(windows: [])) }

    /// The profile was deleted: stop writing files and unload extensions.
    func discard() {
        isDiscarded = true
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        unloadExtensions()
    }

    /// Debounces disk writes so rapid successive changes are written once.
    private func scheduleSave(_ key: String, _ action: @escaping @MainActor (ProfileData) -> Void) {
        saveTasks[key]?.cancel()
        saveTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.isDiscarded else { return }
            self.saveTasks[key] = nil
            action(self)
        }
    }
}
