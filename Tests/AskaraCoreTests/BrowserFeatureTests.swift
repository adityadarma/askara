import Foundation
import Testing
@testable import AskaraCore

@Suite struct HistoryStoreTests {
    let a = URL(string: "https://a.com/")!
    let b = URL(string: "https://b.com/")!

    @Test func revisitMovesToFrontAndCounts() {
        var h = HistoryStore()
        h.record(url: a, title: "A", at: Date(timeIntervalSince1970: 1))
        h.record(url: b, title: "B", at: Date(timeIntervalSince1970: 2))
        h.record(url: a, title: "", at: Date(timeIntervalSince1970: 3))
        #expect(h.entries.map(\.url) == [a, b])
        #expect(h.entries[0].visitCount == 2)
        #expect(h.entries[0].title == "A") // empty title doesn't overwrite
    }

    @Test func ignoresNonWebSchemes() {
        var h = HistoryStore()
        h.record(url: URL(string: "about:blank")!, title: "x")
        h.record(url: URL(string: "file:///tmp/a")!, title: "x")
        #expect(h.entries.isEmpty)
    }

    @Test func limitDropsOldest() {
        var h = HistoryStore(limit: 2)
        for i in 0..<5 { h.record(url: URL(string: "https://s\(i).com")!, title: "") }
        #expect(h.entries.map(\.url.host) == ["s4.com", "s3.com"])
    }

    @Test func searchMatchesAllWords() {
        var h = HistoryStore()
        h.record(url: URL(string: "https://swift.org/docs")!, title: "Swift Docs")
        h.record(url: URL(string: "https://rust-lang.org")!, title: "Rust")
        #expect(h.search("swift DOCS").count == 1)
        #expect(h.search("swift rust").isEmpty)
        #expect(h.search("").count == 2)
    }

    @Test func clearSince() {
        var h = HistoryStore()
        h.record(url: a, title: "", at: Date(timeIntervalSince1970: 10))
        h.record(url: b, title: "", at: Date(timeIntervalSince1970: 100))
        h.clear(since: Date(timeIntervalSince1970: 50))
        #expect(h.entries.map(\.url) == [a])
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = JSONFile<HistoryStore>(url: dir.appendingPathComponent("h.json"))
        var h = HistoryStore()
        h.record(url: a, title: "A", at: Date(timeIntervalSince1970: 1_000))
        try file.save(h)
        #expect(file.load() == h)
    }
}

@Suite struct BookmarkStoreTests {
    let url = URL(string: "https://example.com")!

    @Test func toggleAddsThenRemoves() {
        var s = BookmarkStore()
        #expect(s.toggle(url: url, title: "Ex") == true)
        #expect(s.contains(url))
        #expect(s.toggle(url: url, title: "Ex") == false)
        #expect(!s.contains(url))
    }

    @Test func noDuplicatesAndFallbackTitle() {
        var s = BookmarkStore()
        #expect(s.add(url: url, title: "  ") != nil)
        #expect(s.add(url: url, title: "again") == nil)
        #expect(s.bookmarks.count == 1)
        #expect(s.bookmarks[0].title == "example.com")
    }

    @Test func rename() {
        var s = BookmarkStore()
        let bm = s.add(url: url, title: "a")!
        s.rename(id: bm.id, to: "b")
        #expect(s.bookmarks[0].title == "b")
    }
}

@Suite struct BrowserModelTests {
    @Test func sessionClampsIndexAndDropsEmptyWindows() {
        let tab = SessionState.SavedTab(url: URL(string: "https://a.com")!, title: "A")
        let s = SessionState(windows: [.init(tabs: [tab], activeIndex: 9), .init(tabs: [], activeIndex: 0)])
        #expect(s.windows.count == 1)
        #expect(s.windows[0].activeIndex == 0)
    }

    @Test func sessionWindowGeometryRoundTrips() throws {
        let tab = SessionState.SavedTab(url: URL(string: "https://a.com")!, title: "A")
        let frame = SessionState.SavedFrame(x: 10, y: 20, width: 900, height: 700)
        let state = SessionState(windows: [.init(tabs: [tab], activeIndex: 0, frame: frame, isFullScreen: true)])
        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func recentlyClosedIsBoundedLIFO() {
        var r = RecentlyClosed<Int>(capacity: 2)
        [1, 2, 3].forEach { r.push($0) }
        #expect(r.pop() == 3)
        #expect(r.pop() == 2)
        #expect(r.pop() == nil)
    }

    @Test func zoomSteps() {
        #expect(ZoomLevels.zoomIn(from: 1.0) == 1.1)
        #expect(ZoomLevels.zoomOut(from: 1.0) == 0.9)
        #expect(ZoomLevels.zoomIn(from: 3.0) == 3.0)
        #expect(ZoomLevels.zoomOut(from: 0.5) == 0.5)
        #expect(ZoomLevels.zoomIn(from: 1.05) == 1.1)
        #expect(ZoomLevels.label(1.25) == "125%")
    }

    @Test func sanitizeStripsPathsAndHidden() {
        #expect(DownloadNaming.sanitize("../../etc/passwd") == "_.._etc_passwd")
        #expect(DownloadNaming.sanitize(".bashrc") == "bashrc")
        #expect(DownloadNaming.sanitize("   ") == "download")
        #expect(DownloadNaming.sanitize("a\nb.txt") == "a_b.txt")
    }

    @Test func uniqueNameAddsCounter() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.pdf", "/tmp/x/a (1).pdf", "/tmp/x/README"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        #expect(DownloadNaming.uniqueURL(in: dir, suggested: "a.pdf", exists: exists).lastPathComponent == "a (2).pdf")
        #expect(DownloadNaming.uniqueURL(in: dir, suggested: "README", exists: exists).lastPathComponent == "README (1)")
        #expect(DownloadNaming.uniqueURL(in: dir, suggested: "b.zip", exists: exists).lastPathComponent == "b.zip")
    }

    @Test func downloadRiskClassification() {
        #expect(DownloadRiskClassifier.risks(filename: "photo.jpg").isEmpty)
        #expect(DownloadRiskClassifier.risks(filename: "run.command") == [.executable])
        #expect(DownloadRiskClassifier.risks(filename: "setup.pkg") == [.installer])
        let machO = Data([0xcf, 0xfa, 0xed, 0xfe])
        #expect(DownloadRiskClassifier.risks(filename: "document.pdf", prefix: machO) == [.disguisedExecutable])
    }
}
