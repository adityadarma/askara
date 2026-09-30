import AppKit
import SQLite3
import AskaraCore

/// Bookmarks > Import Bookmarks and History…: from Chrome-based browsers (Chrome, Brave, Edge, Arc,
/// Vivaldi), Safari, or an exported HTML bookmarks file. Goes into the current profile.
/// Passwords aren't imported: they're encrypted with the other browser's key (use Bitwarden instead).
@MainActor
enum BrowserImporter {
    /// Where to import from. A Chromium browser can have several profiles.
    struct Source {
        enum Kind { case chromium(folder: URL), safari, htmlFile }
        let name: String
        let kind: Kind
    }

    /// History is capped like Askara's own (newest first).
    private static let historyLimit = 5_000

    static func availableSources() -> [Source] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let browsers: [(String, String)] = [
            ("Google Chrome", "Google/Chrome"),
            ("Brave", "BraveSoftware/Brave-Browser"),
            ("Microsoft Edge", "Microsoft Edge"),
            ("Arc", "Arc/User Data"),
            ("Vivaldi", "Vivaldi"),
            ("Chromium", "Chromium"),
        ]
        var sources: [Source] = []
        for (name, path) in browsers {
            let root = support.appendingPathComponent(path, isDirectory: true)
            for (profileName, folder) in chromiumProfiles(in: root) {
                let hasData = ["Bookmarks", "History"].contains {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
                guard hasData else { continue }
                let label = profileName.map { "\(name) – \($0)" } ?? name
                sources.append(Source(name: label, kind: .chromium(folder: folder)))
            }
        }
        sources.append(Source(name: "Safari", kind: .safari))
        sources.append(Source(name: String(localized: "Bookmarks HTML File…"), kind: .htmlFile))
        return sources
    }

    /// Profile folders listed in `Local State`, with their display names. nil name = only one profile.
    private static func chromiumProfiles(in root: URL) -> [(String?, URL)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let state = (try? Data(contentsOf: root.appendingPathComponent("Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cache = ((state?["profile"] as? [String: Any])?["info_cache"] as? [String: Any]) ?? [:]
        if cache.isEmpty { return [(nil, root.appendingPathComponent("Default", isDirectory: true))] }
        let entries = cache.map { key, value in
            ((value as? [String: Any])?["name"] as? String ?? key, root.appendingPathComponent(key, isDirectory: true))
        }.sorted { $0.1.lastPathComponent.localizedStandardCompare($1.1.lastPathComponent) == .orderedAscending }
        return entries.count == 1 ? [(nil, entries[0].1)] : entries.map { (Optional($0.0), $0.1) }
    }

    // MARK: - UI

    static func run(in window: NSWindow?, profile: ProfileData) {
        let sources = availableSources()
        let alert = NSAlert()
        alert.messageText = String(localized: "Import Bookmarks and History")
        alert.informativeText = String(localized: "Imported into the “\(profile.profile.name)” profile. Pages you already have are skipped. Passwords aren't imported; Bitwarden keeps those.")
        let popup = NSPopUpButton()
        popup.addItems(withTitles: sources.map(\.name))
        popup.setAccessibilityLabel(String(localized: "Import from"))
        let bookmarks = NSButton(checkboxWithTitle: String(localized: "Bookmarks"), target: nil, action: nil)
        bookmarks.state = .on
        let history = NSButton(checkboxWithTitle: String(localized: "History"), target: nil, action: nil)
        history.state = .on
        let stack = NSStackView(views: [popup, bookmarks, history])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, sources.indices.contains(popup.indexOfSelectedItem) else { return }
            let source = sources[popup.indexOfSelectedItem]
            // Let the sheet close before a possible open panel or result alert.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    start(source, bookmarks: bookmarks.state == .on, history: history.state == .on,
                          profile: profile, window: window)
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private static func start(_ source: Source, bookmarks: Bool, history: Bool, profile: ProfileData, window: NSWindow?) {
        guard bookmarks || history else { return }
        switch source.kind {
        case .htmlFile:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.html]
            panel.message = String(localized: "Choose a bookmarks file exported from another browser.")
            let done: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let imported = BrowserImport.htmlBookmarks(from: try Data(contentsOf: url))
                    finish(bookmarks: imported, visits: nil, name: url.deletingPathExtension().lastPathComponent,
                           profile: profile, window: window)
                } catch {
                    fail(error, window: window)
                }
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }

        case .chromium(let folder):
            do {
                let marks = bookmarks ? try readIfPresent(folder.appendingPathComponent("Bookmarks"))
                    .map(BrowserImport.chromeBookmarks) : nil
                let visits = history ? try chromiumHistory(folder.appendingPathComponent("History")) : nil
                finish(bookmarks: marks, visits: visits, name: source.name, profile: profile, window: window)
            } catch {
                fail(error, window: window)
            }

        case .safari:
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
            let plist = dir.appendingPathComponent("Bookmarks.plist")
            // Safari's folder is protected: without Full Disk Access even reading fails.
            guard FileManager.default.isReadableFile(atPath: plist.path), (try? Data(contentsOf: plist)) != nil else {
                return safariNeedsAccess(window: window)
            }
            do {
                let marks = bookmarks ? try BrowserImport.safariBookmarks(from: Data(contentsOf: plist)) : nil
                let visits = history ? try safariHistory(dir.appendingPathComponent("History.db")) : nil
                finish(bookmarks: marks, visits: visits, name: "Safari", profile: profile, window: window)
            } catch {
                fail(error, window: window)
            }
        }
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    private static func finish(bookmarks: ImportedBookmarks?, visits: [ImportedVisit]?, name: String,
                               profile: ProfileData, window: NSWindow?) {
        let folderTitle = String(localized: "Imported from \(name)")
        let added = bookmarks.map { imported in profile.editBookmarks { $0.importBrowser(imported, folderTitle: folderTitle) } } ?? 0
        let pages = visits.map { profile.importHistory($0) } ?? 0
        let alert = NSAlert()
        alert.messageText = String(localized: "Import finished")
        var lines: [String] = []
        if bookmarks != nil { lines.append(String(localized: "Bookmarks added: \(added)")) }
        if visits != nil { lines.append(String(localized: "History pages: \(pages)")) }
        alert.informativeText = lines.joined(separator: "\n")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func fail(_ error: Error, window: NSWindow?) {
        Log.error("Askara: import failed: \(error)")
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't import")
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func safariNeedsAccess(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Askara can't read Safari's data")
        alert.informativeText = String(localized: "macOS protects Safari's folder. Either give Askara Full Disk Access (then quit and reopen Askara), or in Safari choose File > Export > Bookmarks and import that HTML file here.")
        alert.addButton(withTitle: String(localized: "Open Privacy Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
            NSWorkspace.shared.open(url)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: - History databases

    /// Chrome's `History` (SQLite). The browser keeps it locked while running, so a copy is read.
    private static func chromiumHistory(_ file: URL) throws -> [ImportedVisit] {
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT \(historyLimit)"
        return try query(copyOf: file, sql: sql) { row in
            guard let text = row.text(0), let url = URL(string: text) else { return nil }
            return ImportedVisit(url: url, title: row.text(1) ?? "",
                                 lastVisited: BrowserImport.chromeDate(NSNumber(value: row.int(3))),
                                 visitCount: Int(row.int(2)))
        }
    }

    /// Safari's `History.db`: one row per page, visits (with titles) in a second table.
    private static func safariHistory(_ file: URL) throws -> [ImportedVisit] {
        let sql = """
            SELECT i.url, (SELECT title FROM history_visits WHERE history_item = i.id ORDER BY visit_time DESC LIMIT 1),
                   i.visit_count, MAX(v.visit_time)
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id ORDER BY 4 DESC LIMIT \(historyLimit)
            """
        return try query(copyOf: file, sql: sql) { row in
            guard let text = row.text(0), let url = URL(string: text) else { return nil }
            return ImportedVisit(url: url, title: row.text(1) ?? "", lastVisited: BrowserImport.safariDate(row.double(3)),
                                 visitCount: Int(row.int(2)))
        }
    }

    private struct Row {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    }

    /// Copies the database (and its WAL/journal) to a temporary folder, reads it, then deletes the copy.
    private static func query<T>(copyOf file: URL, sql: String, map: (Row) -> T?) throws -> [T] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return [] }
        let temp = fm.temporaryDirectory.appendingPathComponent("askara-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let copy = temp.appendingPathComponent(file.lastPathComponent)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let source = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "AskaraImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = map(Row(statement: statement)) { result.append(value) }
        }
        return result
    }
}
