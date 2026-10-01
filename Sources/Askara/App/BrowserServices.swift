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

struct ClosedTab {
    let url: URL
    let title: String
}

/// App-wide shared state: profiles, settings, downloads, ad blocker, and the window list.
/// Per-profile data (history, bookmarks, logins, session, extensions) lives in `ProfileData`.
@MainActor
final class BrowserServices {
    static let shared = BrowserServices()

    private(set) var ruleList: WKContentRuleList?
    private(set) var windows: [BrowserWindowController] = []
    let downloads = DownloadManager()
    lazy var sync = SyncCoordinator(services: self)

    private let siteSettingsFile: JSONFile<SiteSettings>
    private let preferencesFile: JSONFile<BrowserPreferences>
    private let profilesFile: JSONFile<ProfileList>
    private let storageDirectory: URL?
    private let dataStoreFactory: (UUID) -> WKWebsiteDataStore
    /// Per-site JavaScript blocking and custom CSS/JavaScript. Kept when browsing data is cleared, like Chrome.
    private(set) var siteSettings: SiteSettings
    /// Settings window (⌘,). Shared by all profiles.
    private(set) var preferences: BrowserPreferences
    private(set) var profileList: ProfileList
    let engineRegistry = BrowserEngineRegistry()
    /// Profiles opened since launch.
    private var profileData: [UUID: ProfileData] = [:]
    private var restartingProfileIDs: Set<UUID> = []
    var isRestartingProfile: Bool { !restartingProfileIDs.isEmpty }

    init(storageDirectory: URL? = nil,
         dataStoreFactory: ((UUID) -> WKWebsiteDataStore)? = nil) {
        self.storageDirectory = storageDirectory
        self.dataStoreFactory = dataStoreFactory ?? { id in
            id == Profile.defaultID ? .default() : WKWebsiteDataStore(forIdentifier: id)
        }
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
        profileList = profilesFile.load() ?? ProfileList(defaultName: String(localized: "Main"))
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
        let data = ProfileData(id: resolvedID, services: self, dataStore: dataStoreFactory(resolvedID),
                               storageDirectory: profileDirectory)
        profileData[data.id] = data
        return data
    }

    /// Profile of the window in use, or the last used profile when no window is open.
    var currentProfile: ProfileData { keyBrowserWindow?.profile ?? data(for: profileList.lastUsedID) }

    /// Engine held by this profile's currently loaded runtime, or nil if it has not loaded this launch.
    func loadedEngine(for id: UUID) -> BrowserEngine? { profileData[id]?.browserEngine }

    /// A normal window of this profile became active: it opens at next launch.
    func profileUsed(_ profile: ProfileData) {
        guard profileList.markUsed(profile.id) else { return }
        saveProfiles()
    }

    func addProfile(name: String, browserEngine: BrowserEngine = .webkit) -> Profile? {
        guard let profile = profileList.add(name: name, browserEngine: browserEngine) else { return nil }
        saveProfiles()
        return profile
    }

    func updateProfile(_ id: UUID, name: String, colorIndex: Int,
                       browserEngine: BrowserEngine? = nil) {
        guard profileList.update(id, name: name, colorIndex: colorIndex,
                                 browserEngine: browserEngine) else { return }
        saveProfiles()
    }

    /// Recreates one profile's runtime after its engine changes. Other profiles keep running.
    /// Normal windows are restored from portable tab metadata; private windows are intentionally closed.
    func restartProfile(_ id: UUID, completion: (@MainActor () -> Void)? = nil) {
        guard !restartingProfileIDs.contains(id), let oldData = profileData[id] else {
            openProfile(id)
            completion?()
            return
        }

        let normalWindows = oldData.windows.filter { !$0.isPrivate }.sorted { $0.lastFocused > $1.lastFocused }
        let session = SessionState(windows: normalWindows.map { $0.savedState() }).portableForEngineChange
        oldData.saveAll()
        oldData.saveSession(session)
        oldData.shutDownRuntime()
        restartingProfileIDs.insert(id)

        // Closing a window normally updates the session. During a runtime restart the snapshot above
        // is authoritative, so windowWillClose only removes each controller from the window list.
        oldData.windows.forEach { $0.close() }
        profileData[id] = nil

        // Give AppKit and the old engine views one run-loop turn to release their runtime objects.
        DispatchQueue.main.async {
            let newData = self.data(for: id)
            newData.prepare {
                if session.isEmpty {
                    self.makeWindow(profile: newData).newTab(url: self.homeURL)
                } else {
                    newData.restore(session: session)
                }
                self.restartingProfileIDs.remove(id)
                NSApp.activate()
                completion?()
            }
        }
    }

    /// Closes the profile's windows and deletes all its data: website data, history, bookmarks, session.
    func removeProfile(_ id: UUID) {
        guard profileList.canRemove(id) else { return }
        let data = profileData[id]
        data?.windows.forEach { $0.close() }
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

    /// Opens a profile: its existing normal window if one is open, otherwise a new window with
    /// the tab that was active last time (or the home page).
    func openProfile(_ id: UUID) {
        let profile = data(for: id)
        if let window = profile.windows.filter({ !$0.isPrivate }).max(by: { $0.lastFocused < $1.lastFocused }) {
            window.showWindow(nil)
            return
        }
        profile.prepare {
            if !profile.restoreSession() {
                self.makeWindow(profile: profile).newTab(url: self.homeURL)
            }
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
        if !controller.isPrivate, !restartingProfileIDs.contains(profile.id) {
            let remainingNormal = profile.windows.filter { $0 !== controller && !$0.isPrivate }
            if remainingNormal.isEmpty {
                // Last normal window of this profile: save it so it is restored when the profile reopens.
                profile.saveSession(SessionState(windows: [controller.savedState()]))
            } else {
                controller.savedState().tabs.forEach {
                    profile.recentlyClosed.push(ClosedTab(url: $0.url, title: $0.title))
                }
                profile.scheduleSessionSave()
            }
        }
        windows.removeAll { $0 === controller }
        if !controller.isPrivate, profile.hasNormalWindows { profile.checkpointSession() }
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
        open(closed.url, newTab: true, nonPrivate: true, profile: profile)
    }

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
