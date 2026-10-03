import AppKit

private final class DownloadRowView: NSTableCellView {
    let fileIcon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let sourceLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let actionButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fileIcon.imageScaling = .scaleProportionallyUpOrDown
        fileIcon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.font = .systemFont(ofSize: 9)
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 9)
        dateLabel.font = .systemFont(ofSize: 9)
        dateLabel.textColor = .tertiaryLabelColor
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .accessoryBarAction
        actionButton.controlSize = .small
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        let titleLine = NSStackView(views: [titleLabel, NSView(), actionButton])
        titleLine.spacing = 8
        let statusLine = NSStackView(views: [sourceLabel, statusLabel, NSView(), dateLabel])
        statusLine.spacing = 6
        statusLine.distribution = .fillProportionally
        let details = NSStackView(views: [titleLine, statusLine, progress])
        details.orientation = .vertical
        details.spacing = 0
        details.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fileIcon)
        addSubview(details)
        NSLayoutConstraint.activate([
            fileIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fileIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: 18),
            fileIcon.heightAnchor.constraint(equalToConstant: 18),
            details.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 8),
            details.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            details.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class DownloadsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                       NSSearchFieldDelegate, NSMenuItemValidation {
    static let shared = DownloadsWindowController()

    private var services: BrowserServices { .shared }
    private var items: [DownloadManager.Item] = []
    private let table = DeletableTableView()
    private let searchField = NSSearchField()
    private let clearButton = NSButton(title: String(localized: "Clear List"), target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No downloads yet"))
    private let summaryLabel = NSTextField(labelWithString: "")
    private let dateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.dateStyle = .medium
        value.timeStyle = .short
        value.doesRelativeDateFormatting = true
        return value
    }()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Downloads")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 280)
        window.setFrameAutosaveName("AskaraDownloadsCompact")
        super.init(window: window)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsChanged),
                                               name: .askaraDownloadsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        searchField.stringValue = ""
        reload()
        showWindow(nil)
        window?.makeFirstResponder(searchField)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        let heading = NSTextField(labelWithString: String(localized: "Downloads"))
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor
        searchField.placeholderString = String(localized: "Search downloads")
        searchField.setAccessibilityLabel(String(localized: "Search downloads"))
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [heading, summaryLabel, NSView(), searchField])
        header.alignment = .centerY
        header.spacing = 10

        let column = NSTableColumn(identifier: .init("download"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel(String(localized: "Downloads"))
        let menu = NSMenu()
        for (title, action) in [
            (String(localized: "Open"), #selector(openSelected(_:))),
            (String(localized: "Show in Finder"), #selector(revealSelected(_:))),
            (String(localized: "Copy Address"), #selector(copySource(_:))),
            (String(localized: "Copy SHA-256"), #selector(copySHA256(_:))),
            (String(localized: "Cancel Download"), #selector(cancelSelected(_:))),
            (String(localized: "Remove"), #selector(delete(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        clearButton.target = self
        clearButton.action = #selector(clearList(_:))
        clearButton.bezelStyle = .rounded
        let footer = NSStackView(views: [NSView(), clearButton])
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)

        for view in [header, scroll, footer, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    @objc private func downloadsChanged() {
        guard window?.isVisible == true else { return }
        reload()
    }

    @objc private func searchChanged(_ sender: Any?) { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    private func reload() {
        let words = searchField.stringValue.lowercased().split(separator: " ")
        items = services.downloads.items.filter { item in
            let text = "\(item.filename) \(item.sourceURL?.absoluteString ?? "")".lowercased()
            return words.allSatisfy(text.contains)
        }
        let running = services.downloads.running.count
        summaryLabel.stringValue = running > 0 ? String(localized: "\(running) active")
            : String(localized: "\(services.downloads.items.count) items")
        clearButton.isEnabled = services.downloads.items.contains { $0.state != .running }
        emptyLabel.isHidden = !items.isEmpty
        table.reloadData()
    }

    private var selectedItems: [DownloadManager.Item] {
        var indexes = table.selectedRowIndexes
        if table.clickedRow >= 0, !indexes.contains(table.clickedRow) { indexes = [table.clickedRow] }
        return indexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("download-row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DownloadRowView) ?? {
            let value = DownloadRowView()
            value.identifier = id
            return value
        }()
        let item = items[row]
        if let path = item.destination?.path, FileManager.default.fileExists(atPath: path) {
            cell.fileIcon.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            cell.fileIcon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        }
        cell.titleLabel.stringValue = item.filename
        cell.sourceLabel.stringValue = item.sourceURL?.host ?? item.sourceURL?.absoluteString ?? String(localized: "Unknown source")
        let size = item.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        cell.statusLabel.stringValue = [item.statusText, size].compactMap { $0 }.joined(separator: "  ·  ")
        cell.statusLabel.textColor = item.risks.contains(where: \.isHighRisk) ? .systemOrange
            : item.state == .running ? .controlAccentColor : .secondaryLabelColor
        cell.dateLabel.stringValue = item.endedAt.map(dateFormatter.string(from:)) ?? ""
        cell.toolTip = item.sourceURL?.absoluteString
        cell.progress.isHidden = item.state != .running
        cell.progress.isIndeterminate = item.fraction <= 0
        if cell.progress.isIndeterminate { cell.progress.startAnimation(nil) }
        else { cell.progress.stopAnimation(nil); cell.progress.doubleValue = item.fraction }
        cell.actionButton.identifier = .init(item.id.uuidString)
        cell.actionButton.target = self
        if item.state == .running {
            cell.actionButton.title = ""
            cell.actionButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            cell.actionButton.action = #selector(rowCancel(_:))
            cell.actionButton.isHidden = false
        } else if item.destination.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            cell.actionButton.title = ""
            cell.actionButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            cell.actionButton.action = #selector(rowReveal(_:))
            cell.actionButton.isHidden = false
        } else {
            cell.actionButton.isHidden = true
        }
        return cell
    }

    @objc private func rowCancel(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let item = services.downloads.items.first(where: { $0.id == id }) else { return }
        services.downloads.cancel(item)
    }

    @objc private func rowReveal(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let url = services.downloads.items.first(where: { $0.id == id })?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openSelected(_ sender: Any?) {
        for item in selectedItems {
            guard let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { continue }
            if item.requiresOpenConfirmation, !confirmOpen(item) { continue }
            NSWorkspace.shared.open(url)
        }
    }

    private func confirmOpen(_ item: DownloadManager.Item) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Open this download?")
        let finding = item.riskText.isEmpty ? item.statusText : item.riskText
        alert.informativeText = String(localized: "Local scan result: \(finding). This scan cannot determine whether a file is malware. Only open files you trust.")
        alert.addButton(withTitle: String(localized: "Open Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func revealSelected(_ sender: Any?) {
        let urls = selectedItems.compactMap(\.destination).filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func copySource(_ sender: Any?) {
        copy(selectedItems.compactMap { $0.sourceURL?.absoluteString })
    }

    @objc private func copySHA256(_ sender: Any?) { copy(selectedItems.compactMap(\.sha256)) }

    private func copy(_ values: [String]) {
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    @objc private func cancelSelected(_ sender: Any?) { selectedItems.forEach(services.downloads.cancel) }

    @objc func delete(_ sender: Any?) {
        let selected = selectedItems
        selected.forEach(services.downloads.cancel)
        services.downloads.removeFromList(Set(selected.map(\.id)))
    }

    @objc private func clearList(_ sender: Any?) {
        services.downloads.removeFromList(Set(services.downloads.items.filter { $0.state != .running }.map(\.id)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let selected = selectedItems
        switch menuItem.action {
        case #selector(openSelected(_:)), #selector(revealSelected(_:)):
            return selected.contains { $0.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        case #selector(copySource(_:)): return selected.contains { $0.sourceURL != nil }
        case #selector(copySHA256(_:)): return selected.contains { $0.sha256 != nil }
        case #selector(cancelSelected(_:)): return selected.contains { $0.state == .running }
        default: return !selected.isEmpty
        }
    }
}
