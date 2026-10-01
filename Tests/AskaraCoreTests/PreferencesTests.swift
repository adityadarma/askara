import Foundation
import Testing
@testable import AskaraCore

@Suite struct PreferencesTests {
    @Test func decodesOldFileWithDefaults() throws {
        let prefs = try JSONDecoder().decode(BrowserPreferences.self, from: Data(#"{"httpsOnly":true}"#.utf8))
        #expect(prefs.httpsOnly)
        #expect(prefs.searchEngineID == "google")
        #expect(prefs.maxLoadedTabs == 5)
        #expect(prefs.sleepAfterMinutes == 5)
    }

    @Test func homeURLFallsBackToSearchEngine() {
        var prefs = BrowserPreferences()
        prefs.searchEngineID = "duckduckgo"
        #expect(prefs.homeURL.absoluteString == "https://duckduckgo.com")
        prefs.homePage = "example.com"
        #expect(prefs.homeURL.absoluteString == "https://example.com")
        prefs.searchEngineID = "unknown"
        #expect(prefs.searchEngine.id == "google")
    }

    @Test func searchUsesChosenEngine() {
        let url = SearchEngine.engine(id: "bing").searchURL(for: "a b")
        #expect(url?.absoluteString == "https://www.bing.com/search?q=a%20b")
    }

    @Test func policyFromPreferences() {
        var prefs = BrowserPreferences()
        prefs.sleepAfterMinutes = 0
        prefs.maxLoadedTabs = 100
        let policy = prefs.hibernationPolicy(memoryBudget: nil)
        #expect(policy.idleTimeout == .infinity)
        #expect(policy.maxLoadedTabs == 20)
        #expect(policy.dozeAfter == 60)
        prefs.dozeAfterMinutes = 0
        #expect(prefs.hibernationPolicy(memoryBudget: nil).dozeAfter == .infinity)
        prefs.dozeAfterMinutes = 5
        #expect(prefs.hibernationPolicy(memoryBudget: nil).dozeAfter == 300)
    }

    @Test func memoryLimitAndProtectedTabsSettings() throws {
        let gb: UInt64 = 1_073_741_824
        let old = try JSONDecoder().decode(BrowserPreferences.self, from: Data("{}".utf8))
        #expect(old.memoryBudgetPercent == 25)
        #expect(old.protectedTabs == 2)
        var prefs = old
        #expect(prefs.hibernationPolicy(physicalMemory: 8 * gb).memoryBudget == 8 * gb / 100 * 25)
        #expect(prefs.hibernationPolicy(physicalMemory: 8 * gb).maxGracedTabs == 2)
        prefs.memoryBudgetPercent = 0
        #expect(prefs.hibernationPolicy(physicalMemory: 8 * gb).memoryBudget == nil)
        prefs.memoryBudgetPercent = 12
        // Never below 512 MB on small Macs.
        #expect(prefs.hibernationPolicy(physicalMemory: 2 * gb).memoryBudget == 512 * 1_048_576)
        prefs.protectedTabs = 99
        #expect(prefs.hibernationPolicy(physicalMemory: 8 * gb).maxGracedTabs == 10)
    }

    @Test func dozeSettingDefaultsForOldFiles() throws {
        let prefs = try JSONDecoder().decode(BrowserPreferences.self, from: Data(#"{"sleepAfterMinutes":15}"#.utf8))
        #expect(prefs.dozeAfterMinutes == 1)
        let saved = try JSONDecoder().decode(BrowserPreferences.self,
                                             from: JSONEncoder().encode({ var p = prefs; p.dozeAfterMinutes = 0; return p }()))
        #expect(saved.dozeAfterMinutes == 0)
    }

    @Test func keepAwakeSites() {
        var prefs = BrowserPreferences()
        #expect(prefs.addKeepAwakeSite("https://www.Mail.Google.com/mail/u/0") == "mail.google.com")
        #expect(prefs.addKeepAwakeSite("mail.google.com") == nil)
        #expect(prefs.addKeepAwakeSite("not a site") == nil)
        #expect(prefs.keepsAwake(host: "mail.google.com"))
        #expect(!prefs.keepsAwake(host: "google.com"))
        prefs.removeKeepAwakeSite("mail.google.com")
        #expect(!prefs.keepsAwake(host: "mail.google.com"))
    }
}

@Suite struct HTTPSUpgradeTests {
    @Test func upgradesPublicHTTP() {
        #expect(HTTPSUpgrade.upgradedURL(for: URL(string: "http://example.com/a?b=1")!)?.absoluteString
                == "https://example.com/a?b=1")
        #expect(HTTPSUpgrade.upgradedURL(for: URL(string: "http://example.com:80/")!)?.absoluteString
                == "https://example.com/")
    }

    @Test func leavesLocalAndHTTPSAlone() {
        for text in ["https://example.com", "http://localhost:3000", "http://192.168.1.1", "http://router.local",
                     "http://printer", "http://[::1]:8080", "http://app.test"] {
            #expect(HTTPSUpgrade.upgradedURL(for: URL(string: text)!) == nil, "\(text)")
        }
    }
}

@Suite struct SitePermissionsTests {
    @Test func rememberAndForget() {
        var p = SitePermissions()
        p.set(.allow, for: .camera, host: "Meet.Google.com")
        #expect(p.choice(.camera, host: "meet.google.com") == .allow)
        #expect(p.choice(.camera, host: "google.com") == nil) // exact host only
        p.set(nil, for: .camera, host: "meet.google.com")
        #expect(p.hosts.isEmpty)
    }

    @Test func combinedDecision() {
        var p = SitePermissions()
        p.set(.allow, for: .camera, host: "a.com")
        #expect(p.decision(for: [.camera], host: "a.com") == .allow)
        #expect(p.decision(for: [.camera, .microphone], host: "a.com") == nil)
        p.set(.block, for: .microphone, host: "a.com")
        #expect(p.decision(for: [.camera, .microphone], host: "a.com") == .block)
    }
}

@Suite struct SessionTabStateTests {
    @Test func pinnedAndMutedRoundTripAndOldFilesLoad() throws {
        let window = SessionState.SavedWindow(
            tabs: [.init(url: URL(string: "https://a.com")!, title: "A", isPinned: true, isMuted: true)], activeIndex: 0)
        let decoded = try JSONDecoder().decode(SessionState.SavedWindow.self, from: JSONEncoder().encode(window))
        #expect(decoded.tabs[0].isPinned == true)
        #expect(decoded.tabs[0].isMuted == true)
        // Older files, and files that still contain group data, load fine.
        let old = #"{"windows":[{"tabs":[{"url":"https://a.com","title":"A","groupID":"8C2D9C4E-0F3B-4E5A-9A57-3C1B2A6F7E10"}],"activeIndex":0,"groups":[]}]}"#
        let state = try JSONDecoder().decode(SessionState.self, from: Data(old.utf8))
        #expect(state.windows[0].tabs[0].isPinned == nil)
    }

    @Test func interactionDataRoundTripsAndOldFilesLoadWithoutIt() throws {
        let blob = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) // stand-in for WKWebView's opaque state blob
        let tab = SessionState.SavedTab(url: URL(string: "https://a.com")!, title: "A", interactionData: blob)
        let decoded = try JSONDecoder().decode(SessionState.SavedTab.self, from: JSONEncoder().encode(tab))
        #expect(decoded.interactionData == blob)
        // Sessions saved before this field existed still load, with no interaction data to restore.
        let old = #"{"url":"https://a.com","title":"A"}"#
        let legacy = try JSONDecoder().decode(SessionState.SavedTab.self, from: Data(old.utf8))
        #expect(legacy.interactionData == nil)
    }

    @Test func engineChangeKeepsPortableSessionStateOnly() {
        let tabs = [
            SessionState.SavedTab(url: URL(string: "https://a.com")!, title: "A", isPinned: true,
                                  interactionData: Data([1, 2, 3])),
            SessionState.SavedTab(url: URL(string: "https://b.com")!, title: "B", isMuted: true,
                                  interactionData: Data([4, 5, 6])),
        ]
        let frame = SessionState.SavedFrame(x: 10, y: 20, width: 900, height: 700)
        let state = SessionState(windows: [
            .init(tabs: tabs, activeIndex: 1, frame: frame, isFullScreen: true),
        ])

        let portable = state.portableForEngineChange

        #expect(portable.windows.count == 1)
        #expect(portable.windows[0].tabs.map(\.url) == tabs.map(\.url))
        #expect(portable.windows[0].tabs[0].isPinned == true)
        #expect(portable.windows[0].tabs[1].isMuted == true)
        #expect(portable.windows[0].tabs.allSatisfy { $0.interactionData == nil })
        #expect(portable.windows[0].activeIndex == 1)
        #expect(portable.windows[0].frame == frame)
        #expect(portable.windows[0].isFullScreen == true)
    }
}

@Suite struct KeepAwakeHibernationTests {
    @Test func keepAwakeNeverSleepsButCountsTowardLimit() {
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let pinned = TabSnapshot(id: UUID(), lastActive: old, isLoaded: true, isActive: false, keepAwake: true)
        let active = TabSnapshot(id: UUID(), lastActive: now, isLoaded: true, isActive: true)
        let other = TabSnapshot(id: UUID(), lastActive: now, isLoaded: true, isActive: false)
        let policy = HibernationPolicy(idleTimeout: 60, maxLoadedTabs: 2)
        let result = policy.tabsToHibernate([pinned, active, other], now: now)
        #expect(result == [other.id])
        #expect(policy.tabsToHibernate([pinned, active], now: now, underMemoryPressure: true).isEmpty)
    }
}
