/// Engine-owned features whose implementation differs between WebKit, Blink, and Gecko.
public enum BrowserEngineFeature: String, CaseIterable, Codable, Hashable, Sendable {
    case extensions
    case downloads
    case contentBlocking
    case permissions
    case webAuthentication
    case pictureInPicture
    case developerTools
    case documentExport
    case websiteData
    case processManagement
    case contextMenu
    case popupHandling
    case deviceEmulation
}

public enum BrowserEngineFeatureSupport: String, Codable, Equatable, Sendable {
    case supported
    case limited
    case unavailable
}

/// Capability matrix exposed by one engine runtime. A feature marked limited is usable but has an
/// engine-specific restriction that the UI should explain rather than silently hiding.
public struct BrowserEngineCapabilities: Equatable, Sendable {
    public struct Capability: Equatable, Sendable {
        public let support: BrowserEngineFeatureSupport
        public let note: String?

        public init(_ support: BrowserEngineFeatureSupport, note: String? = nil) {
            self.support = support
            self.note = note
        }
    }

    private let values: [BrowserEngineFeature: Capability]

    public init(_ values: [BrowserEngineFeature: Capability]) {
        self.values = values
    }

    public subscript(_ feature: BrowserEngineFeature) -> Capability {
        values[feature] ?? Capability(.unavailable, note: "Capability is not declared")
    }

    public func supports(_ feature: BrowserEngineFeature) -> Bool {
        self[feature].support != .unavailable
    }

    public static func unavailable(reason: String) -> BrowserEngineCapabilities {
        BrowserEngineCapabilities(Dictionary(uniqueKeysWithValues: BrowserEngineFeature.allCases.map {
            ($0, Capability(.unavailable, note: reason))
        }))
    }
}
