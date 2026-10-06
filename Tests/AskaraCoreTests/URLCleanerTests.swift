import Foundation
import Testing
@testable import AskaraCore

@Suite struct URLCleanerTests {
    @Test func removesTrackingParametersAndKeepsOthers() throws {
        let url = try #require(URL(string: "https://example.com/a?id=7&utm_source=x&UTM_Medium=y&fbclid=abc&q=a%20b#top"))
        #expect(URLCleaner.clean(url).absoluteString == "https://example.com/a?id=7&q=a%20b#top")
    }

    @Test func dropsQuestionMarkWhenNothingIsLeft() throws {
        let url = try #require(URL(string: "https://example.com/?gclid=1&utm_campaign=2"))
        #expect(URLCleaner.clean(url).absoluteString == "https://example.com/")
    }

    @Test func leavesCleanAndNonWebURLsUnchanged() throws {
        let clean = try #require(URL(string: "https://example.com/?b=1&a=%2F"))
        #expect(URLCleaner.clean(clean) == clean)
        let file = try #require(URL(string: "file:///tmp/a?utm_source=x"))
        #expect(URLCleaner.clean(file) == file)
        // Names that only resemble tracking parameters stay.
        let lookalike = try #require(URL(string: "https://example.com/?utm=1&source=2&gclidx=3"))
        #expect(URLCleaner.clean(lookalike) == lookalike)
    }
}

@Suite struct TextFragmentTests {
    @Test func shortSelectionIsExactAndEncoded() throws {
        let page = try #require(URL(string: "https://example.com/doc#old"))
        let url = try #require(TextFragment.url(for: page, selection: "  Hello,  world - ok  "))
        #expect(url.absoluteString == "https://example.com/doc#:~:text=Hello%2C%20world%20%2D%20ok")
    }

    @Test func longSelectionUsesStartAndEnd() throws {
        let page = try #require(URL(string: "https://example.com/"))
        let text = (1...40).map { "word\($0)" }.joined(separator: " ")
        let url = try #require(TextFragment.url(for: page, selection: text))
        #expect(url.absoluteString ==
            "https://example.com/#:~:text=word1%20word2%20word3%20word4,word37%20word38%20word39%20word40")
    }

    @Test func nonASCIIIsEncodedAndEmptySelectionGivesNil() throws {
        let page = try #require(URL(string: "https://example.com/"))
        #expect(TextFragment.url(for: page, selection: "kafé")?.absoluteString == "https://example.com/#:~:text=kaf%C3%A9")
        #expect(TextFragment.url(for: page, selection: "  \n ") == nil)
    }
}

@Suite struct LinkFormatTests {
    @Test func markdownEscapesTitleAndURL() throws {
        let url = try #require(URL(string: "https://en.wikipedia.org/wiki/Swift_(language)"))
        #expect(LinkFormat.markdown(title: " Swift [lang]\n", url: url)
            == "[Swift \\[lang\\]](https://en.wikipedia.org/wiki/Swift_%28language%29)")
        let plain = try #require(URL(string: "https://example.com"))
        #expect(LinkFormat.markdown(title: "", url: plain) == "[https://example.com](https://example.com)")
    }
}

@Suite struct TabCleanupTests {
    @Test func keepsActiveTabAmongDuplicates() {
        let urls: [URL?] = ["https://a.com/", "https://b.com/", "https://a.com/#x", nil, "https://b.com/", nil]
            .map { $0.flatMap(URL.init(string:)) }
        #expect(TabCleanup.duplicateIndices(urls: urls, preferring: 2) == [0, 4])
        #expect(TabCleanup.duplicateIndices(urls: urls) == [2, 4])
    }
}

@Suite struct SiteZoomTests {
    @Test func zoomIsPerSiteAndDefaultIsNotStored() throws {
        var settings = SiteSettings()
        settings.setZoom(1.25, host: "www.Example.com")
        #expect(settings.zoom(host: "example.com") == 1.25)
        #expect(settings.zoom(host: "docs.example.com") == nil)
        settings.setZoom(1, host: "example.com")
        #expect(settings.zoom(host: "example.com") == nil)
        // Old files without zoom still decode, and zoom round-trips.
        settings.setZoom(0.9, host: "a.org")
        let decoded = try JSONDecoder().decode(SiteSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.zoom(host: "a.org") == 0.9)
        let old = try JSONDecoder().decode(SiteSettings.self, from: Data(#"{"javaScriptBlocked":[],"customizations":{}}"#.utf8))
        #expect(old.zoom(host: "a.org") == nil)
    }
}
