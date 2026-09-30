import Foundation

public enum PermissionKind: String, Codable, CaseIterable, Sendable {
    case camera, microphone, location
}

public enum PermissionChoice: String, Codable, Sendable {
    case allow, block
}

/// Remembered camera/microphone/location decisions, per site (exact host, like Chrome's per-origin permissions).
public struct SitePermissions: Codable, Equatable, Sendable {
    public private(set) var sites: [String: [String: PermissionChoice]] = [:]

    public init() {}

    public static func key(for host: String) -> String {
        var key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasSuffix(".") { key.removeLast() }
        return key
    }

    public var hosts: [String] { sites.keys.sorted() }

    public func choice(_ kind: PermissionKind, host: String) -> PermissionChoice? {
        sites[Self.key(for: host)]?[kind.rawValue]
    }

    /// nil forgets the choice, so the site is asked again.
    public mutating func set(_ choice: PermissionChoice?, for kind: PermissionKind, host: String) {
        let key = Self.key(for: host)
        guard !key.isEmpty else { return }
        var entry = sites[key] ?? [:]
        entry[kind.rawValue] = choice
        sites[key] = entry.isEmpty ? nil : entry
    }

    public mutating func removeAll(host: String) { sites[Self.key(for: host)] = nil }

    /// For a request covering several kinds (camera + microphone): block if any is blocked,
    /// allow only if all are allowed, otherwise nil (ask the user).
    public func decision(for kinds: [PermissionKind], host: String) -> PermissionChoice? {
        let choices = kinds.map { choice($0, host: host) }
        if choices.contains(.block) { return .block }
        if !choices.isEmpty, choices.allSatisfy({ $0 == .allow }) { return .allow }
        return nil
    }
}
