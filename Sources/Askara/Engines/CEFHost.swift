import AppKit
import AskaraCore

#if ASKARA_CEF
import CEFBridge
#endif

@MainActor
enum CEFHost {
    private(set) static var initializationError: String?
    /// Set while CEF closes every browser for app shutdown, so tabs aren't removed from the session.
    private(set) static var isShuttingDown = false
    private static var rootDirectory: URL?

    /// `scripts/smoke-cef.sh` sets this: the app runs only the Blink smoke test, on throwaway storage.
    static var smokeMarkerPath: String? { ProcessInfo.processInfo.environment["ASKARA_CEF_SMOKE_FILE"] }
    static var isSmokeTest: Bool { smokeMarkerPath != nil }

    static var isCompiledIn: Bool {
#if ASKARA_CEF
        true
#else
        false
#endif
    }

    static var isInitialized: Bool {
#if ASKARA_CEF
        AskaraCEFBridge.isInitialized
#else
        false
#endif
    }

    /// Why Blink cannot be selected right now, for the profile engine picker.
    static var unavailableReason: String {
        if !isCompiledIn { return "Chromium Embedded Framework (CEF) is not installed" }
        return initializationError.map { "CEF failed to start: \($0)" } ?? "CEF is not running"
    }

    /// Per-profile Blink data lives under CEF's root cache path, as CEF requires.
    static func cacheDirectory(forProfile id: UUID) -> URL? {
        guard let rootDirectory else { return nil }
        let generationFile = rootDirectory.appendingPathComponent("ProfileGenerations/\(id.uuidString)")
        if let generation = try? String(contentsOf: generationFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !generation.isEmpty,
           generation != "deleted" {
            return rootDirectory.appendingPathComponent(
                "Profiles/\(id.uuidString)-\(generation)", isDirectory: true)
        }
        return rootDirectory.appendingPathComponent("Profiles/\(id.uuidString)", isDirectory: true)
    }

    static func scheduleWebsiteDataRemoval(forProfile id: UUID) {
        guard let rootDirectory else { return }
        let marker = rootDirectory.appendingPathComponent("ProfileGenerations/\(id.uuidString)")
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data((UUID().uuidString + "\n").utf8).write(to: marker, options: .atomic)
    }

    static func scheduleProfileDataRemoval(forProfile id: UUID) {
        guard let rootDirectory else { return }
        let marker = rootDirectory.appendingPathComponent("ProfileGenerations/\(id.uuidString)")
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("deleted\n".utf8).write(to: marker, options: .atomic)
    }

    private static func removeStaleProfileData(at root: URL) {
        let fileManager = FileManager.default
        let metadata = root.appendingPathComponent("ProfileGenerations", isDirectory: true)
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        guard let markers = try? fileManager.contentsOfDirectory(at: metadata,
                                                                  includingPropertiesForKeys: nil) else { return }
        let directories = (try? fileManager.contentsOfDirectory(at: profiles,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for marker in markers {
            let id = marker.lastPathComponent
            let generation = (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "deleted"
            let currentName = generation == "deleted" ? nil : "\(id)-\(generation)"
            for directory in directories where directory.lastPathComponent == id
                || (directory.lastPathComponent.hasPrefix(id + "-")
                    && directory.lastPathComponent != currentName) {
                try? fileManager.removeItem(at: directory)
            }
            if generation == "deleted" { try? fileManager.removeItem(at: marker) }
        }
    }

    static func start() {
#if ASKARA_CEF
        guard !AskaraCEFBridge.isInitialized else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = smokeMarkerPath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("BlinkRoot", isDirectory: true)
        } ?? support.appendingPathComponent("Askara/Engines/Blink", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            removeStaleProfileData(at: root)
            try AskaraCEFBridge.initialize(withRootCachePath: root.path)
            rootDirectory = root
            if let marker = smokeMarkerPath {
                AskaraCEFBridge.whenReady { CEFSmokeTest.run(marker: URL(fileURLWithPath: marker)) }
            }
        } catch {
            initializationError = error.localizedDescription
            Log.error("Askara: CEF initialization failed: \(error.localizedDescription)")
        }
#endif
    }

    static func stop() {
        isShuttingDown = true
#if ASKARA_CEF
        if isSmokeTest { CEFSmokeTest.prepareShutdown() }
        // Closes any browser still open, waits for them, then shuts CEF down.
        AskaraCEFBridge.shutdown()
#endif
    }
}

#if ASKARA_CEF
/// End-to-end Blink check through the real tab stack: a Blink profile on throwaway storage, a
/// normal and a private window, navigation, and release of every browser when windows close.
/// Each phase is written to the marker file; the script waits for the final "navigated".
@MainActor
private enum CEFSmokeTest {
    private static let title = "Askara Blink Smoke"
    private static var services: BrowserServices?
    private static var profileData: ProfileData?
    private static var controller: BrowserWindowController?
    private static var timer: Timer?

    static func run(marker: URL) {
        func write(_ phase: String) { try? Data((phase + "\n").utf8).write(to: marker, options: .atomic) }
        func fail(_ message: String) {
            write("failed \(message)")
            Log.error("Askara: CEF smoke test failed: \(message)")
            NSApp.terminate(nil)
        }

        let storage = marker.deletingLastPathComponent().appendingPathComponent("AppData", isDirectory: true)
        let downloadDirectory = marker.deletingLastPathComponent()
            .appendingPathComponent("Downloads", isDirectory: true)
        let services = BrowserServices(storageDirectory: storage, downloadDirectory: downloadDirectory,
                                       dataStoreFactory: { _ in .nonPersistent() })
        self.services = services
        guard let profile = services.addProfile(name: "Blink Smoke", browserEngine: .blink) else {
            return fail("profile could not be created")
        }
        let data = services.data(for: profile.id)
        profileData = data
        // The registry falls back to WebKit silently; the smoke test must prove it did not.
        guard data.browserEngine == .blink else { return fail("profile fell back to \(data.browserEngine.name)") }
        write("profile")

        let html = "<html><head><title>\(title)</title></head><body>Blink</body></html>"
        let fallbackURL = URL(string: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())")
        let fixtureURL = ProcessInfo.processInfo.environment["ASKARA_CEF_SMOKE_URL"].flatMap(URL.init(string:))
        guard let url = fixtureURL ?? fallbackURL else {
            return fail("test URL")
        }
        if let host = fixtureURL?.host {
            PermissionKind.allCases.forEach { data.setPermission(.block, for: $0, host: host) }
            services.setCustomization(.init(javaScript: """
                window.customApplied = true;
                if (!location.pathname.startsWith('/popup-')) {
                    document.title = window.permissionsDenied ? 'permissions-denied'
                        : 'custom-' + (window.pageRan ? 'page' : 'blocked')
                            + '-' + (window.adLoaded ? 'loaded' : 'blocked');
                }
                """), host: host)
        }
        let phases: [(name: String, isPrivate: Bool)] = [("normal", false), ("private", true)]
        var index = 0
        var policyStage = 0
        var downloadSettledAt: Date?
        var finalSettledAt: Date?
        var deadline = Date()

        func open() {
            let phase = phases[index]
            let window = BrowserWindowController(profile: data, isPrivate: phase.isPrivate, services: services)
            controller = window
            window.window?.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.showWindow(nil)
            window.newTab(url: url)
            deadline = Date().addingTimeInterval(10)
            write("\(phase.name)-opened")
        }

        open()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if index >= phases.count {
                    guard AskaraCEFBridge.liveBrowserCount == 0 else { return }
                    if finalSettledAt == nil {
                        finalSettledAt = Date().addingTimeInterval(10)
                        return
                    }
                    guard Date() >= finalSettledAt! else { return }
                    timer?.invalidate()
                    write("navigated")
                    NSApp.terminate(nil)
                    return
                }
                let phase = phases[index]
                guard Date() < deadline else {
                    timer?.invalidate()
                    let state = controller?.currentTab.map {
                        let url = $0.content?.url?.absoluteString ?? "nil"
                        return "title=\($0.title) loading=\($0.content?.isLoading ?? false) url=\(url)"
                    } ?? "no tab"
                    return fail("\(phase.name) phase timed out (\(state))")
                }
                if let window = controller {
                    guard let tab = window.currentTab, let content = tab.content else { return }
                    guard content is BlinkTabContent else {
                        timer?.invalidate()
                        return fail("\(phase.name) tab is not a Blink tab")
                    }
                    if fixtureURL != nil, !phase.isPrivate, policyStage == 2 {
                        guard let item = services.downloads.items.first else { return }
                        guard item.state == .finished,
                              let destination = item.destination,
                              FileManager.default.fileExists(atPath: destination.path) else { return }
                        guard item.scanState == .complete else { return }
                        write("download-completed")
                        policyStage = 3
                        downloadSettledAt = Date().addingTimeInterval(1)
                        deadline = Date().addingTimeInterval(10)
                        return
                    }
                    if let downloadSettledAt, Date() < downloadSettledAt { return }
                    let expected: String
                    if fixtureURL == nil {
                        expected = title
                    } else if phase.isPrivate || (1...3).contains(policyStage) {
                        expected = "base"
                    } else if policyStage == 4 {
                        expected = "popup-source"
                    } else if policyStage == 5 {
                        expected = "opener-ok"
                    } else {
                        expected = "permissions-denied"
                    }
                    guard tab.title == expected, !content.isLoading else { return }
                    if fixtureURL != nil, !phase.isPrivate, policyStage == 0,
                       let host = fixtureURL?.host {
                        policyStage = 1
                        services.setJavaScriptBlocked(true, host: host)
                        window.applyBlinkBlockList(domains: services.blockListDomains,
                                                   exceptions: services.siteSettings.adBlockExceptions)
                        window.reloadTabs(relatedTo: host)
                        deadline = Date().addingTimeInterval(10)
                        write("javascript-blocking")
                        return
                    }
                    if fixtureURL != nil, !phase.isPrivate, policyStage == 1,
                       let downloadURL = URL(string: "/download.bin", relativeTo: fixtureURL)?.absoluteURL {
                        policyStage = 2
                        content.load(downloadURL)
                        deadline = Date().addingTimeInterval(10)
                        write("download-started")
                        return
                    }
                    if fixtureURL != nil, !phase.isPrivate, policyStage == 3,
                       let host = fixtureURL?.host,
                       let popupURL = URL(string: "/popup-source.html", relativeTo: fixtureURL)?.absoluteURL {
                        policyStage = 4
                        services.setJavaScriptBlocked(false, host: host)
                        window.applyBlinkBlockList(domains: services.blockListDomains,
                                                   exceptions: services.siteSettings.adBlockExceptions)
                        content.load(popupURL)
                        deadline = Date().addingTimeInterval(10)
                        write("popup-source")
                        return
                    }
                    if policyStage == 4, let blink = content as? BlinkTabContent {
                        policyStage = 5
                        blink.sendMouseClick(at: NSPoint(x: 100, y: 100))
                        deadline = Date().addingTimeInterval(10)
                        write("popup-clicked")
                        return
                    }
                    if policyStage == 5, let host = fixtureURL?.host {
                        guard window.allTabs.count == 2 else { return }
                        write("popup-opener-ok")
                        policyStage = 6
                        services.setJavaScriptBlocked(true, host: host)
                    }
                    if !phase.isPrivate {
                        guard let directory = CEFHost.cacheDirectory(forProfile: profile.id),
                              FileManager.default.fileExists(atPath: directory.path) else {
                            timer?.invalidate()
                            return fail("profile cache directory missing")
                        }
                    }
                    write("\(phase.name)-navigated")
                    // Closing the window must release the tab's browser.
                    window.window?.close()
                    controller = nil
                    return
                }
                guard AskaraCEFBridge.liveBrowserCount == 0 else { return }
                write("\(phase.name)-closed")
                index += 1
                if index < phases.count { return open() }
            }
        }
    }

    static func prepareShutdown() {
        timer?.invalidate()
        timer = nil
        controller = nil
        profileData?.shutDownRuntime()
        profileData = nil
        services = nil
    }
}
#endif
