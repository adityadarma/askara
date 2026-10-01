import AppKit

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
        rootDirectory?.appendingPathComponent("Profiles/\(id.uuidString)", isDirectory: true)
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
        let services = BrowserServices(storageDirectory: storage, dataStoreFactory: { _ in .nonPersistent() })
        self.services = services
        guard let profile = services.addProfile(name: "Blink Smoke", browserEngine: .blink) else {
            return fail("profile could not be created")
        }
        let data = services.data(for: profile.id)
        // The registry falls back to WebKit silently; the smoke test must prove it did not.
        guard data.browserEngine == .blink else { return fail("profile fell back to \(data.browserEngine.name)") }
        write("profile")

        let html = "<html><head><title>\(title)</title></head><body>Blink</body></html>"
        guard let url = URL(string: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())") else {
            return fail("test URL")
        }
        let phases: [(name: String, isPrivate: Bool)] = [("normal", false), ("private", true)]
        var index = 0
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
                let phase = phases[index]
                guard Date() < deadline else {
                    timer?.invalidate()
                    return fail("\(phase.name) phase timed out")
                }
                if let window = controller {
                    guard let tab = window.currentTab, let content = tab.content else { return }
                    guard content is BlinkTabContent else {
                        timer?.invalidate()
                        return fail("\(phase.name) tab is not a Blink tab")
                    }
                    guard tab.title == title, !content.isLoading else { return }
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
                timer?.invalidate()
                write("navigated")
                NSApp.terminate(nil)
            }
        }
    }
}
#endif
