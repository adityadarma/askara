import AppKit
import HematCore

/// Table that forwards Delete/Backspace to the `delete(_:)` action, and Enter to open.
final class DeletableTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Backspace, Forward Delete
            NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: self)
        case 36, 76: // Return, Enter
            if let doubleAction { NSApp.sendAction(doubleAction, to: target, from: self) }
        default:
            super.keyDown(with: event)
        }
    }
}

/// One window for History, Bookmarks, and Downloads (table + search).
@MainActor
final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSMenuItemValidation {
    enum Mode: Int, CaseIterable {
        case history, bookmarks, downloads
        var title: String { [String(localized: "History"), String(localized: "Bookmarks"), String(localized: "Downloads")][rawValue] }
    }

    private struct Row {
        let id: AnyHashable
        let title: String
        let detail: String
        let date: Date?
        let url: URL?
    }

    static let shared = LibraryWindowController()

    private var mode: Mode = .history
    private var rows: [Row] = []
    private let table = DeletableTableView()
    private let searchField = NSSearchField()
    private let picker = NSSegmentedControl()
    private let actionButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var services: BrowserServices { .shared }
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HematLibrary")
        window.minSize = NSSize(width: 480, height: 300)
        super.init(window: window)
        buildUI()

        let center = NotificationCenter.default
        for name in [Notification.Name.hematHistoryChanged, .hematBookmarksChanged, .hematDownloadsChanged] {
            center.addObserver(self, selector: #selector(dataChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ mode: Mode) {
        self.mode = mode
        picker.selectedSegment = mode.rawValue
        searchField.stringValue = ""
        reload()
        showWindow(nil)
        window?.makeFirstResponder(searchField)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }

        picker.segmentCount = Mode.allCases.count
        for mode in Mode.allCases { picker.setLabel(mode.title, forSegment: mode.rawValue) }
        picker.trackingMode = .selectOne
        picker.target = self
        picker.action = #selector(modeChanged(_:))
        picker.setAccessibilityLabel(String(localized: "Choose list"))

        searchField.placeholderString = String(localized: "Search")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityLabel(String(localized: "Search list"))

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(footerAction(_:))

        let header = NSStackView(views: [picker, searchField])
        header.spacing = 8
        let footer = NSStackView(views: [NSView(), actionButton])

        for (id, title, width) in [("title", String(localized: "Title"), 300.0), ("detail", String(localized: "Address / Status"), 280), ("date", String(localized: "Date"), 140)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel(String(localized: "List"))

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open"), action: #selector(openSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Open in New Tab"), action: #selector(openSelectedInNewTabs(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Copy Address"), action: #selector(copyAddress(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Rename…"), action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(revealSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Remove"), action: #selector(delete(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        for v in [header, scroll, footer, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Data

    @objc private func dataChanged(_ note: Notification) {
        let relevant: Notification.Name = [.hematHistoryChanged, .hematBookmarksChanged, .hematDownloadsChanged][mode.rawValue]
        // No need to refresh a table that isn't visible.
        guard note.name == relevant, window?.isVisible == true else { return }
        reload()
    }

    private func reload() {
        let query = searchField.stringValue.lowercased()
        func matches(_ parts: String...) -> Bool {
            query.isEmpty || query.split(separator: " ").allSatisfy { word in
                parts.contains { $0.lowercased().contains(word) }
            }
        }

        switch mode {
        case .history:
            rows = services.history.search(query, limit: 1_000).map {
                Row(id: $0.url, title: $0.title.isEmpty ? ($0.url.host ?? "") : $0.title,
                    detail: $0.url.absoluteString, date: $0.lastVisited, url: $0.url)
            }
            actionButton.title = String(localized: "Clear History…")
            emptyLabel.stringValue = String(localized: "No history yet")
        case .bookmarks:
            rows = services.bookmarks.bookmarks.reversed()
                .filter { matches($0.title, $0.url.absoluteString) }
                .map { Row(id: $0.id, title: $0.title, detail: $0.url.absoluteString, date: $0.created, url: $0.url) }
            actionButton.title = String(localized: "Remove Selected")
            emptyLabel.stringValue = String(localized: "No bookmarks yet. Press ⌘D on a page to add one.")
        case .downloads:
            rows = services.downloads.items
                .filter { matches($0.filename, $0.sourceURL?.absoluteString ?? "") }
                .map { Row(id: $0.id, title: $0.filename, detail: $0.statusText, date: nil, url: $0.destination) }
            actionButton.title = String(localized: "Clear List")
            emptyLabel.stringValue = String(localized: "No downloads yet")
        }
        window?.title = mode.title
        emptyLabel.isHidden = !rows.isEmpty
        table.reloadData()
    }

    private var selectedRows: [Row] {
        var indexes = table.selectedRowIndexes
        // Right-click on an unselected row: use that row.
        if table.clickedRow >= 0, !indexes.contains(table.clickedRow) { indexes = [table.clickedRow] }
        return indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = Mode(rawValue: sender.selectedSegment) ?? .history
        reload()
    }

    @objc private func searchChanged(_ sender: Any?) { reload() }

    @objc private func openSelected(_ sender: Any?) {
        let selected = selectedRows
        if mode == .downloads {
            selected.compactMap(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
                .forEach { NSWorkspace.shared.open($0) }
            return
        }
        for (index, row) in selected.enumerated() {
            if let url = row.url { services.open(url, newTab: index > 0) }
        }
    }

    @objc private func openSelectedInNewTabs(_ sender: Any?) {
        selectedRows.compactMap(\.url).forEach { services.open($0, newTab: true) }
    }

    @objc private func copyAddress(_ sender: Any?) {
        let text = selectedRows.compactMap { mode == .downloads ? $0.url?.path : $0.url?.absoluteString }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func revealSelected(_ sender: Any?) {
        let urls = selectedRows.compactMap(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard mode == .bookmarks, let row = selectedRows.first, let id = row.id.base as? UUID,
              let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Bookmark")
        let input = NSTextField(string: row.title)
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        input.setAccessibilityLabel(String(localized: "Bookmark name"))
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.services.renameBookmark(id: id, to: input.stringValue)
        }
    }

    /// The keyboard Delete key also calls this.
    @objc func delete(_ sender: Any?) {
        let selected = selectedRows
        guard !selected.isEmpty else { return }
        switch mode {
        case .history: services.removeHistory(urls: selected.compactMap { $0.id.base as? URL })
        case .bookmarks: services.removeBookmarks(ids: selected.compactMap { $0.id.base as? UUID })
        case .downloads:
            let ids = Set(selected.compactMap { $0.id.base as? UUID })
            // Removing from the list cancels it if still running. Finished files are not deleted.
            services.downloads.items.filter { ids.contains($0.id) }.forEach(services.downloads.cancel)
            services.downloads.removeFromList(ids)
        }
    }

    @objc private func footerAction(_ sender: Any?) {
        switch mode {
        case .history: confirmClearBrowsingData()
        case .bookmarks: delete(sender)
        case .downloads:
            let done = services.downloads.items.filter { $0.state != .running }.map(\.id)
            services.downloads.removeFromList(Set(done))
        }
    }

    private func confirmClearBrowsingData() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Clear all browsing data?")
        alert.informativeText = String(localized: "History, cookies, cache, and website data will be removed. You will be signed out of all websites. Bookmarks and downloaded files are not removed. This can’t be undone.")
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.services.clearBrowsingData {}
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = selectedRows
        switch item.action {
        case #selector(renameSelected(_:)):
            item.isHidden = mode != .bookmarks
            return selected.count == 1
        case #selector(revealSelected(_:)):
            item.isHidden = mode != .downloads
            return selected.contains { $0.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        case #selector(openSelectedInNewTabs(_:)):
            item.isHidden = mode == .downloads
            return !selected.isEmpty
        default:
            return !selected.isEmpty
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, rows.indices.contains(row) else { return nil }
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let item = rows[row]
        switch id.rawValue {
        case "title": cell.textField?.stringValue = item.title
        case "detail":
            cell.textField?.stringValue = item.detail
            cell.textField?.textColor = .secondaryLabelColor
        default: cell.textField?.stringValue = item.date.map(dateFormatter.string(from:)) ?? ""
        }
        return cell
    }
}
