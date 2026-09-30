import Foundation

/// A browser profile, like Chrome's: its own logins, cookies, history, bookmarks, session,
/// site permissions, and extensions. App settings are shared by all profiles.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Index into the app's avatar color palette.
    public var colorIndex: Int

    public init(id: UUID = UUID(), name: String, colorIndex: Int) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
    }

    /// The first profile owns the data from before profiles existed: files in the root of the app
    /// data folder and WebKit's default data store. So nothing is migrated or lost.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public var isDefault: Bool { id == Self.defaultID }

    /// First letters of up to two words: "Kerja Kantor" = "KK", "aditya" = "A".
    public var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// This profile's folder inside the app data folder, with a trailing slash. Empty for the default profile.
    public var folder: String { Self.folder(for: id) }

    public static func folder(for id: UUID) -> String {
        id == defaultID ? "" : "Profiles/\(id.uuidString)/"
    }
}

/// All profiles, saved in profiles.json.
public struct ProfileList: Codable, Equatable {
    public static let colorCount = 8
    public static let maxNameLength = 40

    public private(set) var profiles: [Profile]
    /// Profile of the most recently focused normal window. Opened at launch.
    public private(set) var lastUsedID: UUID
    /// Deleted profiles whose WebKit data store couldn't be removed yet (still in use). Retried at launch.
    public private(set) var pendingRemovals: [UUID]

    public init(defaultName: String) {
        profiles = [Profile(id: Profile.defaultID, name: defaultName, colorIndex: 0)]
        lastUsedID = Profile.defaultID
        pendingRemovals = []
    }

    private enum CodingKeys: String, CodingKey { case profiles, lastUsedID, pendingRemovals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        // No duplicate IDs, and the default profile always exists and comes first,
        // even if the file was edited by hand.
        var seen = Set<UUID>()
        var list = decoded.filter { seen.insert($0.id).inserted }
        if let index = list.firstIndex(where: \.isDefault) {
            list.insert(list.remove(at: index), at: 0)
        } else {
            list.insert(Profile(id: Profile.defaultID, name: "Main", colorIndex: 0), at: 0)
        }
        profiles = list
        let last = try c.decodeIfPresent(UUID.self, forKey: .lastUsedID) ?? Profile.defaultID
        lastUsedID = profiles.contains { $0.id == last } ? last : Profile.defaultID
        pendingRemovals = try c.decodeIfPresent([UUID].self, forKey: .pendingRemovals) ?? []
    }

    public func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }
    public var lastUsed: Profile { profile(lastUsedID) ?? profiles[0] }

    /// Trimmed, shortened name; nil when empty.
    public static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Adds a profile with the first color not used yet, so profiles are easy to tell apart.
    @discardableResult
    public mutating func add(name: String) -> Profile? {
        guard let name = Self.cleanName(name) else { return nil }
        let used = Set(profiles.map(\.colorIndex))
        let color = (0..<Self.colorCount).first { !used.contains($0) } ?? profiles.count % Self.colorCount
        let profile = Profile(name: name, colorIndex: color)
        profiles.append(profile)
        return profile
    }

    @discardableResult
    public mutating func update(_ id: UUID, name: String, colorIndex: Int) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }), let name = Self.cleanName(name) else { return false }
        profiles[index].name = name
        profiles[index].colorIndex = min(max(0, colorIndex), Self.colorCount - 1)
        return true
    }

    /// The default profile can't be removed, so there is always at least one.
    public func canRemove(_ id: UUID) -> Bool { id != Profile.defaultID && profile(id) != nil }

    /// Removes the profile and queues its WebKit data store for removal.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard canRemove(id) else { return false }
        profiles.removeAll { $0.id == id }
        if lastUsedID == id { lastUsedID = Profile.defaultID }
        if !pendingRemovals.contains(id) { pendingRemovals.append(id) }
        return true
    }

    /// Returns true if it changed (so the caller only writes the file when needed).
    @discardableResult
    public mutating func markUsed(_ id: UUID) -> Bool {
        guard id != lastUsedID, profile(id) != nil else { return false }
        lastUsedID = id
        return true
    }

    public mutating func storeRemoved(_ id: UUID) { pendingRemovals.removeAll { $0 == id } }
}
