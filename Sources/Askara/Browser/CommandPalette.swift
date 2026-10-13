import AppKit
import AskaraCore

/// Panel that can take the keyboard even though it has no title bar.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// ⌘K: one search field for open tabs, menu commands, bookmarks, and history.
/// Enter runs the selected row; typed text can also be opened directly as an address or search.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Item {
        enum Kind { case tab, command, bookmark, history, open }
        let kind: Kind
        let title: String
        let detail: String
        /// Right-aligned text: the shortcut of a command, or the kind of row.
        let accessory: String
        let icon: NSImage?
        /// Long text (URLs) is matched without loose letter-by-letter matching.
        let matchesDetailExactly: Bool
        let run: () -> Void
    }

    private static weak var current: CommandPalette?

    private weak var browser: BrowserWindowController?
    private let services: BrowserServices
    private let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                                     styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
    private let searchField = NSTextField()
    private let table = NSTableView()
    private var catalog: [Item] = []
    private var results: [Item] = []
    /// Keeps the palette alive while its panel is open.
    private var selfReference: CommandPalette?

    private init(browser: BrowserWindowController, services: BrowserServices) {
        self.browser = browser
        self.services = services
        super.init()
    }

    static func toggle(for browser: BrowserWindowController, services: BrowserServices) {
        if let current, current.panel.isVisible { return current.panel.close() }
        let palette = CommandPalette(browser: browser, services: services)
        // Commands are read while the browser window is still key, so the menu validates them
        // against that window (Back is only offered when the page can go back, and so on).
        palette.catalog = palette.buildCatalog()
        palette.buildUI()
        palette.filter()
        palette.present()
        current = palette
    }

    // MARK: - Catalog

    private func buildCatalog() -> [Item] {
        guard let browser else { return [] }
        let profile = browser.profile
        var items: [Item] = []

        // Open tabs of this profile and mode, most recently used first.
        let windows = services.windows.filter { $0.profile === profile && $0.isPrivate == browser.isPrivate }
        let tabs = windows.flatMap { window in window.allTabs.map { (window, $0) } }
            .sorted { $0.1.lastActive > $1.1.lastActive }
        for (window, tab) in tabs {
            let url = tab.webView?.url ?? tab.url
            items.append(Item(kind: .tab, title: tab.title.isEmpty ? String(localized: "New Tab") : tab.title,
                              detail: url.map { AddressParser.displayString(for: $0) } ?? "",
                              accessory: window.isActive(tab) && window === browser ? String(localized: "Current Tab")
                                                                                     : String(localized: "Switch to Tab"),
                              icon: FaviconStore.shared.icon(for: url), matchesDetailExactly: true) { [weak window, weak tab] in
                guard let window, let tab else { return }
                window.activate(tab: tab)
                window.window?.makeKeyAndOrderFront(nil)
            })
        }

        items += commandItems()

        for bookmark in profile.bookmarks.bookmarks {
            items.append(linkItem(.bookmark, url: bookmark.url, title: bookmark.title,
                                  accessory: String(localized: "Bookmark"), symbol: "star"))
        }
        // History can hold thousands of pages; the most recent ones are enough here.
        let bookmarked = Set(profile.bookmarks.bookmarks.map(\.url))
        for entry in profile.history.entries.prefix(1500)
        where HistoryStore.isRecordable(entry.url) && !bookmarked.contains(entry.url) {
            items.append(linkItem(.history, url: entry.url, title: entry.title,
                                  accessory: String(localized: "History"), symbol: "clock"))
        }
        return items
    }

    private func linkItem(_ kind: Item.Kind, url: URL, title: String, accessory: String, symbol: String) -> Item {
        let address = AddressParser.displayString(for: url)
        return Item(kind: kind, title: title.isEmpty ? address : title, detail: address, accessory: accessory,
                    icon: FaviconStore.shared.icon(for: url) ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                    matchesDetailExactly: true) { [weak self] in self?.browser?.newTab(url: url) }
    }

    /// Lists, row by row, are rebuilt elsewhere; their commands are covered by the tab and link rows.
    private static let excludedActions: Set<Selector> = [
        #selector(AppDelegate.openMenuURL(_:)), #selector(AppDelegate.openAllMenuURLs(_:)),
        #selector(BrowserWindowController.selectTabFromMenu(_:)),
        #selector(BrowserWindowController.selectTabNumberAction(_:)),
        #selector(BrowserWindowController.showCommandPaletteAction(_:)),
    ]

    /// Every enabled, visible menu bar command, with its menu path ("Develop › User Agent").
    private func commandItems() -> [Item] {
        guard let main = NSApp.mainMenu else { return [] }
        var items: [Item] = []
        var seen = Set<String>()

        func walk(_ menu: NSMenu, path: [String]) {
            // Fills dynamic menus (Profiles, Open Page With) and refreshes titles and enabled states.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu {
                    let title = submenu.title.isEmpty ? item.title : submenu.title
                    walk(submenu, path: path + [title])
                    continue
                }
                guard let action = item.action, item.isEnabled, !Self.excludedActions.contains(action),
                      !item.title.isEmpty else { continue }
                let pathText = path.joined(separator: " › ")
                guard seen.insert(pathText + "\u{1}" + item.title).inserted else { continue }
                items.append(Item(kind: .command, title: item.title, detail: pathText,
                                  accessory: Self.shortcut(for: item), icon: item.image ?? Self.symbol("command"),
                                  matchesDetailExactly: false) { [weak item] in
                    guard let item, let action = item.action else { return }
                    NSApp.sendAction(action, to: item.target, from: item)
                })
            }
        }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            walk(submenu, path: [submenu.title.isEmpty ? top.title : submenu.title])
        }
        return items
    }

    static func shortcut(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mods = item.keyEquivalentModifierMask
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        let key: String = switch item.keyEquivalent {
        case "\u{8}", "\u{7F}": "⌫"
        case "\r": "↩"
        case "\u{1B}": "⎋"
        case " ": String(localized: "Space")
        default: item.keyEquivalent.uppercased()
        }
        return text + key
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: - Filtering

    private func filter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            // Nothing typed: tabs to jump back to, then commands.
            results = Array((catalog.filter { $0.kind == .tab } + catalog.filter { $0.kind == .command }).prefix(60))
        } else {
            let bonus: [Item.Kind: Int] = [.tab: 600, .command: 500, .bookmark: 300, .history: 0]
            var scored: [(item: Item, score: Int)] = []
            for item in catalog {
                let titleScore = FuzzyMatcher.score(query, in: item.title)
                let detailScore = FuzzyMatcher.score(query, in: item.detail, allowsSubsequence: !item.matchesDetailExactly)
                    .map { $0 - 200 } // The name matters more than where it lives.
                let combined = FuzzyMatcher.score(query, in: item.title + " " + item.detail, allowsSubsequence: false)
                    .map { $0 - 400 } // Words split between title and address ("github pull").
                guard let best = [titleScore, detailScore, combined].compactMap({ $0 }).max() else { continue }
                scored.append((item, best + (bonus[item.kind] ?? 0)))
            }
            scored.sort { $0.score > $1.score }
            results = scored.prefix(50).map(\.item)
            if let open = openItem(for: query) {
                // An address is clearly meant to be opened; a plain search is a last resort.
                let isDirect = AddressParser.url(from: query, searchTemplate: services.searchEngine.searchTemplate)
                    != services.searchEngine.searchURL(for: query)
                if isDirect || results.isEmpty { results.insert(open, at: 0) } else { results.append(open) }
            }
        }
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// "Open example.com" or "Search Google for …" in a new tab.
    private func openItem(for query: String) -> Item? {
        guard let url = AddressParser.url(from: query, searchTemplate: services.searchEngine.searchTemplate) else { return nil }
        let title: String
        if url == services.searchEngine.searchURL(for: query) {
            title = String(localized: "Search \(services.searchEngine.name) for “\(query)”")
        } else {
            title = String(localized: "Open \(AddressParser.displayString(for: url))")
        }
        return Item(kind: .open, title: title, detail: String(localized: "New tab"), accessory: "↩",
                    icon: Self.symbol("magnifyingglass"), matchesDetailExactly: true) { [weak self] in
            self?.browser?.newTab(url: url)
        }
    }

    // MARK: - UI

    private func buildUI() {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.setAccessibilityLabel(String(localized: "Command Palette"))

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        searchField.placeholderString = String(localized: "Search tabs, commands, bookmarks, and history")
        searchField.font = .systemFont(ofSize: 18)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.setAccessibilityLabel(String(localized: "Command palette search"))
        searchField.setAccessibilityIdentifier("askara.commandPalette.search")

        let separator = NSBox()
        separator.boxType = .separator

        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.setAccessibilityLabel(String(localized: "Command palette results"))
        table.setAccessibilityIdentifier("askara.commandPalette.results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [searchField, separator, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
        panel.contentView = background
    }

    private func present() {
        guard let parent = browser?.window else { return }
        let size = panel.frame.size
        let frame = parent.frame
        // Centered over the browser window, near the top like Spotlight.
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - min(140, frame.height * 0.15))
        panel.setFrameOrigin(origin)
        selfReference = self
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func run(_ item: Item) {
        let browserWindow = browser?.window
        panel.close()
        // Commands act on the key window, so hand the keyboard back to the browser first.
        browserWindow?.makeKeyAndOrderFront(nil)
        item.run()
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard results.indices.contains(table.clickedRow) else { return }
        run(results[table.clickedRow])
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { panel.close() }
    }

    func windowWillClose(_ notification: Notification) {
        // Release once the current event finishes, after the row's action has run.
        DispatchQueue.main.async { [self] in selfReference = nil }
    }

    // MARK: - Keyboard

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if results.indices.contains(table.selectedRow) { run(results[table.selectedRow]) }
        case #selector(NSResponder.cancelOperation(_:)): panel.close()
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = (max(0, table.selectedRow) + delta + results.count) % results.count
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("command-palette-row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteRowView ?? PaletteRowView()
        cell.identifier = id
        cell.configure(results[row])
        return cell
    }
}

/// Icon, title, detail (menu path or address), and shortcut.
private final class PaletteRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        accessory.font = .systemFont(ofSize: 12)
        accessory.textColor = .secondaryLabelColor
        accessory.alignment = .right
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        for view in [icon, labels, accessory] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: CommandPalette.Item) {
        icon.image = item.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        title.stringValue = item.title
        detail.stringValue = item.detail
        detail.isHidden = item.detail.isEmpty
        accessory.stringValue = item.accessory
        setAccessibilityLabel([item.title, item.detail, item.accessory].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
