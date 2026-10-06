import Foundation

/// How far back "Clear Browsing Data" reaches.
public enum ClearRange: Int, CaseIterable, Sendable {
    case lastHour, lastDay, lastWeek, lastFourWeeks, allTime

    /// Start of the range, or nil for everything.
    public func startDate(now: Date = Date()) -> Date? {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3_600)
        case .lastDay: return now.addingTimeInterval(-86_400)
        case .lastWeek: return now.addingTimeInterval(-7 * 86_400)
        case .lastFourWeeks: return now.addingTimeInterval(-28 * 86_400)
        case .allTime: return nil
        }
    }
}

/// What "Clear Browsing Data" removes. Bookmarks and downloaded files are never part of it.
public struct BrowsingDataKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Visited pages, recently closed tabs, and site icons.
    public static let history = BrowsingDataKinds(rawValue: 1 << 0)
    /// Cookies and site storage (this signs you out of websites).
    public static let cookiesAndSiteData = BrowsingDataKinds(rawValue: 1 << 1)
    /// Cached images and files.
    public static let cache = BrowsingDataKinds(rawValue: 1 << 2)

    public static let all: BrowsingDataKinds = [.history, .cookiesAndSiteData, .cache]
}
