import Foundation

public struct PasswordOrigin: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int?

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "https", var host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        self.host = host
        port = url.port == 443 ? nil : url.port
    }

    public var displayName: String { port.map { "https://\(host):\($0)" } ?? "https://\(host)" }
}

public struct PasswordCredential: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let origin: PasswordOrigin
    public var username: String
    public let createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), origin: PasswordOrigin, username: String,
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.origin = origin
        self.username = username
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
