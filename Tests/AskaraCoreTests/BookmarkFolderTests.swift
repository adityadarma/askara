import Foundation
import Testing
@testable import AskaraCore

@Suite struct BookmarkFolderTests {
    let a = URL(string: "https://a.com")!
    let b = URL(string: "https://b.com")!
    let c = URL(string: "https://c.com")!

    @Test func decodesOldFlatFileOntoBar() throws {
        let id = UUID()
        let json = #"{"bookmarks":[{"id":"\#(id.uuidString)","url":"https://a.com","title":"A","created":0}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let store = try decoder.decode(BookmarkStore.self, from: Data(json.utf8))
        #expect(store.bar.map(\.id) == [id])
        #expect(store.contains(a))
    }

    @Test func foldersAndFlatList() throws {
        var store = BookmarkStore()
        let folderResult = store.addFolder(title: "Work")
        let folder = try #require(folderResult)
        store.add(url: a, title: "A", to: .folder(folder))
        store.add(url: b, title: "B", to: .other)
        store.add(url: c, title: "C")
        #expect(store.bookmarks.map(\.url) == [a, c, b])
        #expect(store.children(of: .folder(folder)).map(\.url) == [a])
        let duplicate = store.add(url: a, title: "again", to: .other)
        #expect(duplicate == nil)
        #expect(store.location(of: store.node(for: a)!.id)?.container == .folder(folder))
    }

    @Test func removeFolderRemovesContents() throws {
        var store = BookmarkStore()
        let folderResult = store.addFolder(title: "Work")
        let folder = try #require(folderResult)
        store.add(url: a, title: "A", to: .folder(folder))
        store.remove(id: folder)
        #expect(!store.contains(a))
        #expect(store.bar.isEmpty)
    }

    @Test func moveReordersAndNests() throws {
        var store = BookmarkStore()
        store.add(url: a, title: "A")
        store.add(url: b, title: "B")
        store.add(url: c, title: "C")
        let idA = try #require(store.node(for: a)?.id)
        // Drop A after C (index 3 in the order before the move).
        let result1 = store.move(id: idA, to: .bar, at: 3)
        #expect(result1)
        #expect(store.bar.compactMap(\.url) == [b, c, a])
        let outerResult = store.addFolder(title: "Outer")
        let outer = try #require(outerResult)
        let innerResult = store.addFolder(title: "Inner", to: .folder(outer))
        let inner = try #require(innerResult)
        let result2 = store.move(id: idA, to: .folder(inner))
        #expect(result2)
        #expect(store.children(of: .folder(inner)).map(\.url) == [a])
        // A folder can't move into itself or its own subfolder.
        let result3 = store.move(id: outer, to: .folder(inner))
        #expect(!result3)
        let result4 = store.move(id: outer, to: .folder(outer))
        #expect(!result4)
        #expect(store.node(outer) != nil)
    }

    @Test func setURLRejectsDuplicates() throws {
        var store = BookmarkStore()
        store.add(url: a, title: "A")
        store.add(url: b, title: "B")
        let idA = try #require(store.node(for: a)?.id)
        let result5 = store.setURL(id: idA, to: b)
        #expect(!result5)
        let result6 = store.setURL(id: idA, to: c)
        #expect(result6)
        #expect(store.contains(c) && !store.contains(a))
    }

    @Test func containersAndPath() throws {
        var store = BookmarkStore()
        let workResult = store.addFolder(title: "Work")
        let work = try #require(workResult)
        let docsResult = store.addFolder(title: "Docs", to: .folder(work))
        let docs = try #require(docsResult)
        let list = store.containers()
        #expect(list.map(\.container) == [.bar, .folder(work), .folder(docs), .other])
        #expect(list.map(\.depth) == [0, 1, 2, 0])
        #expect(store.path(of: .folder(docs), barTitle: "Bar", otherTitle: "Other") == "Bar / Work / Docs")
    }

    @Test func roundTrip() throws {
        var store = BookmarkStore()
        let folderResult = store.addFolder(title: "Work")
        let folder = try #require(folderResult)
        store.add(url: a, title: "A", to: .folder(folder))
        store.add(url: b, title: "B", to: .other)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(BookmarkStore.self, from: encoder.encode(store))
        #expect(decoded.bookmarks.map(\.url) == store.bookmarks.map(\.url))
        #expect(decoded.children(of: .folder(folder)).map(\.url) == [a])
    }
}

@Suite struct BrowserImportTests {
    @Test func chromeBookmarks() throws {
        let json = """
        {"roots":{
          "bookmark_bar":{"children":[
            {"type":"url","name":"A","url":"https://a.com","date_added":"13300000000000000"},
            {"type":"folder","name":"Work","children":[{"type":"url","name":"B","url":"https://b.com"}]}
          ]},
          "other":{"children":[{"type":"url","name":"C","url":"https://c.com"}]},
          "synced":{"children":[]}
        }}
        """
        let imported = try BrowserImport.chromeBookmarks(from: Data(json.utf8))
        #expect(imported.bar.count == 2)
        #expect(imported.bar[1].isFolder && imported.bar[1].children?.first?.url?.host == "b.com")
        #expect(imported.other.first?.url?.host == "c.com")
        #expect(imported.count == 3)
        // 13300000000000000 µs since 1601 = 2022-06-18.
        let year = Calendar(identifier: .gregorian).component(.year, from: imported.bar[0].created)
        #expect(year == 2022)
    }

    @Test func safariBookmarksSkipReadingList() throws {
        let plist: [String: Any] = ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://a.com", "URIDictionary": ["title": "A"]],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Dev", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://b.com", "URIDictionary": ["title": "B"]],
                ]],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.com"],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let imported = try BrowserImport.safariBookmarks(from: data)
        #expect(imported.bar.map(\.title) == ["A"])
        #expect(imported.other.first?.title == "Dev")
        #expect(imported.count == 2)
    }

    @Test func htmlExport() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
          <DL><p>
            <DT><A HREF="https://a.com" ADD_DATE="1600000000">A &amp; co</A>
            <DT><H3>Work</H3>
            <DL><p>
              <DT><A HREF="https://b.com">B</A>
            </DL><p>
          </DL><p>
          <DT><A HREF="https://c.com">C</A>
        </DL><p>
        """
        let imported = BrowserImport.htmlBookmarks(from: Data(html.utf8))
        #expect(imported.bar.first?.title == "A & co")
        #expect(imported.bar.last?.title == "Work")
        #expect(imported.bar.last?.children?.first?.url?.host == "b.com")
        #expect(imported.other.map(\.title) == ["C"])
    }

    @Test func importIntoFolderSkipsKnownPages() {
        var store = BookmarkStore()
        store.add(url: URL(string: "https://a.com")!, title: "A")
        let imported = ImportedBookmarks(bar: [.bookmark(url: URL(string: "https://a.com")!, title: "A"),
                                               .bookmark(url: URL(string: "https://b.com")!, title: "B"),
                                               .folder("Empty")],
                                         other: [.bookmark(url: URL(string: "javascript:alert(1)")!, title: "js")])
        let added = store.importBrowser(imported, folderTitle: "From Chrome")
        #expect(added == 1)
        #expect(store.bar.last?.title == "From Chrome")
        #expect(store.bar.last?.children?.map(\.title) == ["B"])
    }

    @Test func importOntoEmptyBar() {
        var store = BookmarkStore()
        let imported = ImportedBookmarks(bar: [.bookmark(url: URL(string: "https://a.com")!, title: "A")],
                                         other: [.bookmark(url: URL(string: "https://b.com")!, title: "B")])
        let result7 = store.importBrowser(imported, folderTitle: "From Safari")
        #expect(result7 == 2)
        #expect(store.bar.map(\.title) == ["A"])
        #expect(store.other.first?.title == "From Safari")
    }

    @Test func historyMerge() {
        var history = HistoryStore(limit: 3)
        let a = URL(string: "https://a.com")!
        history.record(url: a, title: "A", at: Date(timeIntervalSince1970: 100))
        let changed = history.importVisits([
            ImportedVisit(url: a, title: "", lastVisited: Date(timeIntervalSince1970: 500), visitCount: 4),
            ImportedVisit(url: URL(string: "https://b.com")!, title: "B", lastVisited: Date(timeIntervalSince1970: 200), visitCount: 1),
            ImportedVisit(url: URL(string: "file:///x")!, title: "x", lastVisited: Date(), visitCount: 1),
        ])
        #expect(changed == 2)
        #expect(history.entries.map(\.url.host) == ["a.com", "b.com"])
        #expect(history.entries[0].visitCount == 5)
        #expect(history.entries[0].title == "A")
    }
}
