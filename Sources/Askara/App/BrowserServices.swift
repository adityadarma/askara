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
    static let askaraProfilesChanged = Notification.Name("AskaraProfilesChanged")
    static let askaraSyncChanged = Notification.Name("AskaraSyncChanged")
}

enum RecentlyClosedEntry {
    case tab(id: UUID, closedAt: Date, tab: SessionState.SavedTab)
    case window(id: UUID, closedAt: Date, window: SessionState.SavedWindow)

    var id: UUID {
        switch self {
        case .tab(let id, _, _), .window(let id, _, _): id
        }
    }
}

/// App-wide shared state: profiles, settings, downloads, ad blocker, and the window list.
/// Per-profile data (history, bookmarks, logins, session, extensions) lives in `ProfileData`.
@MainActor
final class BrowserServices {
    static let shared = BrowserServices()

    private(set) var ruleList: WKContentRuleList?
    var blockListDomains: [String] { blockListUpdater.currentDomains }
    private(set) var windows: [BrowserWindowController] = []
    let downloads: DownloadManager
    lazy var sync = SyncCoordinator(services: self)

    private let siteSettingsFile: JSONFile<SiteSettings>
    private let preferencesFile: JSONFile<BrowserPreferences>
    private let profilesFile: JSONFile<ProfileList>
    private let storageDirectory: URL?
    /// Per-site JavaScript blocking and custom CSS/JavaScript. Kept when browsing data is cleared, like Chrome.
    private(set) var siteSettings: SiteSettings
    /// Settings window (⌘,). Shared by all profiles.
    private(set) var preferences: BrowserPreferences
    private(set) var profileList: ProfileList
    /// Profiles opened since launch.
    private var profileData: [UUID: ProfileData] = [:]
    private var isTerminating = false
    private var suppressCloseRecording = false

    init(storageDirectory: URL? = nil, downloadDirectory: URL? = nil) {
        let downloadsFile = storageDirectory.map { JSONFile<DownloadHistory>(url: $0.appendingPathComponent("downloads.json")) }
            ?? JSONFile<DownloadHistory>.inAppSupport("downloads.json")
        downloads = DownloadManager(directory: downloadDirectory, historyFile: downloadsFile)
        self.storageDirectory = storageDirectory
        if let storageDirectory {
            siteSettingsFile = JSONFile(url: storageDirectory.appendingPathComponent("site-settings.json"))
            preferencesFile = JSONFile(url: storageDirectory.appendingPathComponent("preferences.json"))
            profilesFile = JSONFile(url: storageDirectory.appendingPathComponent("profiles.json"))
        } else {
            siteSettingsFile = .inAppSupport("site-settings.json")
            preferencesFile = .inAppSupport("preferences.json")
            profilesFile = .inAppSupport("profiles.json")
        }
        siteSettings = siteSettingsFile.load() ?? SiteSettings()
        preferences = preferencesFile.load() ?? BrowserPreferences()
        let savedProfiles = profilesFile.load()
        profileList = savedProfiles ?? ProfileList(defaultName: String(localized: "Main"))
        // Rewrite old profiles without the removed browserEngineID field.
        if savedProfiles != nil { try? profilesFile.save(profileList) }
        // CEF is no longer bundled. Its cache contains no profile metadata worth preserving.
        if storageDirectory == nil {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: support.appendingPathComponent("Askara/Engines/Blink"))
        }
    }

    // MARK: - Preferences

    func updatePreferences(_ change: (inout BrowserPreferences) -> Void) {
        let before = preferences
        change(&preferences)
        guard preferences != before else { return }
        do { try preferencesFile.save(preferences) } catch { Log.error("Askara: failed to save preferences: \(error)") }
        NotificationCenter.default.post(name: .askaraPreferencesChanged, object: nil)
        sync.localDataChanged()
        // Stricter limits apply right away.
        enforceHibernation()
    }

    /// Sites the user chose to open over HTTP despite HTTPS-Only Mode. Until quit only.
    var httpAllowedHosts: Set<String> = []

    var searchEngine: SearchEngine { preferences.searchEngine }
    var homeURL: URL { preferences.homeURL }

    // MARK: - Site settings

    func setJavaScriptBlocked(_ blocked: Bool, host: String) {
        siteSettings.setJavaScriptBlocked(blocked, host: host)
        saveSiteSettings()
    }

    func setAdBlockDisabled(_ disabled: Bool, host: String) {
        siteSettings.setAdBlockDisabled(disabled, host: host)
        saveSiteSettings()
        blockListUpdater.recompile()
        windows.forEach { $0.reloadTabs(relatedTo: host) }
    }

    func setCustomization(_ customization: SiteCustomization, host: String) {
        siteSettings.setCustomization(customization, host: host)
        saveSiteSettings()
    }

    private func saveSiteSettings() {
        do { try siteSettingsFile.save(siteSettings) } catch { Log.error("Askara: failed to save site settings: \(error)") }
    }

    // MARK: - Profiles

    /// Loaded data for a profile (created on first use).
    func data(for id: UUID) -> ProfileData {
        if let data = profileData[id] { return data }
        let resolvedID = profileList.profile(id) != nil ? id : Profile.defaultID
        let profileDirectory = storageDirectory?.appendingPathComponent(Profile.folder(for: resolvedID),
                                                                         isDirectory: true)
        let dataStore = resolvedID == Profile.defaultID ? WKWebsiteDataStore.default()
            : WKWebsiteDataStore(forIdentifier: resolvedID)
        let data = ProfileData(id: resolvedID, services: self, dataStore: dataStore,
                               storageDirectory: profileDirectory)
        profileData[data.id] = data
        return data
    }

    /// Profile of the window in use, or the last used profile when no window is open.
    var currentProfile: ProfileData { keyBrowserWindow?.profile ?? data(for: profileList.lastUsedID) }

    /// A normal window of this profile became active: it opens at next launch.
    func profileUsed(_ profile: ProfileData) {
        guard profileList.markUsed(profile.id) else { return }
        saveProfiles()
    }

    func addProfile(name: String) -> Profile? {
        guard let profile = profileList.add(name: name) else { return nil }
        saveProfiles()
        return profile
    }

    func updateProfile(_ id: UUID, name: String, colorIndex: Int) {
        guard profileList.update(id, name: name, colorIndex: colorIndex) else { return }
        saveProfiles()
    }

    /// Closes the profile's windows and deletes all its data: website data, history, bookmarks, session.
    func removeProfile(_ id: UUID) {
        guard profileList.canRemove(id) else { return }
        let data = profileData[id]
        suppressCloseRecording = true
        data?.windows.forEach { $0.close() }
        suppressCloseRecording = false
        data?.discard()
        profileData[id] = nil
        profileList.remove(id)
        saveProfiles()
        let folder = storageDirectory?.appendingPathComponent(Profile.folder(for: id), isDirectory: true)
            ?? JSONFile<Int>.inAppSupport(Profile.folder(for: id)).url
        do { try FileManager.default.removeItem(at: folder) } catch CocoaError.fileNoSuchFile {} catch {
            Log.error("Askara: failed to delete profile folder: \(error)")
        }
        // WebKit can only remove the store once no web view uses it; closed web views go away
        // on the next run loop turn. If it's still busy, it is retried at the next launch.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.removeDataStores() } }
    }

    /// Removes WebKit data stores of deleted profiles.
    func removeDataStores() {
        for id in profileList.pendingRemovals where profileData[id] == nil {
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                MainActor.assumeIsolated {
                    if let error {
                        Log.error("Askara: profile data store not removed yet (retried at next launch): \(error)")
                        return
                    }
                    self.profileList.storeRemoved(id)
                    self.saveProfiles()
                }
            }
        }
    }

    private func saveProfiles() {
        do { try profilesFile.save(profileList) } catch { Log.error("Askara: failed to save profiles: \(error)") }
        NotificationCenter.default.post(name: .askaraProfilesChanged, object: nil)
    }

    /// Opens a profile: its existing normal window if one is open, otherwise a fresh window with
    /// exactly one home-page tab. Session state remains a crash-recovery record only; it is not
    /// restored automatically so each browser launch starts clean.
    func openProfile(_ id: UUID) {
        let profile = data(for: id)
        if let window = profile.windows.filter({ !$0.isPrivate }).max(by: { $0.lastFocused < $1.lastFocused }) {
            window.showWindow(nil)
            return
        }
        profile.prepare {
            self.makeWindow(profile: profile).newTab(url: self.homeURL)
            NSApp.activate()
        }
    }

    // MARK: - Windows

    /// The browser window the user is currently using.
    var keyBrowserWindow: BrowserWindowController? {
        if let c = NSApp.keyWindow?.windowController as? BrowserWindowController { return c }
        if let c = NSApp.mainWindow?.windowController as? BrowserWindowController { return c }
        return windows.max { $0.lastFocused < $1.lastFocused }
    }

    @discardableResult
    func makeWindow(profile: ProfileData? = nil, isPrivate: Bool = false,
                    restoring: Bool = false) -> BrowserWindowController {
        let controller = BrowserWindowController(profile: profile ?? currentProfile, isPrivate: isPrivate,
                                                 services: self)
        if !restoring, let last = windows.last?.window, let window = controller.window {
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
        let profile = controller.profile
        if !controller.isPrivate, !isTerminating, !suppressCloseRecording {
            let saved = controller.savedState()
            if !saved.tabs.isEmpty {
                profile.recentlyClosed.push(.window(id: UUID(), closedAt: Date(), window: saved))
            }
        }
        windows.removeAll { $0 === controller }
        if !controller.isPrivate { profile.saveSession(profile.currentSession()) }
        // No window left for this profile: free its extension background pages.
        if !profile.windows.contains(where: { !$0.isPrivate }) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !profile.windows.contains(where: { !$0.isPrivate }) { profile.unloadExtensions() }
                }
            }
        }
    }

    /// Opens a URL in the active window. `nonPrivate` forces a normal window (e.g. reopening a tab).
    /// `profile` limits it to that profile's windows.
    func open(_ url: URL, newTab: Bool, nonPrivate: Bool = false, profile: ProfileData? = nil) {
        var target = keyBrowserWindow
        if let profile, target?.profile !== profile { target = nil }
        let profile = profile ?? target?.profile ?? currentProfile
        if target == nil || (nonPrivate && target?.isPrivate == true) {
            target = profile.windows.filter { !$0.isPrivate }.max { $0.lastFocused < $1.lastFocused }
        }
        let controller = target ?? makeWindow(profile: profile)
        controller.showWindow(nil)
        if newTab { controller.newTab(url: url) } else { controller.load(url) }
    }

    /// Settings window (⌘,).
    lazy var settingsWindow = SettingsWindowController()

    func reopenClosedTab() {
        let profile = currentProfile
        guard let closed = profile.recentlyClosed.pop() else { return }
        restore(closed, profile: profile)
    }

    func reopenRecentlyClosed(_ id: UUID, profile: ProfileData, selectedTab: Int? = nil) {
        guard let closed = profile.recentlyClosed.pop(where: { $0.id == id }) else { return }
        restore(closed, profile: profile, selectedTab: selectedTab)
    }

    private func restore(_ entry: RecentlyClosedEntry, profile: ProfileData, selectedTab: Int? = nil) {
        switch entry {
        case .tab(_, _, let saved):
            let target = profile.windows.filter { !$0.isPrivate }.max { $0.lastFocused < $1.lastFocused }
                ?? makeWindow(profile: profile, restoring: true)
            target.restoreTab(saved)
            target.window?.makeKeyAndOrderFront(nil)
        case .window(_, _, var saved):
            if let selectedTab, saved.tabs.indices.contains(selectedTab) { saved.activeIndex = selectedTab }
            let target = makeWindow(profile: profile, restoring: true)
            target.restore(saved)
            target.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    func beginTermination() { isTerminating = true }

    // MARK: - Hibernation (global, across windows)

    /// Sleep timeout, tab count, memory limit (share of RAM), and protected tabs all come from Settings.
    var hibernationPolicy: HibernationPolicy { preferences.hibernationPolicy() }
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
        if pressure != .normal { windows.forEach { $0.discardSpareNewTab() } }
        var seen = Set<pid_t>()
        let snapshots = windows.flatMap { $0.hibernationSnapshots(seenProcesses: &seen) }
        let policy = hibernationPolicy
        let decisions = policy.decisions(snapshots, pressure: pressure)
        // Step 1 for tabs that aren't sleeping yet: doze (page kept, media suspended, caches freed).
        let sleeping = Set(decisions.map(\.id))
        let dozing = Set(policy.tabsToDoze(snapshots)).subtracting(sleeping)
        if !dozing.isEmpty { windows.forEach { $0.doze(tabIDs: dozing) } }
        // Step 2: sleep fully (idle timeout, tab/memory limits, memory pressure).
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

    lazy var blockListUpdater = BlockListUpdater(storageDirectory: storageDirectory, services: self)

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

    // MARK: - Saving

    /// Called when the app quits: write everything pending.
    func saveAll() {
        profileData.values.forEach { $0.saveAll() }
        sync.pushNow()
    }


    func applySyncedPreferences(_ synced: BrowserPreferences) {
        preferences = synced
        do { try preferencesFile.save(preferences) } catch { Log.error("Askara: failed to save synced preferences: \(error)") }
        NotificationCenter.default.post(name: .askaraPreferencesChanged, object: nil)
    }

    /// Session cookies of every opened profile. `completion` runs once all are written.
    func saveSessionCookies(completion: @escaping @MainActor () -> Void) {
        let group = DispatchGroup()
        for profile in profileData.values where !profile.isDiscarded {
            group.enter()
            profile.sessionCookies.save { group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion() } }
    }

}
