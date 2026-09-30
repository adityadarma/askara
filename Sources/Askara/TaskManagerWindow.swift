import AppKit
import WebKit
import AskaraCore

/// Window > Task Manager: every tab with its RAM, like Chrome's task manager. Tabs that share a page
/// process are grouped so memory is never counted twice. Refreshes every 2 s while visible.
@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                         NSTableViewDelegate {
    static let shared = TaskManagerWindowController()

    private struct Row {
        let tab: Tab
        let window: BrowserWindowController
        let title: String
        let detail: String
        let status: String
        /// Memory of its page process, only on the first tab using that process (0 on the others).
        let bytes: UInt64
        /// % CPU of its page process (one core = 100%), only on the first tab using that process.
        let cpuPercent: Double
        let isSleeping: Bool
        let isActive: Bool
    }

    private var rows: [Row] = []
    private let table = DeletableTableView()
    private let totalLabel = NSTextField(labelWithString: "")
    private let sleepButton = NSButton()
    private let closeButton = NSButton()
    private var timer: Timer?
    private let cpuTracker = CPUUsageTracker()
    private var services: BrowserServices { .shared }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Task Manager")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AskaraTaskManager")
        window.minSize = NSSize(width: 520, height: 280)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        reload()
        showWindow(nil)
        window?.makeFirstResponder(table)
        startTimer()
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        for (id, title, width) in [("tab", String(localized: "Tab"), 300.0), ("status", String(localized: "Status"), 170.0),
                                   ("cpu", String(localized: "CPU"), 70.0), ("memory", String(localized: "Memory"), 100.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            if id == "memory" { column.sortDescriptorPrototype = NSSortDescriptor(key: "memory", ascending: false) }
            if id == "cpu" { column.sortDescriptorPrototype = NSSortDescriptor(key: "cpu", ascending: false) }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(showSelected(_:))
        table.setAccessibilityLabel(String(localized: "Tabs and memory use"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        totalLabel.textColor = .secondaryLabelColor
        totalLabel.lineBreakMode = .byTruncatingTail
        totalLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, title, action) in [(sleepButton, String(localized: "Sleep Tab"), #selector(sleepSelected(_:))),
                                        (closeButton, String(localized: "Close Tab"), #selector(closeSelected(_:)))] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        let footer = NSStackView(views: [totalLabel, NSView(), sleepButton, closeButton])
        footer.spacing = 8

        for v in [scroll, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
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

    // MARK: - Data

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { TaskManagerWindowController.shared.reload() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowWillClose(_ notification: Notification) {
        // No polling while closed.
        timer?.invalidate()
        timer = nil
    }

    private func reload() {
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].tab.id : nil })
        var counted = Set<pid_t>()
        var cpuCounted = Set<pid_t>()
        var sharing: [pid_t: Int] = [:]
        let windows = services.windows
        for window in windows { for web in window.loadedWebViews { if let pid = web.askaraProcessID { sharing[pid, default: 0] += 1 } } }
        let showProfile = services.profileList.profiles.count > 1

        var result: [Row] = []
        for window in windows {
            for tab in window.allTabs {
                let web = tab.webView
                let pid = web?.askaraProcessID
                var bytes: UInt64 = 0
                if let pid, counted.insert(pid).inserted { bytes = ProcessMemory.footprint(pid: pid) ?? 0 }
                var cpuPercent: Double = 0
                if let pid, cpuCounted.insert(pid).inserted { cpuPercent = cpuTracker.usage(pid: pid) }
                var status: String
                if web == nil {
                    status = String(localized: "Sleeping")
                } else if window.isActive(tab) {
                    status = String(localized: "Active")
                } else if tab.isPinned {
                    status = String(localized: "Pinned (never sleeps)")
                } else if tab.isPlayingAudio {
                    status = String(localized: "Playing audio")
                } else {
                    status = String(localized: "Awake")
                }
                if let pid, let count = sharing[pid], count > 1 {
                    status += " · " + String(localized: "shares memory with \(count - 1) tabs")
                }
                var detail = AddressParser.displayString(for: web?.url ?? tab.url)
                if window.isPrivate { detail = String(localized: "Private") + " · " + detail }
                else if showProfile { detail = window.profile.profile.name + " · " + detail }
                result.append(Row(tab: tab, window: window, title: tab.title, detail: detail, status: status,
                                  bytes: bytes, cpuPercent: cpuPercent, isSleeping: web == nil, isActive: window.isActive(tab)))
            }
        }
        cpuTracker.prune(keeping: Set(result.compactMap { $0.tab.webView?.askaraProcessID }))
        if let sort = table.sortDescriptors.first {
            if sort.key == "memory" { result.sort { sort.ascending ? $0.bytes < $1.bytes : $0.bytes > $1.bytes } }
            else if sort.key == "cpu" { result.sort { sort.ascending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent } }
        }
        rows = result

        let pages = result.reduce(UInt64(0)) { $0 + $1.bytes }
        let app = ProcessMemory.footprint(pid: getpid()) ?? 0
        let awake = result.filter { !$0.isSleeping }.count
        totalLabel.stringValue = String(localized: "Askara: \(ProcessMemory.format(app + pages)) (app \(ProcessMemory.format(app)), pages \(ProcessMemory.format(pages))) · \(awake) of \(result.count) tabs awake")
        totalLabel.toolTip = String(localized: "Extensions and WebKit's shared network and graphics processes aren't included.")

        table.reloadData()
        let restore = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].tab.id) })
        table.selectRowIndexes(restore, byExtendingSelection: false)
        updateButtons()
    }

    private var selectedRows: [Row] {
        var indexes = table.selectedRowIndexes
        if table.clickedRow >= 0, !indexes.contains(table.clickedRow) { indexes = [table.clickedRow] }
        return indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    private func updateButtons() {
        let selected = selectedRows
        sleepButton.isEnabled = selected.contains { !$0.isSleeping && !$0.isActive }
        closeButton.isEnabled = !selected.isEmpty
    }

    // MARK: - Actions

    @objc private func sleepSelected(_ sender: Any?) {
        for row in selectedRows where !row.isSleeping && !row.isActive {
            row.window.hibernate(tabIDs: [row.tab.id], force: true)
        }
        reload()
    }

    @objc private func closeSelected(_ sender: Any?) {
        selectedRows.forEach { $0.window.close(tab: $0.tab) }
        reload()
    }

    /// Delete key closes the selected tabs.
    @objc func delete(_ sender: Any?) { closeSelected(sender) }

    @objc private func showSelected(_ sender: Any?) {
        guard let row = selectedRows.first else { return }
        row.window.activate(tab: row.tab)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 34 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        switch id.rawValue {
        case "tab":
            cell.textField?.stringValue = item.title
            (cell.viewWithTag(2) as? NSTextField)?.stringValue = item.detail
            cell.imageView?.image = FaviconStore.shared.icon(for: item.tab.url)
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            cell.imageView?.alphaValue = item.isSleeping ? 0.45 : 1
            cell.setAccessibilityLabel("\(item.title), \(item.detail)")
        case "status":
            cell.textField?.stringValue = item.status
            cell.textField?.textColor = item.isSleeping ? .secondaryLabelColor : .labelColor
        case "cpu":
            cell.textField?.stringValue = item.isSleeping ? "–" : String(format: "%.0f%%", item.cpuPercent)
            cell.textField?.alignment = .right
        default:
            cell.textField?.stringValue = item.bytes > 0 ? ProcessMemory.format(item.bytes)
                : (item.isSleeping ? "0 MB" : "–")
            cell.textField?.alignment = .right
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        if id.rawValue == "tab" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.imageView = icon
            let detail = NSTextField(labelWithString: "")
            detail.tag = 2
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(detail)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 1),
                detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: text.trailingAnchor),
                detail.topAnchor.constraint(equalTo: text.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}
