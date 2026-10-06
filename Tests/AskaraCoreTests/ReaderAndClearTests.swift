import Foundation
import Testing
@testable import AskaraCore

@Suite struct ClearRangeTests {
    @Test func startDatesGoBackTheRightAmount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ClearRange.lastHour.startDate(now: now) == now.addingTimeInterval(-3_600))
        #expect(ClearRange.lastDay.startDate(now: now) == now.addingTimeInterval(-86_400))
        #expect(ClearRange.lastWeek.startDate(now: now) == now.addingTimeInterval(-604_800))
        #expect(ClearRange.lastFourWeeks.startDate(now: now) == now.addingTimeInterval(-2_419_200))
        #expect(ClearRange.allTime.startDate(now: now) == nil)
    }

    @Test func historyClearsOnlyTheRange() {
        var store = HistoryStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.record(url: URL(string: "https://old.example")!, title: "old", at: now.addingTimeInterval(-7_200))
        store.record(url: URL(string: "https://new.example")!, title: "new", at: now.addingTimeInterval(-60))
        store.clear(since: ClearRange.lastHour.startDate(now: now))
        #expect(store.entries.map(\.url.host) == ["old.example"])
        store.clear(since: ClearRange.allTime.startDate(now: now))
        #expect(store.entries.isEmpty)
    }
}

@Suite struct PageFileNameTests {
    @Test func usesTitleThenHostThenFallback() {
        #expect(PageFileName.suggested(title: "My Page", host: "a.com", pathExtension: "pdf") == "My Page.pdf")
        #expect(PageFileName.suggested(title: "  ", host: "a.com", pathExtension: "pdf") == "a.com.pdf")
        #expect(PageFileName.suggested(title: "", host: nil, pathExtension: "pdf") == "page.pdf")
    }

    @Test func removesPathSeparatorsAndLimitsLength() {
        let name = PageFileName.suggested(title: "../../etc/passwd: a/b", host: nil, pathExtension: "pdf")
        #expect(!name.contains("/"))
        #expect(!name.hasPrefix("."))
        let long = PageFileName.suggested(title: String(repeating: "x", count: 500), host: nil, pathExtension: "pdf")
        #expect(long.count <= 104)
    }
}

@Suite struct ReaderTests {
    private func payload(_ blocks: [[String: Any]], title: String = "Title") -> [String: Any] {
        ["title": title, "byline": "By Someone", "siteName": "Example", "blocks": blocks]
    }

    @Test func parsesBlocksAndDropsRepeatedTitle() throws {
        let article = try #require(ReaderArticle(payload: payload([
            ["t": "h", "level": 1, "text": "title"],
            ["t": "p", "text": "Hello   world\nagain"],
            ["t": "li", "text": "one"],
            ["t": "q", "text": "quote"],
            ["t": "pre", "text": "a\n  b"],
            ["t": "img", "src": "https://example.com/a.png", "text": "alt"],
        ])))
        #expect(article.blocks == [
            .paragraph("Hello world again"), .listItem("one"), .quote("quote"), .code("a\n  b"),
            .image(url: URL(string: "https://example.com/a.png")!, alt: "alt"),
        ])
        #expect(article.byline == "By Someone")
    }

    @Test func rejectsUnsafeOrMalformedInput() throws {
        #expect(ReaderArticle(payload: "nope") == nil)
        #expect(ReaderArticle(payload: ["title": "x"]) == nil)
        let article = try #require(ReaderArticle(payload: payload([
            ["t": "img", "src": "javascript:alert(1)", "text": "x"],
            ["t": "img", "src": "data:text/html,<script>", "text": "x"],
            ["t": "img", "src": "file:///etc/passwd", "text": "x"],
            ["t": "script", "text": "alert(1)"],
            ["t": "p", "text": "\u{0000}\u{202E}ok"],
        ])))
        #expect(article.blocks == [.paragraph("ok")])
    }

    @Test func limitsSizes() throws {
        let many = (0..<(ReaderArticle.maxBlocks + 50)).map { _ in ["t": "p", "text": "x"] as [String: Any] }
        let article = try #require(ReaderArticle(payload: payload(many)))
        #expect(article.blocks.count == ReaderArticle.maxBlocks)
        let huge = try #require(ReaderArticle(payload: payload([["t": "p", "text": String(repeating: "a", count: 50_000)]])))
        #expect(huge.blocks == [.paragraph(String(repeating: "a", count: ReaderArticle.maxTextLength))])
    }

    @Test func readableNeedsEnoughParagraphText() throws {
        let short = try #require(ReaderArticle(payload: payload([["t": "p", "text": "Too short"]])))
        #expect(!short.isReadable)
        let long = try #require(ReaderArticle(payload: payload([
            ["t": "p", "text": String(repeating: "word ", count: 80)]])))
        #expect(long.isReadable)
        #expect(long.readingMinutes >= 1)
    }

    @Test func htmlEscapesEverythingFromThePage() throws {
        let article = try #require(ReaderArticle(payload: payload([
            ["t": "p", "text": "<script>alert('x')</script> & \"q\""],
            ["t": "img", "src": "https://example.com/a.png?x=1&y=\"2\"", "text": "\"><script>"],
            ["t": "h", "level": 2, "text": "<b>bold</b>"],
            ["t": "pre", "text": "<img src=x onerror=alert(1)>"],
        ], title: "<title>evil</title>")))
        let html = ReaderDocument.html(for: article, minutesLabel: "3 min")
        #expect(!html.contains("<script>alert"))
        #expect(!html.contains("<b>bold"))
        #expect(!html.contains("<img src=x"))
        #expect(!html.contains("<title>evil"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("default-src 'none'"))
        // The image address stays inside its attribute: quotes are percent-encoded, & is escaped.
        #expect(html.contains("a.png?x=1&amp;y=%222%22"))
        #expect(html.contains("alt=\"&quot;&gt;&lt;script&gt;\""))
    }
}
