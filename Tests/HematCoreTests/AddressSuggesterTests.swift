import Foundation
import Testing
@testable import HematCore

@Suite struct AddressSuggesterTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func history(_ items: [(String, String, Int)]) -> [HistoryEntry] {
        items.map { HistoryEntry(url: URL(string: $0.0)!, title: $0.1, lastVisited: now, visitCount: $0.2) }
    }

    func urls(_ query: String, _ history: [HistoryEntry], bookmarks: [Bookmark] = [], limit: Int = 6) -> [String] {
        AddressSuggester.suggestions(for: query, history: history, bookmarks: bookmarks, now: now, limit: limit)
            .map(\.url.absoluteString)
    }

    @Test func emptyQueryGivesNothing() {
        let h = history([("https://a.com/", "A", 1)])
        #expect(urls("", h).isEmpty)
        #expect(urls("   ", h).isEmpty)
    }

    @Test func addressPrefixBeatsTitleAndSubstring() {
        let h = history([
            ("https://news.example.com/aset", "Berita", 20),       // "aset" only in the path
            ("https://example.org/", "Laporan Aset Daerah", 20),   // word in the title
            ("https://aset.baliprov.go.id/dashboard", "Dashboard V2", 1),
        ])
        #expect(urls("aset", h).first == "https://aset.baliprov.go.id/dashboard")
    }

    @Test func ignoresSchemeAndWwwInQuery() {
        let h = history([("https://www.github.com/", "GitHub", 1)])
        #expect(urls("https://git", h) == ["https://www.github.com/"])
        #expect(urls("www.github", h) == ["https://www.github.com/"])
        #expect(urls("GITHUB", h) == ["https://www.github.com/"])
    }

    @Test func shorterAddressFirstAmongPrefixMatches() {
        let h = history([
            ("https://aset.baliprov.go.id/dashboard/detail/123", "Detail", 1),
            ("https://aset.baliprov.go.id/", "Aset", 1),
        ])
        #expect(urls("aset.bali", h).first == "https://aset.baliprov.go.id/")
    }

    @Test func moreVisitsRankHigherWhenMatchIsEqual() {
        let h = history([("https://mail.google.com/", "Gmail", 1), ("https://maps.google.com/", "Maps", 30)])
        #expect(urls("ma", h) == ["https://maps.google.com/", "https://mail.google.com/"])
    }

    @Test func allWordsMustMatch() {
        let h = history([("https://a.com/", "Single Sign On Provinsi Bali", 1), ("https://b.com/", "Sign in", 1)])
        #expect(urls("sign bali", h) == ["https://a.com/"])
    }

    @Test func bookmarksIncludedAndMergedWithHistory() {
        let url = URL(string: "https://sso.baliprov.go.id/login")!
        let h = history([("https://sso.baliprov.go.id/login", "", 3)])
        let bookmarks = [Bookmark(url: url, title: "SSO Bali"), Bookmark(url: URL(string: "https://ssl.com/")!, title: "SSL")]
        let result = AddressSuggester.suggestions(for: "ss", history: h, bookmarks: bookmarks, now: now)
        #expect(result.count == 2)
        let sso = result.first { $0.url == url }
        #expect(sso?.kind == .bookmark)
        #expect(sso?.title == "SSO Bali") // empty history title falls back to the bookmark title
    }

    @Test func respectsLimitAndSkipsNonWebURLs() {
        var items = (0..<20).map { ("https://site\($0).com/", "Site", 1) }
        items.append(("file:///tmp/site.html", "Site", 1))
        let result = urls("site", history(items), limit: 4)
        #expect(result.count == 4)
        #expect(!result.contains { $0.hasPrefix("file:") })
    }
}
