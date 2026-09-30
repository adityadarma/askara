import Foundation
import Testing
@testable import AskaraCore

@Suite struct AddressParserTests {
    @Test func displayHidesRootSlashOnly() {
        #expect(AddressParser.displayString(for: URL(string: "https://www.google.com/")) == "https://www.google.com")
        #expect(AddressParser.displayString(for: URL(string: "https://example.com/a/")) == "https://example.com/a/")
        #expect(AddressParser.displayString(for: URL(string: "https://example.com/?q=1")) == "https://example.com/?q=1")
        #expect(AddressParser.displayString(for: URL(string: "https://example.com/#top")) == "https://example.com/#top")
        #expect(AddressParser.displayString(for: URL(string: "file:///")) == "file:///")
        #expect(AddressParser.displayString(for: nil) == "")
    }

    @Test func fullURLUnchanged() {
        #expect(AddressParser.url(from: "https://example.com/a?b=1")?.absoluteString
                == "https://example.com/a?b=1")
    }

    @Test func bareDomainGetsHTTPS() {
        #expect(AddressParser.url(from: "  example.com  ")?.absoluteString == "https://example.com")
    }

    @Test func localhostGetsHTTP() {
        #expect(AddressParser.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
    }

    @Test func textBecomesSearch() throws {
        let url = try #require(AddressParser.url(from: "lightweight browser low ram & fast"))
        #expect(url.host == "www.google.com")
        #expect(url.path == "/search")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(q == "lightweight browser low ram & fast")
    }

    @Test func singleWordBecomesSearch() {
        #expect(AddressParser.url(from: "swift")?.host == "www.google.com")
    }

    @Test func emptyIsNil() {
        #expect(AddressParser.url(from: "   ") == nil)
    }
}

@Suite struct BlockListExceptionTests {
    @Test func generatedRulesExcludeTopSite() throws {
        let json = BlockList.contentRuleListJSON(domains: ["ads.example"], excludingSites: ["news.example"])
        let data = try #require(json.data(using: .utf8))
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let trigger = try #require(rules.first?["trigger"] as? [String: Any])
        let exclusions = try #require(trigger["unless-top-url"] as? [String])
        #expect(exclusions.first?.contains("news\\.example") == true)
    }
}

@Suite struct HibernationPolicyTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func tab(_ age: TimeInterval, loaded: Bool = true, active: Bool = false) -> TabSnapshot {
        TabSnapshot(id: UUID(), lastActive: now.addingTimeInterval(-age),
                    isLoaded: loaded, isActive: active)
    }

    @Test func activeTabNeverHibernated() {
        let policy = HibernationPolicy(idleTimeout: 10, maxLoadedTabs: 1)
        #expect(policy.tabsToHibernate([tab(1_000, active: true)], now: now,
                                       underMemoryPressure: true).isEmpty)
    }

    @Test func idleTabsHibernated() {
        let policy = HibernationPolicy(idleTimeout: 60, maxLoadedTabs: 10)
        let idle = tab(120)
        #expect(policy.tabsToHibernate([tab(0, active: true), tab(30), idle], now: now) == [idle.id])
    }

    @Test func alreadyHibernatedIgnored() {
        let policy = HibernationPolicy(idleTimeout: 60, maxLoadedTabs: 10)
        #expect(policy.tabsToHibernate([tab(999, loaded: false)], now: now).isEmpty)
    }

    @Test func limitEvictsOldestFirst() {
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 2)
        let a = tab(10), b = tab(30), c = tab(20)
        // Limit 2 = active + 1 background. Keep the newest (a).
        #expect(policy.tabsToHibernate([tab(0, active: true), a, b, c], now: now) == [b.id, c.id])
    }

    @Test func memoryPressureHibernatesAllBackground() {
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 10)
        let a = tab(1), b = tab(2)
        #expect(policy.tabsToHibernate([tab(0, active: true), a, b], now: now,
                                       underMemoryPressure: true) == [a.id, b.id])
    }

    func memTab(_ age: TimeInterval, mb: UInt64, active: Bool = false) -> TabSnapshot {
        TabSnapshot(id: UUID(), lastActive: now.addingTimeInterval(-age), isLoaded: true,
                    isActive: active, memoryBytes: mb * 1_048_576)
    }

    @Test func memoryBudgetEvictsOldestUntilUnderBudget() {
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 10,
                                       memoryBudget: 500 * 1_048_576)
        let active = memTab(0, mb: 200, active: true)
        let newest = memTab(10, mb: 150)
        let middle = memTab(20, mb: 150)
        let oldest = memTab(30, mb: 150)
        // Total 650 MB > 500. Discard the oldest = 500, no longer over.
        #expect(policy.tabsToHibernate([active, newest, middle, oldest], now: now) == [oldest.id])
    }

    @Test func memoryBudgetNeverTouchesActiveTab() {
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 10,
                                       memoryBudget: 100 * 1_048_576)
        let active = memTab(0, mb: 900, active: true)
        let bg = memTab(5, mb: 50)
        #expect(policy.tabsToHibernate([active, bg], now: now) == [bg.id])
    }

    @Test func recentlyUsedTabSparedByMemoryBudget() {
        // Leaving a big tab (Gmail) and switching straight back must not reload it.
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 10,
                                       memoryBudget: 500 * 1_048_576, recentGrace: 300)
        let active = memTab(0, mb: 200, active: true)
        let gmail = memTab(5, mb: 600)
        let old = memTab(900, mb: 100)
        #expect(policy.tabsToHibernate([active, gmail, old], now: now) == [old.id])
    }

    @Test func recentlyUsedTabSparedByTabLimit() {
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 2, recentGrace: 300)
        let recent = tab(10), old = tab(900)
        #expect(policy.tabsToHibernate([tab(0, active: true), recent, old], now: now) == [old.id])
        // Only recent tabs over the limit: nothing sleeps until they age past the grace period.
        #expect(policy.tabsToHibernate([tab(0, active: true), tab(10), tab(20)], now: now).isEmpty)
    }

    @Test func graceCoversOnlyTheMostRecentTabs() {
        // Opening many tabs in a row must not keep all of them awake.
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 2, recentGrace: 300)
        let t1 = tab(10), t2 = tab(20), t3 = tab(30), t4 = tab(40)
        let slept = policy.tabsToHibernate([tab(0, active: true), t1, t2, t3, t4], now: now)
        #expect(Set(slept) == [t3.id, t4.id])
    }

    @Test func warningPressureIgnoresGraceButNotLimits() {
        let policy = HibernationPolicy(idleTimeout: 3_600, maxLoadedTabs: 2, recentGrace: 300)
        let a = tab(10), b = tab(20)
        // Warning: limits apply to recent tabs too, but tabs within the limit stay loaded.
        let slept = policy.decisions([tab(0, active: true), a, b], now: now, pressure: .warning).map(\.id)
        #expect(slept == [b.id])
        // Critical: every background tab.
        let all = policy.decisions([tab(0, active: true), a, b], now: now, pressure: .critical)
        #expect(all.map(\.id) == [a.id, b.id])
        #expect(all.allSatisfy { $0.reason == .memoryCritical })
    }

    @Test func audioTabKeptExceptUnderPressure() {
        let policy = HibernationPolicy(idleTimeout: 60, maxLoadedTabs: 1)
        let music = TabSnapshot(id: UUID(), lastActive: now.addingTimeInterval(-999), isLoaded: true,
                                isActive: false, isPlayingAudio: true)
        let active = tab(0, active: true)
        #expect(policy.tabsToHibernate([active, music], now: now).isEmpty)
        #expect(policy.tabsToHibernate([active, music], now: now, underMemoryPressure: true) == [music.id])
    }

    @Test func unsavedFormNeverHibernated() {
        let policy = HibernationPolicy(idleTimeout: 1, maxLoadedTabs: 1, memoryBudget: 1)
        let form = TabSnapshot(id: UUID(), lastActive: now.addingTimeInterval(-9_999), isLoaded: true,
                               isActive: false, memoryBytes: 900 * 1_048_576, hasUnsavedInput: true)
        let active = tab(0, active: true)
        #expect(policy.tabsToHibernate([active, form], now: now).isEmpty)
        #expect(policy.tabsToHibernate([active, form], now: now, underMemoryPressure: true).isEmpty)
    }

    @Test func defaultBudgetIsClamped() {
        let gb: UInt64 = 1_073_741_824
        #expect(HibernationPolicy.defaultMemoryBudget(physicalMemory: 2 * gb) == 512 * 1_048_576)
        #expect(HibernationPolicy.defaultMemoryBudget(physicalMemory: 8 * gb) == gb)
        #expect(HibernationPolicy.defaultMemoryBudget(physicalMemory: 64 * gb) == 1_536 * 1_048_576)
    }
}

@Suite struct BlockListTests {
    @Test func jsonIsValidRuleList() throws {
        let data = Data(BlockList.contentRuleListJSON().utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(parsed.count == BlockList.domains.count)
        #expect((parsed[0]["trigger"] as? [String: Any])?["url-filter"] is String)
    }

    @Test func filterMatchesDomainAndSubdomainOnly() throws {
        let data = Data(BlockList.contentRuleListJSON(domains: ["ads.com"]).utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let pattern = try #require((parsed[0]["trigger"] as? [String: Any])?["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        #expect(matches("https://x.ads.com/p.js"))
        #expect(matches("http://ads.com/"))
        #expect(!matches("https://myads.com/"))
        #expect(!matches("https://ads.com.example.org/"))
    }
}
