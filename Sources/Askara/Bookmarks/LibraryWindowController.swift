import AppKit
import AskaraCore

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

private final class LibraryRowView: NSTableCellView {
    let siteIcon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let hostLabel = NSTextField(labelWithString: "")
    let metadataLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        siteIcon.imageScaling = .scaleProportionallyUpOrDown
        siteIcon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        hostLabel.font = .systemFont(ofSize: 9)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.font = .systemFont(ofSize: 9)
        metadataLabel.textColor = .tertiaryLabelColor
        dateLabel.font = .systemFont(ofSize: 9)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right

        let titleLine = NSStackView(views: [titleLabel, NSView(), dateLabel])
        titleLine.spacing = 8
        let contextLine = NSStackView(views: [hostLabel, metadataLabel, NSView()])
        contextLine.spacing = 8
        let labels = NSStackView(views: [titleLine, contextLine])
        labels.orientation = .vertical
        labels.spacing = 0
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(siteIcon)
        addSubview(labels)
        NSLayoutConstraint.activate([
            siteIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            siteIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            siteIcon.widthAnchor.constraint(equalToConstant: 16),
            siteIcon.heightAnchor.constraint(equalToConstant: 16),
            labels.leadingAnchor.constraint(equalTo: siteIcon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            dateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Independent searchable window for either History or Bookmarks.
@MainActor
final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSMenuItemValidation {
    enum Mode {
        case history, bookmarks
        var title: String { self == .history ? String(localized: "History") : String(localized: "Bookmarks") }
    }

    private struct Row {
        let id: AnyHashable
        let title: String
        let detail: String
        let metadata: String
        let date: Date?
        let url: URL?
    }

    static let history = LibraryWindowController(mode: .history)
    static let bookmarks = LibraryWindowController(mode: .bookmarks)

    private let mode: Mode
    private var rows: [Row] = []
    private let table = DeletableTableView()
    private let searchField = NSSearchField()
    private let actionButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var services: BrowserServices { .shared }
    /// History and bookmarks shown are those of the profile in use when the window was opened.
    private var profile: ProfileData = BrowserServices.shared.currentProfile
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private init(mode: Mode) {
        self.mode = mode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = mode.title
        window.setFrameAutosaveName(mode == .history ? "AskaraHistoryCompact" : "AskaraBookmarksCompact")
        window.minSize = NSSize(width: 480, height: 300)
        super.init(window: window)
        buildUI()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(dataChanged(_:)),
                           name: mode == .history ? .askaraHistoryChanged : .askaraBookmarksChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        profile = services.currentProfile
        searchField.stringValue = ""
        reload()
        showWindow(nil)
        window?.makeFirstResponder(searchField)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }

        searchField.placeholderString = String(localized: "Search")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityLabel(String(localized: "Search list"))
        searchField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(footerAction(_:))

        let heading = NSTextField(labelWithString: mode.title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [heading, summaryLabel, NSView(), searchField])
        header.alignment = .centerY
        header.spacing = 8
        let footer = NSStackView(views: [NSView(), actionButton])

        let column = NSTableColumn(identifier: .init("library-row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel(String(localized: "List"))

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open"), action: #selector(openSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Open in New Tab"), action: #selector(openSelectedInNewTabs(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Copy Address"), action: #selector(copyAddress(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Rename…"), action: #selector(renameSelected(_:)), keyEquivalent: "")
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
        let relevant: Notification.Name = mode == .history ? .askaraHistoryChanged : .askaraBookmarksChanged
        // No need to refresh a table that isn't visible.
        guard note.name == relevant, window?.isVisible == true,
              note.object == nil || note.object as AnyObject === profile else { return }
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
            rows = profile.history.search(query, limit: 1_000).map {
                Row(id: $0.url, title: $0.title.isEmpty ? ($0.url.host ?? "") : $0.title,
                    detail: $0.url.absoluteString,
                    metadata: String(localized: "\($0.visitCount) visits"),
                    date: $0.lastVisited, url: $0.url)
            }
            actionButton.title = String(localized: "Clear History…")
            emptyLabel.stringValue = String(localized: "No history yet")
        case .bookmarks:
            let store = profile.bookmarks
            rows = store.bookmarks.reversed()
                .filter { matches($0.title, $0.url.absoluteString) }
                .map { bookmark in
                    let container = store.location(of: bookmark.id)?.container
                    let path = container.map {
                        store.path(of: $0, barTitle: String(localized: "Bookmarks Bar"),
                                   otherTitle: String(localized: "Other Bookmarks"))
                    } ?? String(localized: "Bookmarks")
                    return Row(id: bookmark.id, title: bookmark.title, detail: bookmark.url.absoluteString,
                               metadata: path, date: bookmark.created, url: bookmark.url)
                }
            actionButton.title = String(localized: "Remove Selected")
            emptyLabel.stringValue = String(localized: "No bookmarks yet. Press ⌘D on a page to add one.")
        }
        // Profile name only once there is more than one profile.
        window?.title = services.profileList.profiles.count > 1 ? "\(mode.title) – \(profile.profile.name)" : mode.title
        summaryLabel.stringValue = String(localized: "\(rows.count) items")
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

    @objc private func searchChanged(_ sender: Any?) { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func openSelected(_ sender: Any?) {
        for (index, row) in selectedRows.enumerated() {
            if let url = row.url { services.open(url, newTab: index > 0, profile: profile) }
        }
    }

    @objc private func openSelectedInNewTabs(_ sender: Any?) {
        selectedRows.compactMap(\.url).forEach { services.open($0, newTab: true, profile: profile) }
    }

    @objc private func copyAddress(_ sender: Any?) {
        let text = selectedRows.compactMap { $0.url?.absoluteString }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
            self?.profile.renameBookmark(id: id, to: input.stringValue)
        }
    }

    /// The keyboard Delete key also calls this.
    @objc func delete(_ sender: Any?) {
        let selected = selectedRows
        guard !selected.isEmpty else { return }
        switch mode {
        case .history: profile.removeHistory(urls: selected.compactMap { $0.id.base as? URL })
        case .bookmarks: profile.removeBookmarks(ids: selected.compactMap { $0.id.base as? UUID })
        }
    }

    @objc private func footerAction(_ sender: Any?) {
        switch mode {
        case .history: confirmClearBrowsingData()
        case .bookmarks: delete(sender)
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
            self?.profile.clearBrowsingData {}
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = selectedRows
        switch item.action {
        case #selector(renameSelected(_:)):
            item.isHidden = mode != .bookmarks
            return selected.count == 1
        case #selector(openSelectedInNewTabs(_:)):
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
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? LibraryRowView) ?? {
            let value = LibraryRowView()
            value.identifier = id
            return value
        }()
        let item = rows[row]
        cell.siteIcon.image = FaviconStore.shared.icon(for: item.url)
            ?? NSImage(systemSymbolName: mode == .history ? "clock" : "bookmark.fill", accessibilityDescription: nil)
        cell.siteIcon.contentTintColor = cell.siteIcon.image?.isTemplate == true ? .secondaryLabelColor : nil
        cell.titleLabel.stringValue = item.title
        cell.hostLabel.stringValue = item.url?.host ?? String(localized: "Unknown site")
        cell.metadataLabel.stringValue = "·  \(item.metadata)"
        cell.dateLabel.stringValue = item.date.map(dateFormatter.string(from:)) ?? ""
        cell.toolTip = item.detail
        return cell
    }
}
