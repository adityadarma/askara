import AppKit
import WebKit
import AskaraCore

enum BrowserEngineAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

enum BrowserEngineContent {
    case webKit(AskaraWebView)
}

enum BrowserEngineRuntimeError: LocalizedError {
    case unavailable(BrowserEngine, String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let engine, let reason): "\(engine.name) is unavailable: \(reason)"
        }
    }
}

/// One rendering runtime owned by one profile. Feature-specific adapters will be added to this
/// boundary incrementally; no runtime instance is shared between profiles.
@MainActor
protocol BrowserEngineRuntime: AnyObject {
    var engine: BrowserEngine { get }
    var availability: BrowserEngineAvailability { get }
    var capabilities: BrowserEngineCapabilities { get }
    func makeContentView(frame: NSRect, webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent
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

    func makeContentView(frame: NSRect,
                         webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent {
        .webKit(AskaraWebView(frame: frame, configuration: webKitConfiguration))
    }

    func shutDown() {}
}

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

    func makeContentView(frame: NSRect,
                         webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent {
        throw BrowserEngineRuntimeError.unavailable(engine, reason)
    }

    func shutDown() {}
}

@MainActor
struct BrowserEngineRegistry {
    typealias Factory = @MainActor () -> any BrowserEngineRuntime
    private let factories: [BrowserEngine: Factory]

    init(factories: [BrowserEngine: Factory]? = nil) {
        self.factories = factories ?? [
            .webkit: { WebKitBrowserEngineRuntime() },
            .blink: {
                UnavailableBrowserEngineRuntime(engine: .blink,
                                                reason: CEFHost.isCompiledIn
                                                    ? "CEF is installed; Blink tab integration is still in progress"
                                                    : "Chromium Embedded Framework (CEF) is not installed")
            },
            .gecko: {
                UnavailableBrowserEngineRuntime(engine: .gecko,
                                                reason: "Gecko support is deferred")
            },
        ]
    }

    /// Creates a fresh runtime for a profile. An unavailable configured engine resolves to WebKit,
    /// and the returned runtime reports its real engine so the app never labels the fallback as Blink.
    func makeRuntime(for engine: BrowserEngine) -> any BrowserEngineRuntime {
        if let runtime = factories[engine]?(), runtime.availability == .available { return runtime }
        return factories[.webkit]?() ?? WebKitBrowserEngineRuntime()
    }

    func availability(of engine: BrowserEngine) -> BrowserEngineAvailability {
        factories[engine]?().availability ?? .unavailable(reason: "runtime is not registered")
    }
}
