import Foundation

/// Rendering engines that Askara can host. Availability is decided by the app target because
/// Blink and Gecko require separate runtimes that are not part of AskaraCore.
public enum BrowserEngine: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case webkit
    case blink
    case gecko

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .webkit: "WebKit (Apple)"
        case .blink: "Blink (Chromium)"
        case .gecko: "Gecko (Mozilla)"
        }
    }

    public static func engine(id: String) -> BrowserEngine {
        BrowserEngine(rawValue: id) ?? .webkit
    }
}
