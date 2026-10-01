import AppKit
import WebKit
import AskaraCore
#if ASKARA_CEF
import CEFBridge
#endif

enum BrowserEngineAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

enum BrowserEngineContent {
    /// WebKit pages keep their concrete type: delegates, extensions, and KVO are wired to it.
    case webKit(AskaraWebView)
    /// Any other engine, driven only through the engine-neutral `TabContent` contract.
    case native(any TabContent)
}

enum BrowserEngineRuntimeError: LocalizedError {
    case unavailable(BrowserEngine, String)
    case shutDown(BrowserEngine)

    var errorDescription: String? {
        switch self {
        case .unavailable(let engine, let reason): "\(engine.name) is unavailable: \(reason)"
        case .shutDown(let engine): "\(engine.name) runtime was already shut down"
        }
    }
}

/// One rendering runtime owned by one profile. No runtime instance is shared between profiles.
@MainActor
protocol BrowserEngineRuntime: AnyObject {
    var engine: BrowserEngine { get }
    var availability: BrowserEngineAvailability { get }
    var capabilities: BrowserEngineCapabilities { get }
    /// `privateSession` identifies one private window: its pages share in-memory storage that is
    /// discarded by `endPrivateSession`. `webKitConfiguration` is only evaluated by WebKit.
    func makeContent(frame: NSRect, privateSession: UUID?,
                     webKitConfiguration: () -> WKWebViewConfiguration) throws -> BrowserEngineContent
    func endPrivateSession(_ id: UUID)
    /// Engine-owned website data beyond the profile's WKWebsiteDataStore.
    func clearWebsiteData(completion: @escaping @MainActor () -> Void)
    func shutDown()
}

@MainActor
final class WebKitBrowserEngineRuntime: BrowserEngineRuntime {
    let engine = BrowserEngine.webkit
    let availability = BrowserEngineAvailability.available
    let capabilities: BrowserEngineCapabilities

    init(passkeysAvailable: Bool = Passkey.isAvailable) {
        var values = Dictionary(uniqueKeysWithValues: BrowserEngineFeature.allCases.map {
            ($0, BrowserEngineCapabilities.Capability(.supported))
        })
        values[.webAuthentication] = passkeysAvailable
            ? .init(.supported)
            : .init(.unavailable, note: "The Apple web-browser passkey entitlement is not present")
        values[.deviceEmulation] = .init(.limited, note: "User agent and viewport emulation only")
        values[.processManagement] = .init(.limited, note: "Uses checked private WebKit process APIs")
        capabilities = BrowserEngineCapabilities(values)
    }

    func makeContent(frame: NSRect, privateSession: UUID?,
                     webKitConfiguration: () -> WKWebViewConfiguration) throws -> BrowserEngineContent {
        .webKit(AskaraWebView(frame: frame, configuration: webKitConfiguration()))
    }

    /// Private WebKit windows use their own non-persistent WKWebsiteDataStore instead.
    func endPrivateSession(_ id: UUID) {}
    /// The profile's WKWebsiteDataStore holds all WebKit data and is cleared by ProfileData.
    func clearWebsiteData(completion: @escaping @MainActor () -> Void) { completion() }
    func shutDown() {}
}

/// What Blink via CEF supports inside Askara today. Declared without CEF compiled in, so the
/// matrix is testable and the profile UI can explain limits before a profile switches engines.
enum BlinkEngineCapabilities {
    static let declared: BrowserEngineCapabilities = {
        func unavailable(_ note: String) -> BrowserEngineCapabilities.Capability { .init(.unavailable, note: note) }
        func limited(_ note: String) -> BrowserEngineCapabilities.Capability { .init(.limited, note: note) }
        return BrowserEngineCapabilities([
            .extensions: unavailable("CEF does not run Chrome Web Store extensions"),
            .downloads: unavailable("Blink downloads are not connected to the download manager yet"),
            .contentBlocking: unavailable("The ad blocker and HTTPS-Only upgrades for in-page links apply to WebKit only"),
            .permissions: unavailable("Camera, microphone, and location prompts are not connected for Blink yet"),
            .webAuthentication: unavailable("Passkeys and security keys are untested in CEF"),
            .pictureInPicture: unavailable("Picture in Picture is WebKit only"),
            .developerTools: unavailable("Chromium DevTools are not connected yet"),
            .documentExport: unavailable("Print, screenshots, and source view are WebKit only"),
            .websiteData: limited("Clearing browsing data removes Blink cookies and cache, not other site storage"),
            .processManagement: unavailable("Blink tab memory is not measured or put to sleep by Memory Saver limits"),
            .contextMenu: limited("Uses Chromium's default context menu"),
            .popupHandling: limited("Popups open as tabs; window.opener is not preserved"),
            .deviceEmulation: unavailable("Device Mode is WebKit only"),
        ])
    }()
}

#if ASKARA_CEF
/// Blink runtime of one profile: one persistent CEF request context (cookies, cache, storage)
/// under the profile's own cache directory, plus one in-memory context per private window.
@MainActor
final class BlinkBrowserEngineRuntime: BrowserEngineRuntime {
    let engine = BrowserEngine.blink
    let availability = BrowserEngineAvailability.available
    let capabilities = BlinkEngineCapabilities.declared
    private let cacheDirectory: URL
    private var context: AskaraCEFRequestContext?
    private var privateContexts: [UUID: AskaraCEFRequestContext] = [:]
    private var isShutDown = false

    /// Cheap and side-effect free: the directory and context are created on first use.
    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    func makeContent(frame: NSRect, privateSession: UUID?,
                     webKitConfiguration: () -> WKWebViewConfiguration) throws -> BrowserEngineContent {
        guard !isShutDown else { throw BrowserEngineRuntimeError.shutDown(engine) }
        let requestContext: AskaraCEFRequestContext
        if let privateSession {
            if let existing = privateContexts[privateSession] {
                requestContext = existing
            } else {
                // An empty cache path makes CEF keep everything in memory.
                requestContext = try AskaraCEFBridge.createRequestContext(atCachePath: "")
                privateContexts[privateSession] = requestContext
            }
        } else {
            requestContext = try persistentContext()
        }
        return .native(BlinkTabContent(frame: frame, requestContext: requestContext))
    }

    private func persistentContext() throws -> AskaraCEFRequestContext {
        if let context { return context }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let created = try AskaraCEFBridge.createRequestContext(atCachePath: cacheDirectory.path)
        context = created
        return created
    }

    func endPrivateSession(_ id: UUID) {
        privateContexts.removeValue(forKey: id)?.invalidate()
    }

    func clearWebsiteData(completion: @escaping @MainActor () -> Void) {
        guard !isShutDown, let context = try? persistentContext() else { return completion() }
        context.clearCookiesAndCache { MainActor.assumeIsolated { completion() } }
    }

    func shutDown() {
        isShutDown = true
        context?.invalidate()
        context = nil
        privateContexts.values.forEach { $0.invalidate() }
        privateContexts.removeAll()
    }
}
#endif

@MainActor
final class UnavailableBrowserEngineRuntime: BrowserEngineRuntime {
    let engine: BrowserEngine
    let availability: BrowserEngineAvailability
    let capabilities: BrowserEngineCapabilities
    private let reason: String

    init(engine: BrowserEngine, reason: String) {
        self.engine = engine
        self.reason = reason
        availability = .unavailable(reason: reason)
        capabilities = .unavailable(reason: reason)
    }

    func makeContent(frame: NSRect, privateSession: UUID?,
                     webKitConfiguration: () -> WKWebViewConfiguration) throws -> BrowserEngineContent {
        throw BrowserEngineRuntimeError.unavailable(engine, reason)
    }

    func endPrivateSession(_ id: UUID) {}
    func clearWebsiteData(completion: @escaping @MainActor () -> Void) { completion() }
    func shutDown() {}
}

@MainActor
struct BrowserEngineRegistry {
    /// Receives the profile ID so per-profile runtimes keep their data apart.
    typealias Factory = @MainActor (UUID) -> any BrowserEngineRuntime
    private let factories: [BrowserEngine: Factory]

    init(factories: [BrowserEngine: Factory]? = nil) {
        self.factories = factories ?? [
            .webkit: { _ in WebKitBrowserEngineRuntime() },
            .blink: { id in
#if ASKARA_CEF
                if CEFHost.isInitialized, let directory = CEFHost.cacheDirectory(forProfile: id) {
                    return BlinkBrowserEngineRuntime(cacheDirectory: directory)
                }
#endif
                return UnavailableBrowserEngineRuntime(engine: .blink, reason: CEFHost.unavailableReason)
            },
            .gecko: { _ in
                UnavailableBrowserEngineRuntime(engine: .gecko, reason: "Gecko support is deferred")
            },
        ]
    }

    /// Creates a fresh runtime for a profile. An unavailable configured engine resolves to WebKit,
    /// and the returned runtime reports its real engine so the app never labels the fallback as Blink.
    func makeRuntime(for engine: BrowserEngine, profileID: UUID = Profile.defaultID) -> any BrowserEngineRuntime {
        if let runtime = factories[engine]?(profileID), runtime.availability == .available { return runtime }
        return factories[.webkit]?(profileID) ?? WebKitBrowserEngineRuntime()
    }

    func availability(of engine: BrowserEngine) -> BrowserEngineAvailability {
        factories[engine]?(Profile.defaultID).availability ?? .unavailable(reason: "runtime is not registered")
    }
}
