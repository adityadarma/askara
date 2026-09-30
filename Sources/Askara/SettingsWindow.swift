import AppKit
import AskaraCore

/// Settings (⌘,): General, Memory Saver, Privacy & Security, Site Permissions.
/// Changes are saved right away, like macOS System Settings.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let services = BrowserServices.shared
    private let tabView = NSTabView()

    // General
    private let enginePopup = NSPopUpButton()
    private let homeField = NSTextField()
    // Memory Saver
    private let sleepPopup = NSPopUpButton()
    private let maxTabsStepper = NSStepper()
    private let maxTabsLabel = NSTextField(labelWithString: "")
    private let awakeTable = NSTableView()
    private let awakeField = NSTextField()
    // Privacy
    private let httpsOnlyBox = NSButton(checkboxWithTitle: String(localized: "Always use secure connections (HTTPS-Only Mode)"),
                                        target: nil, action: nil)
    // Permissions
    private let permissionTable = NSTableView()
    private var permissionRows: [(host: String, kind: PermissionKind, choice: PermissionChoice)] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .askaraPreferencesChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let root = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        addPage(String(localized: "General"), generalPage())
        addPage(String(localized: "Memory Saver"), memoryPage())
        addPage(String(localized: "Privacy & Security"), privacyPage())
        addPage(String(localized: "Site Permissions"), permissionsPage())
    }

    private func addPage(_ title: String, _ content: NSView) {
        let item = NSTabViewItem()
        item.label = title
        let holder = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor, constant: -16),
        ])
        item.view = holder
        tabView.addTabViewItem(item)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.preferredMaxLayoutWidth = 520
        return field
    }

    private func stack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func generalPage() -> NSView {
        SearchEngine.all.forEach { enginePopup.addItem(withTitle: $0.name) }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged(_:))
        enginePopup.setAccessibilityLabel(String(localized: "Search engine"))

        homeField.placeholderString = String(localized: "Search engine home page")
        homeField.target = self
        homeField.action = #selector(homeChanged(_:))
        homeField.delegate = self
        homeField.setAccessibilityLabel(String(localized: "Home page"))
        homeField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let useCurrent = NSButton(title: String(localized: "Use Current Page"), target: self,
                                  action: #selector(useCurrentPage(_:)))

        let grid = NSGridView(views: [
            [label(String(localized: "Search engine:")), enginePopup],
            [label(String(localized: "Home page:")), homeField],
            [NSGridCell.emptyContentView, useCurrent],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        return stack([grid, note(String(localized: "New tabs and windows open the home page. Leave it empty to use the search engine's page."))])
    }

    private func memoryPage() -> NSView {
        for minutes in BrowserPreferences.sleepChoices {
            sleepPopup.addItem(withTitle: minutes == 0 ? String(localized: "Never (only when over the limit)")
                                                       : String(localized: "After \(minutes) min"))
            sleepPopup.lastItem?.tag = minutes
        }
        sleepPopup.target = self
        sleepPopup.action = #selector(sleepChanged(_:))
        sleepPopup.setAccessibilityLabel(String(localized: "Put background tabs to sleep"))

        maxTabsStepper.minValue = Double(BrowserPreferences.maxLoadedTabRange.lowerBound)
        maxTabsStepper.maxValue = Double(BrowserPreferences.maxLoadedTabRange.upperBound)
        maxTabsStepper.increment = 1
        maxTabsStepper.target = self
        maxTabsStepper.action = #selector(maxTabsChanged(_:))
        maxTabsStepper.setAccessibilityLabel(String(localized: "Maximum awake tabs"))
        let tabsRow = NSStackView(views: [maxTabsLabel, maxTabsStepper])
        tabsRow.spacing = 6

        let grid = NSGridView(views: [
            [label(String(localized: "Put background tabs to sleep:")), sleepPopup],
            [label(String(localized: "Maximum awake tabs:")), tabsRow],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        let column = NSTableColumn(identifier: .init("site"))
        column.title = String(localized: "Always keep these sites awake")
        awakeTable.addTableColumn(column)
        awakeTable.dataSource = self
        awakeTable.delegate = self
        awakeTable.usesAlternatingRowBackgroundColors = true
        awakeTable.setAccessibilityLabel(String(localized: "Sites that never sleep"))
        let scroll = tableScroll(awakeTable, height: 130)

        awakeField.placeholderString = String(localized: "e.g. mail.google.com")
        awakeField.target = self
        awakeField.action = #selector(addAwakeSite(_:))
        awakeField.setAccessibilityLabel(String(localized: "Site to keep awake"))
        awakeField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let add = NSButton(title: String(localized: "Add"), target: self, action: #selector(addAwakeSite(_:)))
        let remove = NSButton(title: String(localized: "Remove"), target: self, action: #selector(removeAwakeSite(_:)))
        let row = NSStackView(views: [awakeField, add, remove])
        row.spacing = 6

        return stack([
            grid,
            note(String(localized: "Sleeping tabs use no RAM and reload when you open them. Tabs with unsent form input, playing audio, or pinned tabs don't sleep. When macOS runs low on memory, background tabs sleep regardless of these settings.")),
            scroll, row,
        ])
    }

    private func privacyPage() -> NSView {
        httpsOnlyBox.target = self
        httpsOnlyBox.action = #selector(httpsOnlyChanged(_:))
        return stack([
            httpsOnlyBox,
            note(String(localized: "Upgrades http:// addresses to https://. If a site doesn't support HTTPS, Askara asks before loading it. Local addresses (localhost, 192.168.x.x, .local) are left alone.")),
        ])
    }

    private func permissionsPage() -> NSView {
        for (id, title, width) in [("site", String(localized: "Site"), 260.0), ("kind", String(localized: "Permission"), 120.0),
                                   ("choice", String(localized: "Choice"), 100.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            permissionTable.addTableColumn(column)
        }
        permissionTable.dataSource = self
        permissionTable.delegate = self
        permissionTable.usesAlternatingRowBackgroundColors = true
        permissionTable.allowsMultipleSelection = true
        permissionTable.setAccessibilityLabel(String(localized: "Saved site permissions"))
        let scroll = tableScroll(permissionTable, height: 250)
        let forget = NSButton(title: String(localized: "Forget Selected"), target: self, action: #selector(forgetPermission(_:)))
        return stack([
            note(String(localized: "Choices you saved for camera, microphone, and location. Forgotten sites will ask again. macOS also asks once whether Askara itself may use the camera, microphone, or location.")),
            scroll, forget,
        ])
    }

    private func tableScroll(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return scroll
    }

    // MARK: - State

    @objc private func reload() {
        let prefs = services.preferences
        enginePopup.selectItem(at: SearchEngine.all.firstIndex { $0.id == prefs.searchEngine.id } ?? 0)
        if homeField.currentEditor() == nil { homeField.stringValue = prefs.homePage }
        homeField.placeholderString = prefs.searchEngine.homeURL.absoluteString
        if !sleepPopup.selectItem(withTag: prefs.sleepAfterMinutes) { sleepPopup.selectItem(withTag: 5) }
        maxTabsStepper.integerValue = prefs.maxLoadedTabs
        maxTabsLabel.stringValue = "\(prefs.maxLoadedTabs)"
        httpsOnlyBox.state = prefs.httpsOnly ? .on : .off
        let permissions = services.permissions
        permissionRows = permissions.hosts.flatMap { host in
            PermissionKind.allCases.compactMap { kind in
                permissions.choice(kind, host: host).map { (host, kind, $0) }
            }
        }
        awakeTable.reloadData()
        permissionTable.reloadData()
    }

    @objc private func engineChanged(_ sender: NSPopUpButton) {
        let engine = SearchEngine.all[max(0, sender.indexOfSelectedItem)]
        services.updatePreferences { $0.searchEngineID = engine.id }
    }

    @objc private func homeChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        services.updatePreferences { $0.homePage = text }
    }

    @objc private func useCurrentPage(_ sender: Any?) {
        guard let url = services.keyBrowserWindow?.currentTab?.url, ["http", "https"].contains(url.scheme ?? "") else {
            NSSound.beep()
            return
        }
        homeField.stringValue = url.absoluteString
        homeChanged(homeField)
    }

    @objc private func sleepChanged(_ sender: NSPopUpButton) {
        let minutes = sender.selectedTag()
        services.updatePreferences { $0.sleepAfterMinutes = minutes }
    }

    @objc private func maxTabsChanged(_ sender: NSStepper) {
        let count = sender.integerValue
        maxTabsLabel.stringValue = "\(count)"
        services.updatePreferences { $0.maxLoadedTabs = count }
    }

    @objc private func httpsOnlyChanged(_ sender: NSButton) {
        let on = sender.state == .on
        services.updatePreferences { $0.httpsOnly = on }
    }

    @objc private func addAwakeSite(_ sender: Any?) {
        let text = awakeField.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var added: String?
        services.updatePreferences { added = $0.addKeepAwakeSite(text) }
        if added == nil { NSSound.beep() } else { awakeField.stringValue = "" }
    }

    @objc private func removeAwakeSite(_ sender: Any?) {
        let sites = services.preferences.keepAwakeSites
        let selected = awakeTable.selectedRowIndexes.compactMap { sites.indices.contains($0) ? sites[$0] : nil }
        guard !selected.isEmpty else { return NSSound.beep() }
        services.updatePreferences { prefs in selected.forEach { prefs.removeKeepAwakeSite($0) } }
    }

    @objc private func forgetPermission(_ sender: Any?) {
        let rows = permissionTable.selectedRowIndexes.compactMap { permissionRows.indices.contains($0) ? permissionRows[$0] : nil }
        guard !rows.isEmpty else { return NSSound.beep() }
        rows.forEach { services.setPermission(nil, for: $0.kind, host: $0.host) }
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === awakeTable ? services.preferences.keepAwakeSites.count : permissionRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === awakeTable {
            text = services.preferences.keepAwakeSites[row]
        } else {
            let entry = permissionRows[row]
            switch tableColumn?.identifier.rawValue {
            case "kind":
                text = switch entry.kind {
                case .camera: String(localized: "Camera")
                case .microphone: String(localized: "Microphone")
                case .location: String(localized: "Location")
                }
            case "choice": text = entry.choice == .allow ? String(localized: "Allowed") : String(localized: "Blocked")
            default: text = entry.host
            }
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// Save the home page when leaving the field too, not only on Enter.
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === homeField { homeChanged(homeField) }
    }
}
