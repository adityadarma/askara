import AppKit
import WebKit
import AskaraCore

enum BrowserEngineAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// Boundary between browser chrome and an embedded rendering runtime. The content enum will gain
/// Blink and Gecko cases when their native runtimes are linked; unsupported adapters never create
/// a view, rather than silently rendering with the wrong engine.
@MainActor
protocol BrowserEngineAdapter {
    var engine: BrowserEngine { get }
    var availability: BrowserEngineAvailability { get }
    func makeContentView(frame: NSRect, webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent
}

enum BrowserEngineContent {
    case webKit(AskaraWebView)
}

enum BrowserEngineAdapterError: LocalizedError {
    case unavailable(BrowserEngine, String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let engine, let reason): "\(engine.name) is unavailable: \(reason)"
        }
    }
}

@MainActor
struct WebKitBrowserEngineAdapter: BrowserEngineAdapter {
    let engine = BrowserEngine.webkit
    let availability = BrowserEngineAvailability.available

    func makeContentView(frame: NSRect,
                         webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent {
        .webKit(AskaraWebView(frame: frame, configuration: webKitConfiguration))
    }
}

@MainActor
struct BlinkBrowserEngineAdapter: BrowserEngineAdapter {
    let engine = BrowserEngine.blink
    let availability = BrowserEngineAvailability.unavailable(
        reason: "Chromium Embedded Framework (CEF) is not installed"
    )

    func makeContentView(frame: NSRect,
                         webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent {
        throw BrowserEngineAdapterError.unavailable(engine, "Chromium Embedded Framework (CEF) is not installed")
    }
}

@MainActor
struct GeckoBrowserEngineAdapter: BrowserEngineAdapter {
    let engine = BrowserEngine.gecko
    let availability = BrowserEngineAvailability.unavailable(
        reason: "no supported Gecko embedding runtime is installed"
    )

    func makeContentView(frame: NSRect,
                         webKitConfiguration: WKWebViewConfiguration) throws -> BrowserEngineContent {
        throw BrowserEngineAdapterError.unavailable(engine, "no supported Gecko embedding runtime is installed")
    }
}

@MainActor
struct BrowserEngineRegistry {
    let adapters: [any BrowserEngineAdapter]

    init(adapters: [any BrowserEngineAdapter]? = nil) {
        self.adapters = adapters ?? [
            WebKitBrowserEngineAdapter(), BlinkBrowserEngineAdapter(), GeckoBrowserEngineAdapter(),
        ]
    }

    func adapter(for engine: BrowserEngine) -> any BrowserEngineAdapter {
        guard let adapter = adapters.first(where: { $0.engine == engine }),
              adapter.availability == .available else {
            return adapters.first { $0.engine == .webkit && $0.availability == .available }
                ?? WebKitBrowserEngineAdapter()
        }
        return adapter
    }

    func availability(of engine: BrowserEngine) -> BrowserEngineAvailability {
        adapters.first { $0.engine == engine }?.availability
            ?? .unavailable(reason: "adapter is not registered")
    }
}
