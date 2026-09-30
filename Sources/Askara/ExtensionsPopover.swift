import AppKit
import WebKit

@MainActor
final class ExtensionsPopoverController: NSViewController {
    private let profile: ProfileData
    private let activeTab: Tab?
    private let onOpen: (InstalledExtension) -> Void
    private let onManage: () -> Void
    private let onPinToggled: (() -> Void)?
    private var manager: ExtensionManager { profile.extensions }

    init(profile: ProfileData, activeTab: Tab?, onOpen: @escaping (InstalledExtension) -> Void,
         onManage: @escaping () -> Void, onPinToggled: (() -> Void)? = nil) {
        self.profile = profile
        self.activeTab = activeTab
        self.onOpen = onOpen
        self.onManage = onManage
        self.onPinToggled = onPinToggled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let installed = manager.installed
        let rowHeight: CGFloat = 38
        let listHeight: CGFloat = CGFloat(installed.isEmpty ? 56 : min(260, installed.count * Int(rowHeight)))
        let contentHeight: CGFloat = 12 + 28 + 8 + listHeight + 8 + 1 + 6 + 32 + 10
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: contentHeight))
        preferredContentSize = container.frame.size

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let title = NSTextField(labelWithString: String(localized: "Extensions"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = NSButton()
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))
        close.isBordered = false
        close.target = self
        close.action = #selector(closePopover(_:))
        close.contentTintColor = .secondaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])

        let header = NSStackView(views: [title, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(header)
        root.setCustomSpacing(8, after: header)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.distribution = .fill
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        if installed.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: String(localized: "No Safari extensions installed"))
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.font = .systemFont(ofSize: 13)
            empty.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(empty)
            NSLayoutConstraint.activate([
                empty.widthAnchor.constraint(equalTo: rows.widthAnchor),
                empty.heightAnchor.constraint(equalToConstant: listHeight),
            ])
        } else {
            for (offset, item) in installed.enumerated() {
                rows.addArrangedSubview(makeRow(item: item, index: offset, widthAnchor: rows.widthAnchor, height: rowHeight))
            }
        }

        let scroll = NSScrollView()
        scroll.documentView = rows
        scroll.hasVerticalScroller = installed.count > 6
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)
        root.setCustomSpacing(8, after: scroll)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(separator)
        root.setCustomSpacing(6, after: separator)

        let manage = NSButton(title: String(localized: "Manage Extensions"), target: self,
                              action: #selector(manageExtensions(_:)))
        manage.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: manage.title)
        manage.imagePosition = .imageLeading
        manage.alignment = .left
        manage.isBordered = false
        manage.font = .systemFont(ofSize: 13, weight: .regular)
        manage.contentTintColor = .labelColor
        manage.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(manage)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: listHeight),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            separator.widthAnchor.constraint(equalTo: root.widthAnchor),

            manage.widthAnchor.constraint(equalTo: root.widthAnchor),
            manage.heightAnchor.constraint(equalToConstant: 32),
        ])
        view = container
    }

    private func makeRow(item: InstalledExtension, index: Int, widthAnchor: NSLayoutDimension, height: CGFloat) -> NSView {
        let context = manager.context(for: item)
        let action = context?.action(for: activeTab)
        let enabled = manager.isEnabled(item)

        let icon = NSButton()
        icon.image = action?.icon(for: NSSize(width: 20, height: 20))
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: item.name)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.isBordered = false
        icon.target = self
        icon.action = #selector(openExtension(_:))
        icon.tag = index
        icon.isEnabled = enabled
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])

        let open = NSButton(title: item.name, target: self, action: #selector(openExtension(_:)))
        open.tag = index
        open.isBordered = false
        open.alignment = .left
        open.font = .systemFont(ofSize: 13)
        open.lineBreakMode = .byTruncatingTail
        open.isEnabled = enabled
        open.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)

        let pinned = manager.isPinned(item)
        let pin = NSButton()
        pin.tag = index
        pin.target = self
        pin.action = #selector(togglePin(_:))
        pin.isBordered = false
        pin.imagePosition = .imageOnly
        pin.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                            accessibilityDescription: pinned ? String(localized: "Unpin from Toolbar")
                                                             : String(localized: "Pin to Toolbar"))
        pin.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
        pin.isEnabled = enabled
        pin.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pin.widthAnchor.constraint(equalToConstant: 24),
            pin.heightAnchor.constraint(equalToConstant: 24),
        ])

        let more = NSButton(title: "⋮", target: self, action: #selector(showExtensionMenu(_:)))
        more.tag = index
        more.isBordered = false
        more.font = .systemFont(ofSize: 16, weight: .regular)
        more.contentTintColor = .secondaryLabelColor
        more.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            more.widthAnchor.constraint(equalToConstant: 24),
            more.heightAnchor.constraint(equalToConstant: 24),
        ])

        let row = NSStackView(views: [icon, open, spacer, pin, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: widthAnchor),
            row.heightAnchor.constraint(equalToConstant: height),
        ])
        return row
    }

    private func item(at index: Int) -> InstalledExtension? {
        manager.installed.indices.contains(index) ? manager.installed[index] : nil
    }

    @objc private func openExtension(_ sender: NSButton) {
        guard let item = item(at: sender.tag), manager.isEnabled(item) else { return }
        onOpen(item)
    }

    @objc private func togglePin(_ sender: NSButton) {
        guard let item = item(at: sender.tag), manager.isEnabled(item) else { return }
        let nowPinned = !manager.isPinned(item)
        manager.setPinned(nowPinned, item: item)
        sender.image = NSImage(systemSymbolName: nowPinned ? "pin.fill" : "pin",
                               accessibilityDescription: nowPinned ? String(localized: "Unpin from Toolbar")
                                                                  : String(localized: "Pin to Toolbar"))
        sender.contentTintColor = nowPinned ? .controlAccentColor : .secondaryLabelColor
        onPinToggled?()
    }

    @objc private func showExtensionMenu(_ sender: NSButton) {
        guard let item = item(at: sender.tag) else { return }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: manager.isEnabled(item) ? String(localized: "Disable") : String(localized: "Enable"),
                                action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.tag = sender.tag
        menu.addItem(toggle)
        if manager.isEnabled(item), manager.context(for: item)?.optionsPageURL != nil {
            let options = NSMenuItem(title: String(localized: "Extension Settings…"),
                                     action: #selector(openOptions(_:)), keyEquivalent: "")
            options.target = self
            options.tag = sender.tag
            menu.addItem(options)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let item = item(at: sender.tag) else { return }
        let wrapper = NSMenuItem()
        wrapper.representedObject = InstalledExtensionBox(item)
        (NSApp.delegate as? AppDelegate)?.toggleExtensionAction(wrapper)
    }

    @objc private func openOptions(_ sender: NSMenuItem) {
        guard let item = item(at: sender.tag) else { return }
        let wrapper = NSMenuItem()
        wrapper.representedObject = InstalledExtensionBox(item)
        (NSApp.delegate as? AppDelegate)?.extensionOptionsAction(wrapper)
    }

    @objc private func manageExtensions(_ sender: Any?) { onManage() }

    @objc private func closePopover(_ sender: Any?) { view.window?.performClose(nil) }
}
