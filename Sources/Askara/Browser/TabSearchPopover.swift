import AppKit
import AskaraCore

@MainActor
final class TabSearchPopover: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Result {
        let title: String
        let detail: String
        let icon: NSImage?
        let action: () -> Void
    }

    private let services: BrowserServices
    private let profile: ProfileData
    private let isPrivate: Bool
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private var allResults: [Result] = []
    private var results: [Result] = []
    private weak var popover: NSPopover?

    private init(services: BrowserServices, profile: ProfileData, isPrivate: Bool) {
        self.services = services
        self.profile = profile
        self.isPrivate = isPrivate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func show(services: BrowserServices, profile: ProfileData, isPrivate: Bool, relativeTo view: NSView) {
        let controller = TabSearchPopover(services: services, profile: profile, isPrivate: isPrivate)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 430)
        popover.contentViewController = controller
        controller.popover = popover
        popover.show(relativeTo: NSRect(x: view.bounds.maxX - 38, y: 0, width: 30, height: view.bounds.height),
                     of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(controller.searchField)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 430))
        let title = NSTextField(labelWithString: String(localized: "Search Tabs"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        searchField.placeholderString = String(localized: "Search open and recently closed tabs")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(openSelected(_:))
        searchField.setAccessibilityLabel(String(localized: "Search tabs"))

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel(String(localized: "Tab search results"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        for item in [title, searchField, scroll] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        rebuild()
    }

    private func rebuild() {
        allResults = services.windows
            .filter { $0.profile === profile && $0.isPrivate == isPrivate }
            .flatMap { window in
                window.allTabs.map { tab in
                    let url = tab.webView?.url ?? tab.url
                    return Result(title: tab.title, detail: url?.absoluteString ?? String(localized: "New Tab"),
                                  icon: FaviconStore.shared.icon(for: url)) { [weak window, weak tab, weak popover] in
                        guard let window, let tab else { return }
                        window.activate(tab: tab)
                        window.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate()
                        popover?.performClose(nil)
                    }
                }
            }
        if !isPrivate {
            for entry in profile.recentlyClosed.items.reversed() {
                switch entry {
                case .tab(let id, _, let tab):
                    allResults.append(closedResult(id: id, tab: tab, selectedTab: nil))
                case .window(let id, _, let window):
                    for (index, tab) in window.tabs.enumerated() {
                        allResults.append(closedResult(id: id, tab: tab, selectedTab: index))
                    }
                }
            }
        }
        filter()
    }

    private func closedResult(id: UUID, tab: SessionState.SavedTab, selectedTab: Int?) -> Result {
        Result(title: tab.title, detail: String(localized: "Recently closed · \(tab.url.absoluteString)"),
               icon: FaviconStore.shared.icon(for: tab.url)) { [weak self] in
            guard let self else { return }
            services.reopenRecentlyClosed(id, profile: profile, selectedTab: selectedTab)
            popover?.performClose(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    private func filter() {
        let words = searchField.stringValue.lowercased().split(whereSeparator: \.isWhitespace)
        results = allResults.filter { result in
            let text = "\(result.title) \(result.detail)".lowercased()
            return words.allSatisfy(text.contains)
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("tab-search-result")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 12, weight: .medium)
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical
            labels.spacing = 1
            labels.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = image
            cell.textField = title
            cell.addSubview(image)
            cell.addSubview(labels)
            detail.identifier = .init("detail")
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                labels.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let result = results[row]
        cell.imageView?.image = result.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        cell.textField?.stringValue = result.title
        cell.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews
            .compactMap { $0 as? NSTextField }.last?.stringValue = result.detail
        return cell
    }

    @objc private func openSelected(_ sender: Any?) {
        guard results.indices.contains(table.selectedRow) else { return }
        results[table.selectedRow].action()
    }
}
