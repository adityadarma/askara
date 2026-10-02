import AppKit
import AskaraCore

@MainActor
final class PasswordVaultWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = PasswordVaultWindowController()

    private let table = NSTableView()
    private let deleteButton = NSButton(title: String(localized: "Delete"), target: nil, action: nil)
    private var credentials: [PasswordCredential] = []
    private var profile: ProfileData?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Saved Passwords")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 260)
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(profile: ProfileData) {
        self.profile = profile
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        for (id, title, width) in [("site", String(localized: "Site"), 290.0),
                                   ("username", String(localized: "Username"), 240.0)] {
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
        table.setAccessibilityLabel(String(localized: "Saved passwords"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected(_:))
        let note = NSTextField(wrappingLabelWithString: String(localized: "Passwords are stored locally in macOS Keychain and are not synchronized."))
        note.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [note, NSView(), deleteButton])
        footer.spacing = 8
        for view in [scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
    }

    private func reload() {
        do { credentials = try profile?.passwords.credentials() ?? [] }
        catch { credentials = []; present(error) }
        table.reloadData()
        deleteButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let profile else { return }
        let selected = table.selectedRowIndexes.compactMap { credentials.indices.contains($0) ? credentials[$0] : nil }
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete selected passwords?")
        alert.informativeText = String(localized: "This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try selected.forEach { try profile.passwords.delete($0.id) }
            reload()
        } catch { present(error) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { credentials.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        deleteButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard credentials.indices.contains(row), let tableColumn else { return nil }
        let id = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.textField = text
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let credential = credentials[row]
        cell.textField?.stringValue = id.rawValue == "site" ? credential.origin.displayName : credential.username
        return cell
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }
}
