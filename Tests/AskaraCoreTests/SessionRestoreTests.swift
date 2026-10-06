import Foundation
import Testing
@testable import AskaraCore

@Suite struct SessionRestoreTests {
    private let home = URL(string: "https://www.google.com")!

    private func window(_ urls: [String]) -> SessionState.SavedWindow {
        .init(tabs: urls.map { .init(url: URL(string: $0)!, title: "t") }, activeIndex: 0)
    }

    @Test func untouchedHomePageSessionIsTrivial() {
        #expect(SessionState(windows: []).isTrivial(homeURL: home))
        #expect(SessionState(windows: [window(["https://www.google.com/"])]).isTrivial(homeURL: home))
        #expect(SessionState(windows: [window(["https://google.com"])]).isTrivial(homeURL: home))
    }

    @Test func anythingElseIsWorthKeeping() {
        #expect(!SessionState(windows: [window(["https://example.com"])]).isTrivial(homeURL: home))
        #expect(!SessionState(windows: [window(["https://www.google.com/search?q=swift"])]).isTrivial(homeURL: home))
        #expect(!SessionState(windows: [window(["https://www.google.com", "https://example.com"])]).isTrivial(homeURL: home))
        #expect(!SessionState(windows: [window(["https://www.google.com"]), window(["https://www.google.com"])])
            .isTrivial(homeURL: home))
    }

    @Test func restorePreferenceDefaultsOffAndRoundTrips() throws {
        let old = try JSONDecoder().decode(BrowserPreferences.self, from: Data(#"{"httpsOnly":true}"#.utf8))
        #expect(!old.restoresSession)
        var prefs = BrowserPreferences()
        prefs.restoresSession = true
        let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.restoresSession)
    }
}
