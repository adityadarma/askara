import Foundation

/// Simple JSON storage in Application Support. Writes atomically.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// App data folder. Development builds declare a separate folder in Info.plist so they cannot
    /// overwrite sessions, bookmarks, or settings belonging to the released browser.
    public static var appSupportDirectory: URL {
        let name = Bundle.main.object(forInfoDictionaryKey: "AskaraApplicationSupportDirectory") as? String ?? "Askara"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func inAppSupport(_ name: String) -> JSONFile {
        JSONFile(url: appSupportDirectory.appendingPathComponent(name))
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
