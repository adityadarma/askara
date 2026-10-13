import Foundation
import Testing
@testable import AskaraCore

@Suite struct SiteSleepTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func tab(idle seconds: TimeInterval, timeout: TimeInterval? = nil) -> TabSnapshot {
        TabSnapshot(id: UUID(), lastActive: now.addingTimeInterval(-seconds), isLoaded: true, isActive: false,
                    idleTimeout: timeout)
    }

    @Test func siteTimeoutOverridesGlobalIdleTimeout() {
        let policy = HibernationPolicy(idleTimeout: 30 * 60, maxLoadedTabs: 20, dozeAfter: 10 * 60)
        let heavy = tab(idle: 90, timeout: 60)
        let normal = tab(idle: 90)
        let ids = policy.decisions([heavy, normal], now: now).map(\.id)
        #expect(ids == [heavy.id])
    }

    @Test func shortSiteTimeoutAlsoDozesEarly() {
        let policy = HibernationPolicy(idleTimeout: 30 * 60, maxLoadedTabs: 20, dozeAfter: 10 * 60)
        let heavy = tab(idle: 70, timeout: 60)
        #expect(policy.tabsToDoze([heavy, tab(idle: 70)], now: now) == [heavy.id])
    }

    @Test func preferencesMatchMostSpecificSite() throws {
        var prefs = BrowserPreferences()
        #expect(prefs.setSiteSleep("https://www.youtube.com/watch?v=1", minutes: 2) == "youtube.com")
        #expect(prefs.sleepTimeout(host: "m.youtube.com") == 120)
        prefs.setSiteSleep("music.youtube.com", minutes: 30)
        #expect(prefs.sleepTimeout(host: "music.youtube.com") == 1800)
        #expect(prefs.sleepTimeout(host: "example.com") == nil)
        prefs.setSiteSleep("youtube.com", minutes: nil)
        #expect(prefs.sleepTimeout(host: "www.youtube.com") == nil)

        let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.siteSleepMinutes == ["music.youtube.com": 30])
        let old = try JSONDecoder().decode(BrowserPreferences.self, from: Data("{}".utf8))
        #expect(old.siteSleepMinutes.isEmpty)
    }
}
