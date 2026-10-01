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
    private let defaultStatus = NSTextField(labelWithString: "")
    private let defaultButton = NSButton()
    private let barBox = NSButton(checkboxWithTitle: String(localized: "Show bookmarks bar"), target: nil, action: nil)
    private let syncBox = NSButton(checkboxWithTitle: String(localized: "Sync encrypted browser data through a folder"), target: nil, action: nil)
    private let syncFolderButton = NSButton(title: String(localized: "Choose Folder…"), target: nil, action: nil)
    private let syncStatus = NSTextField(wrappingLabelWithString: "")
    // Memory Saver
    private let sleepPopup = NSPopUpButton()
    private let dozePopup = NSPopUpButton()
    private let maxTabsStepper = NSStepper()
    private let maxTabsLabel = NSTextField(labelWithString: "")
    private let memoryBudgetPopup = NSPopUpButton()
    private let protectedStepper = NSStepper()
    private let protectedLabel = NSTextField(labelWithString: "")
    private let awakeTable = NSTableView()
    private let awakeField = NSTextField()
    // Privacy
    private let httpsOnlyBox = NSButton(checkboxWithTitle: String(localized: "Always use secure connections (HTTPS-Only Mode)"),
                                        target: nil, action: nil)
    // Permissions
    private let permissionTable = NSTableView()
    private var permissionRows: [(host: String, kind: PermissionKind, choice: PermissionChoice)] = []
    // Extensions
    private let extensionTable = NSTableView()
    private let extensionToggleButton = NSButton()
    private let extensionPinButton = NSButton()

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
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .askaraSyncChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .askaraExtensionsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showExtensions() {
        guard services.currentProfile.engineRuntime.capabilities.supports(.extensions) else {
            showUnavailableFeature(.extensions)
            return
        }
        show()
        if let item = tabView.tabViewItems.first(where: { $0.identifier as? String == "extensions" }) {
            tabView.selectTabViewItem(item)
        }
    }

    private func showUnavailableFeature(_ feature: BrowserEngineFeature) {
        let runtime = services.currentProfile.engineRuntime
        let capability = runtime.capabilities[feature]
        let alert = NSAlert()
        alert.messageText = String(localized: "This feature isn't available with \(runtime.engine.name)")
        alert.informativeText = capability.note ?? String(localized: "The selected engine does not support this feature.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
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
        addPage(String(localized: "Extensions"), extensionsPage(), identifier: "extensions")
    }

    private func addPage(_ title: String, _ content: NSView, identifier: String? = nil) {
        let item = NSTabViewItem()
        item.label = title
        item.identifier = identifier
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

        defaultButton.title = String(localized: "Make Default")
        defaultButton.bezelStyle = .rounded
        defaultButton.target = self
        defaultButton.action = #selector(makeDefault(_:))
        let defaultRow = NSStackView(views: [defaultStatus, defaultButton])
        defaultRow.spacing = 8
        barBox.target = self
        barBox.action = #selector(barChanged(_:))
        syncBox.target = self
        syncBox.action = #selector(syncChanged(_:))
        syncFolderButton.target = self
        syncFolderButton.action = #selector(chooseSyncFolder(_:))
        syncStatus.textColor = .secondaryLabelColor
        syncStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let grid = NSGridView(views: [
            [label(String(localized: "Default browser:")), defaultRow],
            [label(String(localized: "Search engine:")), enginePopup],
            [label(String(localized: "Home page:")), homeField],
            [NSGridCell.emptyContentView, useCurrent],
            [NSGridCell.emptyContentView, barBox],
            [NSGridCell.emptyContentView, syncBox],
            [NSGridCell.emptyContentView, syncFolderButton],
            [NSGridCell.emptyContentView, syncStatus],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        return stack([
            grid,
            note(String(localized: "New tabs and windows open the home page. Leave it empty to use the search engine's page.")),
        ])
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

        for minutes in BrowserPreferences.dozeChoices {
            dozePopup.addItem(withTitle: minutes == 0 ? String(localized: "Off")
                                                      : String(localized: "After \(minutes) min"))
            dozePopup.lastItem?.tag = minutes
        }
        dozePopup.target = self
        dozePopup.action = #selector(dozeChanged(_:))
        dozePopup.setAccessibilityLabel(String(localized: "Pause background tabs"))

        maxTabsStepper.minValue = Double(BrowserPreferences.maxLoadedTabRange.lowerBound)
        maxTabsStepper.maxValue = Double(BrowserPreferences.maxLoadedTabRange.upperBound)
        maxTabsStepper.increment = 1
        maxTabsStepper.target = self
        maxTabsStepper.action = #selector(maxTabsChanged(_:))
        maxTabsStepper.setAccessibilityLabel(String(localized: "Maximum awake tabs"))
        let tabsRow = NSStackView(views: [maxTabsLabel, maxTabsStepper])
        tabsRow.spacing = 6

        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        for percent in BrowserPreferences.memoryBudgetChoices {
            let title: String
            if percent == 0 {
                title = String(localized: "No limit")
            } else {
                let budget = Double(HibernationPolicy.memoryBudget(percent: percent) ?? 0) / 1_073_741_824
                title = String(localized: "\(percent)% of RAM (\(String(format: "%.1f", budget)) of \(String(format: "%.0f", ramGB)) GB)")
            }
            memoryBudgetPopup.addItem(withTitle: title)
            memoryBudgetPopup.lastItem?.tag = percent
        }
        memoryBudgetPopup.target = self
        memoryBudgetPopup.action = #selector(memoryBudgetChanged(_:))
        memoryBudgetPopup.setAccessibilityLabel(String(localized: "Memory limit for tabs"))

        protectedStepper.minValue = Double(BrowserPreferences.protectedTabRange.lowerBound)
        protectedStepper.maxValue = Double(BrowserPreferences.protectedTabRange.upperBound)
        protectedStepper.increment = 1
        protectedStepper.target = self
        protectedStepper.action = #selector(protectedTabsChanged(_:))
        protectedStepper.setAccessibilityLabel(String(localized: "Recently used tabs kept awake"))
        let protectedRow = NSStackView(views: [protectedLabel, protectedStepper])
        protectedRow.spacing = 6

        let grid = NSGridView(views: [
            [label(String(localized: "Pause background tabs:")), dozePopup],
            [label(String(localized: "Put background tabs to sleep:")), sleepPopup],
            [label(String(localized: "Maximum awake tabs:")), tabsRow],
            [label(String(localized: "Memory limit for tabs:")), memoryBudgetPopup],
            [label(String(localized: "Recently used tabs kept awake:")), protectedRow],
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
            note(String(localized: "Paused tabs stay loaded (no reload) but their media stops and caches are freed. Sleeping tabs use no RAM and reload when you open them, showing their last view meanwhile. Tabs with unsent form input, playing audio, or pinned tabs don't sleep. When macOS runs low on memory, background tabs sleep regardless of these settings.")),
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

    private func extensionsPage() -> NSView {
        for (id, title, width) in [("name", String(localized: "Extension"), 280.0),
                                   ("status", String(localized: "Status"), 110.0),
                                   ("pinned", String(localized: "Toolbar"), 110.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            extensionTable.addTableColumn(column)
        }
        extensionTable.dataSource = self
        extensionTable.delegate = self
        extensionTable.usesAlternatingRowBackgroundColors = true
        extensionTable.allowsEmptySelection = true
        extensionTable.setAccessibilityLabel(String(localized: "Installed Safari Web Extensions"))
        extensionToggleButton.title = String(localized: "Enable")
        extensionToggleButton.target = self
        extensionToggleButton.action = #selector(toggleSelectedExtension(_:))
        extensionPinButton.title = String(localized: "Pin to Toolbar")
        extensionPinButton.target = self
        extensionPinButton.action = #selector(pinSelectedExtension(_:))
        let actions = NSStackView(views: [extensionToggleButton, extensionPinButton])
        actions.spacing = 8
        return stack([
            note(String(localized: "Safari Web Extensions are managed per profile. Enabled extensions can access pages according to the permissions you approve.")),
            tableScroll(extensionTable, height: 250), actions,
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

    // MARK: - Default browser

    private var isDefaultBrowser: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func updateDefaultStatus() {
        let isDefault = isDefaultBrowser
        defaultStatus.stringValue = isDefault ? String(localized: "Askara is your default browser")
                                              : String(localized: "Askara isn't your default browser")
        defaultButton.isHidden = isDefault
    }

    /// macOS shows its own confirmation ("Use Askara or keep Safari?").
    @objc private func makeDefault(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        guard Bundle.main.bundleIdentifier != nil, app.pathExtension == "app" else {
            defaultStatus.stringValue = String(localized: "Open Askara from Askara.app to set it as default.")
            return
        }
        let group = DispatchGroup()
        var failure: Error?
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if let error { failure = error }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                if let failure { Log.error("Askara: set default browser failed: \(failure)") }
                self?.updateDefaultStatus()
            }
        }
    }

    @objc private func barChanged(_ sender: NSButton) {
        services.updatePreferences { $0.showsBookmarksBar = sender.state == .on }
    }

    @objc private func syncChanged(_ sender: NSButton) {
        if sender.state == .on, services.sync.folderURL == nil {
            chooseSyncFolder(sender)
        } else {
            services.sync.setEnabled(sender.state == .on)
        }
    }

    @objc private func chooseSyncFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Sync Folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let folder = services.sync.folderURL { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let folder = panel.url else {
            syncBox.state = services.preferences.syncEnabled ? .on : .off
            return
        }
        services.sync.setFolder(folder)
    }

    /// The choice can change in System Settings while this window is open.
    func windowDidBecomeKey(_ notification: Notification) { updateDefaultStatus() }

    @objc private func reload() {
        let prefs = services.preferences
        updateDefaultStatus()
        barBox.state = prefs.showsBookmarksBar ? .on : .off
        syncBox.state = prefs.syncEnabled ? .on : .off
        syncStatus.stringValue = services.sync.status
        syncFolderButton.title = prefs.syncFolderPath.isEmpty ? String(localized: "Choose Folder…")
                                                               : String(localized: "Change Folder…")
        syncFolderButton.toolTip = services.sync.folderDisplayName
        enginePopup.selectItem(at: SearchEngine.all.firstIndex { $0.id == prefs.searchEngine.id } ?? 0)
        if homeField.currentEditor() == nil { homeField.stringValue = prefs.homePage }
        homeField.placeholderString = prefs.searchEngine.homeURL.absoluteString
        if !sleepPopup.selectItem(withTag: prefs.sleepAfterMinutes) { sleepPopup.selectItem(withTag: 5) }
        if !dozePopup.selectItem(withTag: prefs.dozeAfterMinutes) { dozePopup.selectItem(withTag: 1) }
        maxTabsStepper.integerValue = prefs.maxLoadedTabs
        maxTabsLabel.stringValue = "\(prefs.maxLoadedTabs)"
        if !memoryBudgetPopup.selectItem(withTag: prefs.memoryBudgetPercent) { memoryBudgetPopup.selectItem(withTag: 25) }
        protectedStepper.integerValue = prefs.protectedTabs
        protectedLabel.stringValue = "\(prefs.protectedTabs)"
        httpsOnlyBox.state = prefs.httpsOnly ? .on : .off
        let permissions = services.currentProfile.permissions
        permissionRows = permissions.hosts.flatMap { host in
            PermissionKind.allCases.compactMap { kind in
                permissions.choice(kind, host: host).map { (host, kind, $0) }
            }
        }
        awakeTable.reloadData()
        permissionTable.reloadData()
        extensionTable.reloadData()
        updateExtensionButtons()
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

    @objc private func dozeChanged(_ sender: NSPopUpButton) {
        let minutes = sender.selectedTag()
        services.updatePreferences { $0.dozeAfterMinutes = minutes }
    }

    @objc private func memoryBudgetChanged(_ sender: NSPopUpButton) {
        let percent = sender.selectedTag()
        services.updatePreferences { $0.memoryBudgetPercent = percent }
    }

    @objc private func protectedTabsChanged(_ sender: NSStepper) {
        let count = sender.integerValue
        protectedLabel.stringValue = "\(count)"
        services.updatePreferences { $0.protectedTabs = count }
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
        let profile = services.currentProfile
        rows.forEach { profile.setPermission(nil, for: $0.kind, host: $0.host) }
    }

    @objc private func toggleSelectedExtension(_ sender: Any?) {
        let manager = services.currentProfile.extensions
        guard manager.installed.indices.contains(extensionTable.selectedRow) else { return NSSound.beep() }
        let item = manager.installed[extensionTable.selectedRow]
        let menuItem = NSMenuItem()
        menuItem.representedObject = InstalledExtensionBox(item)
        (NSApp.delegate as? AppDelegate)?.toggleExtensionAction(menuItem)
    }

    @objc private func pinSelectedExtension(_ sender: Any?) {
        let manager = services.currentProfile.extensions
        guard manager.installed.indices.contains(extensionTable.selectedRow) else { return NSSound.beep() }
        let item = manager.installed[extensionTable.selectedRow]
        guard manager.isEnabled(item) else { return NSSound.beep() }
        manager.setPinned(!manager.isPinned(item), item: item)
    }

    private func updateExtensionButtons() {
        let manager = services.currentProfile.extensions
        guard manager.installed.indices.contains(extensionTable.selectedRow) else {
            extensionToggleButton.isEnabled = false
            extensionPinButton.isEnabled = false
            return
        }
        let item = manager.installed[extensionTable.selectedRow]
        let enabled = manager.isEnabled(item)
        extensionToggleButton.isEnabled = true
        extensionToggleButton.title = enabled ? String(localized: "Disable") : String(localized: "Enable")
        extensionPinButton.isEnabled = enabled
        extensionPinButton.title = manager.isPinned(item) ? String(localized: "Unpin from Toolbar")
                                                        : String(localized: "Pin to Toolbar")
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === awakeTable { return services.preferences.keepAwakeSites.count }
        if tableView === extensionTable { return services.currentProfile.extensions.installed.count }
        return permissionRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === awakeTable {
            text = services.preferences.keepAwakeSites[row]
        } else if tableView === extensionTable {
            let manager = services.currentProfile.extensions
            let item = manager.installed[row]
            switch tableColumn?.identifier.rawValue {
            case "status": text = manager.isEnabled(item) ? String(localized: "Enabled") : String(localized: "Disabled")
            case "pinned": text = manager.isPinned(item) ? String(localized: "Pinned") : "—"
            default: text = item.name
            }
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === extensionTable { updateExtensionButtons() }
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    /// Save the home page when leaving the field too, not only on Enter.
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === homeField { homeChanged(homeField) }
    }
}
