import AppKit
import AskaraCore

/// Menus, bar, and editor for bookmark folders. Shared by the bookmarks bar, the Bookmarks menu,
/// and the star button.
@MainActor
enum BookmarkMenus {
    static var barTitle: String { String(localized: "Bookmarks Bar") }
    static var otherTitle: String { String(localized: "Other Bookmarks") }

    static let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: String(localized: "Folder"))

    /// Fills `menu` with a container's contents; folders become submenus.
    /// Each bookmark item carries its URL in `representedObject` and calls `action` on `target`.
    static func fill(_ menu: NSMenu, nodes: [BookmarkNode], target: AnyObject, action: Selector,
                     openAll: Selector? = nil) {
        for node in nodes {
            menu.addItem(item(for: node, target: target, action: action, openAll: openAll))
        }
        if let openAll, nodes.contains(where: { !$0.isFolder }) {
            menu.addItem(.separator())
            let all = NSMenuItem(title: String(localized: "Open All in Tabs"), action: openAll, keyEquivalent: "")
            all.target = target
            all.representedObject = nodes.compactMap(\.url)
            menu.addItem(all)
        }
        if nodes.isEmpty {
            let empty = NSMenuItem(title: String(localized: "(Empty)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    static func item(for node: BookmarkNode, target: AnyObject, action: Selector, openAll: Selector?) -> NSMenuItem {
        let title = short(node.title)
        guard node.isFolder else {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = node.url
            item.toolTip = node.url?.absoluteString
            item.image = favicon(for: node.url)
            return item
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = folderIcon
        let submenu = NSMenu(title: node.title)
        fill(submenu, nodes: node.children ?? [], target: target, action: action, openAll: openAll)
        item.submenu = submenu
        return item
    }

    static func favicon(for url: URL?) -> NSImage? {
        let image = FaviconStore.shared.icon(for: url) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    static func short(_ title: String, max: Int = 60) -> String {
        title.count > max ? String(title.prefix(max - 3)) + "…" : title
    }

    /// Folder picker entries: indented names, each item's `representedObject` a `ContainerBox`.
    static func fillFolderPopup(_ popup: NSPopUpButton, store: BookmarkStore, selected: BookmarkContainer,
                                excluding excluded: UUID? = nil) {
        popup.removeAllItems()
        var skipDepth: Int?
        for entry in store.containers() {
            // Hide a folder being moved and everything inside it.
            if let depth = skipDepth, entry.depth > depth { continue }
            skipDepth = nil
            if case .folder(let id) = entry.container, id == excluded { skipDepth = entry.depth; continue }
            let name: String
            switch entry.container {
            case .bar: name = barTitle
            case .other: name = otherTitle
            case .folder: name = entry.title ?? ""
            }
            popup.addItem(withTitle: name)
            let item = popup.lastItem
            item?.indentationLevel = entry.depth
            item?.image = entry.container == .bar ? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
                : entry.container == .other ? NSImage(systemSymbolName: "tray", accessibilityDescription: nil) : folderIcon
            item?.representedObject = ContainerBox(entry.container)
            if entry.container == selected { popup.select(item) }
        }
    }

    final class ContainerBox: NSObject {
        let value: BookmarkContainer
        init(_ value: BookmarkContainer) { self.value = value }
    }
}

// MARK: - Editor

/// Edit a bookmark (name, address, folder) or a folder (name, parent). Used by the bar,
/// the Library, and the star popover.
@MainActor
enum BookmarkEditor {
    /// Opens a sheet for a node. `onDone` runs after saving.
    static func edit(_ id: UUID, profile: ProfileData, in window: NSWindow, onDone: (() -> Void)? = nil) {
        guard let node = profile.bookmarks.node(id),
              let location = profile.bookmarks.location(of: id) else { return }
        let alert = NSAlert()
        alert.messageText = node.isFolder ? String(localized: "Edit Folder") : String(localized: "Edit Bookmark")
        let name = NSTextField(string: node.title)
        name.setAccessibilityLabel(String(localized: "Name"))
        let address = NSTextField(string: node.url?.absoluteString ?? "")
        address.setAccessibilityLabel(String(localized: "Address"))
        let folder = NSPopUpButton()
        folder.setAccessibilityLabel(String(localized: "Folder"))
        BookmarkMenus.fillFolderPopup(folder, store: profile.bookmarks, selected: location.container,
                                      excluding: node.isFolder ? id : nil)
        var rows: [[NSView]] = [[NSTextField(labelWithString: String(localized: "Name:")), name]]
        if !node.isFolder { rows.append([NSTextField(labelWithString: String(localized: "Address:")), address]) }
        rows.append([NSTextField(labelWithString: String(localized: "Folder:")), folder])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.column(at: 1).width = 300
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(rows.count) * 32)
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            var failed = false
            profile.editBookmarks { store in
                store.rename(id: id, to: name.stringValue)
                if !node.isFolder {
                    let text = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: text), url.scheme != nil, url != node.url {
                        failed = !store.setURL(id: id, to: url)
                    }
                }
                if let target = (folder.selectedItem?.representedObject as? BookmarkMenus.ContainerBox)?.value,
                   target != location.container {
                    store.move(id: id, to: target)
                }
            }
            if failed {
                let warn = NSAlert()
                warn.messageText = String(localized: "That address is already bookmarked.")
                warn.beginSheetModal(for: window)
            }
            onDone?()
        }
    }

    /// Asks for a name and creates a folder in `container`.
    static func newFolder(in container: BookmarkContainer, profile: ProfileData, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New Folder")
        let name = NSTextField(string: String(localized: "New Folder"))
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        name.setAccessibilityLabel(String(localized: "Folder name"))
        alert.accessoryView = name
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            profile.editBookmarks { $0.addFolder(title: name.stringValue, to: container) }
        }
    }

    /// Deleting a folder with bookmarks in it asks first.
    static func delete(_ id: UUID, profile: ProfileData, window: NSWindow) {
        guard let node = profile.bookmarks.node(id) else { return }
        let count = node.bookmarkCount
        guard node.isFolder, count > 0 else {
            profile.editBookmarks { $0.remove(id: id) }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(node.title)”?")
        alert.informativeText = String(localized: "The folder and the \(count) bookmarks in it will be deleted.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            profile.editBookmarks { $0.remove(id: id) }
        }
    }
}

// MARK: - Star popover

/// Shown after ⌘D / the star, like Chrome: rename, pick a folder, or remove.
@MainActor
final class BookmarkPopover: NSViewController {
    private let profile: ProfileData
    private let id: UUID
    private let name = NSTextField()
    private let folder = NSPopUpButton()
    private weak var popover: NSPopover?

    init(profile: ProfileData, id: UUID) {
        self.profile = profile
        self.id = id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func show(profile: ProfileData, id: UUID, relativeTo view: NSView) {
        let controller = BookmarkPopover(profile: profile, id: id)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(controller.name)
    }

    override func loadView() {
        let node = profile.bookmarks.node(id)
        let title = NSTextField(labelWithString: String(localized: "Bookmark added"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.stringValue = node?.title ?? ""
        name.setAccessibilityLabel(String(localized: "Name"))
        name.widthAnchor.constraint(equalToConstant: 240).isActive = true
        folder.setAccessibilityLabel(String(localized: "Folder"))
        BookmarkMenus.fillFolderPopup(folder, store: profile.bookmarks,
                                      selected: profile.bookmarks.location(of: id)?.container ?? .bar)
        let remove = NSButton(title: String(localized: "Remove"), target: self, action: #selector(removeBookmark(_:)))
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        [remove, done].forEach { $0.bezelStyle = .rounded }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Name:")), name],
            [NSTextField(labelWithString: String(localized: "Folder:")), folder],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let buttons = NSStackView(views: [NSView(), remove, done])
        let stack = NSStackView(views: [title, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = stack
    }

    /// Closing the popover (click outside, Esc) keeps edits too, like Chrome.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        save()
    }

    private func save() {
        guard profile.bookmarks.node(id) != nil else { return }
        let target = (folder.selectedItem?.representedObject as? BookmarkMenus.ContainerBox)?.value
        let current = profile.bookmarks.location(of: id)?.container
        let title = name.stringValue
        guard title != profile.bookmarks.node(id)?.title || (target != nil && target != current) else { return }
        profile.editBookmarks { store in
            store.rename(id: id, to: title)
            if let target, target != current { store.move(id: id, to: target) }
        }
    }

    @objc private func done(_ sender: Any?) { popover?.performClose(sender) }

    @objc private func removeBookmark(_ sender: Any?) {
        profile.editBookmarks { $0.remove(id: id) }
        popover?.performClose(sender)
    }
}

// MARK: - Bar

@MainActor
protocol BookmarkBarDelegate: AnyObject {
    func bookmarkBar(_ bar: BookmarkBarView, open url: URL, newTab: Bool)
    func bookmarkBar(_ bar: BookmarkBarView, openAll urls: [URL])
    var bookmarkBarProfile: ProfileData { get }
}

/// Row of bookmarks under the toolbar. Folders open a menu. Items that don't fit go into a » menu.
/// Drag to reorder, drop a link or tab address to add one, right-click to edit.
final class BookmarkBarView: NSView, NSDraggingSource {
    static let height: CGFloat = 28
    private static let itemType = NSPasteboard.PasteboardType("local.askara.bookmark")

    weak var delegate: BookmarkBarDelegate?
    private var nodes: [BookmarkNode] = []
    private var buttons: [BookmarkBarButton] = []
    private let overflow = NSButton()
    private var dropIndicator: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        overflow.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: String(localized: "More bookmarks"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        overflow.isBordered = false
        overflow.target = self
        overflow.action = #selector(showOverflow(_:))
        overflow.toolTip = String(localized: "More bookmarks")
        overflow.isHidden = true
        addSubview(overflow)
        registerForDraggedTypes([Self.itemType, .URL, TabStripView.tabType])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(BookmarkMenus.barTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        nodes = delegate?.bookmarkBarProfile.bookmarks.bar ?? []
        buttons.forEach { $0.removeFromSuperview() }
        buttons = nodes.enumerated().map { index, node in
            let button = BookmarkBarButton(bar: self, index: index)
            button.title = BookmarkMenus.short(node.title, max: 28)
            button.image = node.isFolder ? BookmarkMenus.folderIcon : BookmarkMenus.favicon(for: node.url)
            button.toolTip = node.isFolder ? node.title : "\(node.title)\n\(node.url?.absoluteString ?? "")"
            button.setAccessibilityLabel(node.isFolder ? String(localized: "\(node.title) folder") : node.title)
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    private var firstHidden = Int.max

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 8
        let limit = bounds.width - 30
        firstHidden = Int.max
        for (index, button) in buttons.enumerated() {
            let width = min(180, button.intrinsicContentSize.width + 8)
            if x + width > limit, firstHidden == Int.max { firstHidden = index }
            button.isHidden = index >= firstHidden
            button.frame = NSRect(x: x, y: 2, width: width, height: h - 4)
            x += width + 2
        }
        overflow.isHidden = firstHidden == Int.max
        overflow.frame = NSRect(x: bounds.width - 28, y: 2, width: 24, height: h - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for button in buttons where !button.isHidden {
            NSRect(x: button.frame.maxX + 1, y: 6, width: 1, height: bounds.height - 12).fill()
        }
        if let x = dropIndicator {
            NSColor.controlAccentColor.setFill()
            NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8).fill()
        }
    }

    // MARK: Clicks

    fileprivate func clicked(_ index: Int, button: NSButton) {
        guard nodes.indices.contains(index) else { return }
        let node = nodes[index]
        if node.isFolder {
            let menu = NSMenu()
            BookmarkMenus.fill(menu, nodes: node.children ?? [], target: self, action: #selector(openMenuItem(_:)),
                               openAll: #selector(openAllItem(_:)))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: button)
        } else if let url = node.url {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            delegate?.bookmarkBar(self, open: url, newTab: flags.contains(.command))
        }
    }

    fileprivate func middleClicked(_ index: Int) {
        guard nodes.indices.contains(index), let url = nodes[index].url else { return }
        delegate?.bookmarkBar(self, open: url, newTab: true)
    }

    @objc private func showOverflow(_ sender: NSButton) {
        guard firstHidden < nodes.count else { return }
        let menu = NSMenu()
        BookmarkMenus.fill(menu, nodes: Array(nodes[firstHidden...]), target: self, action: #selector(openMenuItem(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    @objc private func openMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.bookmarkBar(self, open: url, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    @objc private func openAllItem(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        delegate?.bookmarkBar(self, openAll: urls)
    }

    // MARK: Right-click

    fileprivate func contextMenu(for index: Int?) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ object: Any?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }
        if let index, nodes.indices.contains(index) {
            let node = nodes[index]
            if let url = node.url {
                add(String(localized: "Open in New Tab"), #selector(openInNewTab(_:)), url)
                menu.addItem(.separator())
            } else if !(node.children ?? []).isEmpty {
                add(String(localized: "Open All in Tabs"), #selector(openAllItem(_:)), node.children?.compactMap(\.url))
                menu.addItem(.separator())
            }
            add(String(localized: "Edit…"), #selector(editNode(_:)), node.id)
            add(String(localized: "Delete"), #selector(deleteNode(_:)), node.id)
            menu.addItem(.separator())
        }
        add(String(localized: "New Folder…"), #selector(newFolder(_:)), nil)
        add(String(localized: "Show All Bookmarks"), #selector(AppDelegate.showBookmarksAction(_:)), nil)
        menu.items.last?.target = NSApp.delegate
        add(String(localized: "Hide Bookmarks Bar"), #selector(BrowserWindowController.toggleBookmarksBarAction(_:)), nil)
        menu.items.last?.target = nil
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu(for: nil) }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.bookmarkBar(self, open: url, newTab: true)
    }

    @objc private func editNode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = delegate?.bookmarkBarProfile, let window else { return }
        BookmarkEditor.edit(id, profile: profile, in: window)
    }

    @objc private func deleteNode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = delegate?.bookmarkBarProfile, let window else { return }
        BookmarkEditor.delete(id, profile: profile, window: window)
    }

    @objc private func newFolder(_ sender: Any?) {
        guard let profile = delegate?.bookmarkBarProfile, let window else { return }
        BookmarkEditor.newFolder(in: .bar, profile: profile, window: window)
    }

    // MARK: Dragging

    fileprivate func beginDrag(_ index: Int, button: NSButton, event: NSEvent) {
        guard nodes.indices.contains(index) else { return }
        let item = NSPasteboardItem()
        item.setString(nodes[index].id.uuidString, forType: Self.itemType)
        if let url = nodes[index].url { item.setString(url.absoluteString, forType: .URL) }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: button.bounds.size)
        if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(button.frame, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    /// Drop position among bar items and, when over the middle of a folder, that folder.
    private func dropTarget(_ info: NSDraggingInfo) -> (index: Int, folder: UUID?, x: CGFloat) {
        let x = convert(info.draggingLocation, from: nil).x
        let visible = buttons.enumerated().filter { !$0.element.isHidden }
        for (index, button) in visible {
            let f = button.frame
            if nodes[index].isFolder, x > f.minX + f.width * 0.25, x < f.maxX - f.width * 0.25 {
                return (index, nodes[index].id, f.midX)
            }
            if x < f.midX { return (index, nil, f.minX - 1) }
        }
        let end = visible.last?.element.frame.maxX ?? 8
        return (visible.count, nil, end + 1)
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let valid = pasteboard.string(forType: Self.itemType) != nil || draggedURL(pasteboard) != nil
        guard valid, delegate != nil else { dropIndicator = nil; needsDisplay = true; return [] }
        dropIndicator = dropTarget(info).x
        needsDisplay = true
        return pasteboard.string(forType: Self.itemType) != nil ? .move : .copy
    }

    /// A link, or a tab dragged from the tab strip.
    private func draggedURL(_ pasteboard: NSPasteboard) -> (url: URL, title: String)? {
        if let id = pasteboard.string(forType: TabStripView.tabType).flatMap(UUID.init(uuidString:)),
           let tab = BrowserServices.shared.windows.lazy.flatMap(\.allTabs).first(where: { $0.id == id }),
           let url = tab.webView?.url ?? tab.url, HistoryStore.isRecordable(url) {
            return (url, tab.title)
        }
        guard let url = NSURL(from: pasteboard) as URL?, HistoryStore.isRecordable(url) else { return nil }
        let title = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? ""
        return (url, title)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndicator = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator = nil
        needsDisplay = true
        guard let profile = delegate?.bookmarkBarProfile else { return false }
        let target = dropTarget(sender)
        let container: BookmarkContainer = target.folder.map { .folder($0) } ?? .bar
        let index = target.folder == nil ? target.index : nil
        let pasteboard = sender.draggingPasteboard
        if let id = pasteboard.string(forType: Self.itemType).flatMap(UUID.init(uuidString:)) {
            return profile.editBookmarks { $0.move(id: id, to: container, at: index) }
        }
        guard let (url, title) = draggedURL(pasteboard) else { return false }
        if let existing = profile.bookmarks.node(for: url) {
            // Already bookmarked elsewhere: move it here.
            return profile.editBookmarks { $0.move(id: existing.id, to: container, at: index) }
        }
        return profile.editBookmarks { $0.add(url: url, title: title, to: container, at: index) } != nil
    }
}

/// One bar item. Click opens, drag starts a move, right-click edits.
final class BookmarkBarButton: NSButton {
    private weak var bar: BookmarkBarView?
    let index: Int

    init(bar: BookmarkBarView, index: Int) {
        self.bar = bar
        self.index = index
        super.init(frame: .zero)
        bezelStyle = .recessed
        isBordered = false
        showsBorderOnlyWhileMouseInside = true
        font = .systemFont(ofSize: 12)
        imagePosition = .imageLeading
        imageHugsTitle = true
        lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(click(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func click(_ sender: Any?) { bar?.clicked(index, button: self) }

    override func mouseDown(with event: NSEvent) {
        // Moving the mouse past a few points starts a drag; otherwise it's a normal click.
        guard let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                bar?.clicked(index, button: self)
                return
            }
            let p = next.locationInWindow
            if abs(p.x - start.x) > 4 || abs(p.y - start.y) > 4 {
                bar?.beginDrag(index, button: self, event: event)
                return
            }
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.middleClicked(index) } else { super.otherMouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar?.contextMenu(for: index) }
}
