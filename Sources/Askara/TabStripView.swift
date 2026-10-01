import AppKit

enum AskaraColors {
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// Tab strip background (darker), like Chrome.
    static let strip = dynamic(dark: NSColor(white: 0.10, alpha: 1), light: NSColor(white: 0.86, alpha: 1))
    static let privateStrip = NSColor(srgbRed: 0.15, green: 0.11, blue: 0.24, alpha: 1)
    /// Active tab and toolbar share one color so they blend.
    static let toolbar = dynamic(dark: NSColor(white: 0.20, alpha: 1), light: NSColor(white: 0.98, alpha: 1))
    static let privateToolbar = NSColor(srgbRed: 0.23, green: 0.18, blue: 0.33, alpha: 1)
    static let hover = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.06))
}

/// Solid-color view with a thin bottom border.
final class FillView: NSView {
    var color: NSColor = AskaraColors.toolbar { didSet { needsDisplay = true } }
    var drawsBottomBorder = true
    /// Double-click on empty space zooms/minimizes the window, like the titlebar (toolbar row).
    var zoomsOnDoubleClick = false

    override func mouseUp(with event: NSEvent) {
        if zoomsOnDoubleClick, event.clickCount == 2 { TabStripView.titlebarDoubleClick(window) }
        else { super.mouseUp(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        if drawsBottomBorder {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }
}

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelect index: Int)
    func tabStrip(_ strip: TabStripView, didClose index: Int)
    func tabStripNewTab(_ strip: TabStripView)
    /// Called when the cursor rests on a tab; computed on demand to avoid polling.
    func tabStrip(_ strip: TabStripView, tooltipFor index: Int) -> String
    /// Right-click menu for a tab.
    func tabStrip(_ strip: TabStripView, menuFor index: Int) -> NSMenu?
    /// Click on the speaker icon.
    func tabStrip(_ strip: TabStripView, toggleMuteAt index: Int)
    /// Drag within the strip: move a tab (pinned tabs stay among pinned tabs).
    func tabStrip(_ strip: TabStripView, moveTabFrom from: Int, to: Int)
    /// Identifier put on the pasteboard when a tab is dragged out of the strip. nil = can't leave.
    func tabStrip(_ strip: TabStripView, dragIDForTabAt index: Int) -> String?
    /// Whether a tab dragged from any window may be dropped on this strip.
    func tabStrip(_ strip: TabStripView, canAcceptTab id: String) -> Bool
    func tabStrip(_ strip: TabStripView, acceptTab id: String, at index: Int) -> Bool
    /// Dropped outside every tab strip: open it in a new window near `screenPoint` (top-left).
    func tabStrip(_ strip: TabStripView, detachTab id: String, to screenPoint: NSPoint)
}

struct TabStripItem: Equatable {
    var title: String
    var isSleeping: Bool
    var isPlayingAudio: Bool
    var isLoading = false
    var favicon: NSImage? = nil
    var isPinned = false
    var isMuted = false
}

/// Thin progress line under the toolbar (like Safari). Advances with `estimatedProgress`,
/// then fills and fades out when the page finishes loading.
final class LoadingBar: NSView {
    private let fill = CALayer()
    private var fraction: Double = 0
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(String(localized: "Loading page"))
        setAccessibilityIdentifier("askara.page.loading")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `animated: false` is used when switching tabs so the bar shows the new tab's state immediately.
    func update(loading: Bool, progress: Double, animated: Bool = true) {
        if loading {
            hideWork?.cancel()
            hideWork = nil
            if isHidden {
                isHidden = false
                alphaValue = 1
                setFraction(0, animated: false)
            }
            // Start at 10% so the bar is visible as soon as navigation begins.
            setFraction(max(0.1, progress), animated: animated)
        } else if !isHidden, hideWork == nil {
            guard animated else { isHidden = true; return }
            setFraction(1, animated: true)
            let work = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    self?.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard let self, self.hideWork != nil else { return }
                        self.isHidden = true
                        self.hideWork = nil
                    }
                })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func setFraction(_ value: Double, animated: Bool) {
        // Progress never goes backward within one navigation (except reset to 0).
        fraction = value == 0 ? 0 : max(fraction, value)
        setAccessibilityValue(Int(fraction * 100))
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    // Clicks pass through to the view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Tab strip in the titlebar area, next to the window buttons (red/yellow/green).
/// Pinned tabs (icon only) come first, then normal tabs.
final class TabStripView: NSView, NSDraggingSource {
    static let height: CGFloat = 40
    static let tabType = NSPasteboard.PasteboardType("local.askara.tab")
    private static let topGap: CGFloat = 6
    static let pinnedWidth: CGFloat = 42

    weak var delegate: TabStripDelegate?
    var isPrivate = false {
        didSet {
            privateBadge.isHidden = !isPrivate
            needsDisplay = true
            needsLayout = true
        }
    }

    private var itemViews: [TabItemView] = []
    private var items: [TabStripItem] = []
    private var activeIndex = -1
    private let newTabButton = NSButton()
    private let privateBadge = NSTextField(labelWithString: String(localized: "Private"))

    override init(frame: NSRect) {
        super.init(frame: frame)
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "New tab"))
        newTabButton.isBordered = false
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked(_:))
        newTabButton.toolTip = String(localized: "New tab (⌘T)")
        newTabButton.setAccessibilityLabel(String(localized: "New tab"))
        newTabButton.setAccessibilityIdentifier("askara.tabs.new")
        addSubview(newTabButton)

        privateBadge.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        privateBadge.textColor = .systemPurple
        privateBadge.isHidden = true
        addSubview(privateBadge)

        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(String(localized: "Tabs"))
        setAccessibilityIdentifier("askara.tabs")
        registerForDraggedTypes([Self.tabType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(items: [TabStripItem], activeIndex: Int) {
        let previousItems = self.items
        let previousActiveIndex = self.activeIndex
        self.items = items
        self.activeIndex = activeIndex
        while itemViews.count > items.count { itemViews.removeLast().removeFromSuperview() }
        while itemViews.count < items.count {
            let view = TabItemView(strip: self)
            addSubview(view, positioned: .below, relativeTo: newTabButton)
            itemViews.append(view)
        }
        for (index, item) in items.enumerated() {
            let itemChanged = !previousItems.indices.contains(index) || previousItems[index] != item
            let activeChanged = previousActiveIndex != activeIndex &&
                (index == previousActiveIndex || index == activeIndex)
            guard itemChanged || activeChanged else { continue }
            itemViews[index].configure(index: index, item: item, isActive: index == activeIndex)
        }
        if previousItems != items || previousActiveIndex != activeIndex { needsLayout = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        // Window buttons disappear in full screen, so tabs can start at the left edge.
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: name, object: window)
        }
    }

    @objc private func relayout() { needsLayout = true }

    override func layout() {
        super.layout()
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        let leading: CGFloat = fullScreen ? 8 : 78
        let badgeWidth: CGFloat = isPrivate ? privateBadge.intrinsicContentSize.width + 12 : 0
        let buttonSize: CGFloat = 28
        let tabHeight = bounds.height - Self.topGap

        let pinnedCount = CGFloat(items.filter(\.isPinned).count)
        let normalCount = items.count - Int(pinnedCount)
        let available = bounds.width - leading - badgeWidth - buttonSize - 16 - pinnedCount * Self.pinnedWidth
        let width = floor(max(28, min(240, available / CGFloat(max(normalCount, 1)))))

        var x = leading
        for (index, view) in itemViews.enumerated() {
            let w = items[index].isPinned ? Self.pinnedWidth : width
            view.frame = NSRect(x: x, y: 0, width: w, height: tabHeight)
            x += w
        }
        newTabButton.frame = NSRect(x: x + 6, y: (tabHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
        let badgeSize = privateBadge.intrinsicContentSize
        privateBadge.frame = NSRect(x: bounds.width - badgeSize.width - 10, y: (tabHeight - badgeSize.height) / 2,
                                    width: badgeSize.width, height: badgeSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isPrivate ? AskaraColors.privateStrip : AskaraColors.strip).setFill()
        bounds.fill()
    }

    var activeTabColor: NSColor { isPrivate ? AskaraColors.privateToolbar : AskaraColors.toolbar }

    // Empty tab strip area acts like a titlebar: drag to move, double-click to zoom.
    // The second click is handled on mouse-up: after the first click's performDrag the window
    // server may swallow the second mouse-down's follow-up events.
    override func mouseDown(with event: NSEvent) {
        guard let window, event.clickCount == 1 else { return }
        window.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { Self.titlebarDoubleClick(window) }
    }

    /// Follows System Settings > Desktop & Dock > "Double-click a window's title bar to".
    static func titlebarDoubleClick(_ window: NSWindow?) {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil) // "Maximize"/"Fill": toggles between full size and the previous size
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The strip lies in the titlebar area. Without this, the window server treats it as titlebar
    /// and moves the window on any drag, so tabs could never be dragged. AppKit asks titlebar views
    /// for this rect (the same override Chromium uses); moving the window from empty space is done
    /// in `mouseDown` instead.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

    @objc private func newTabClicked(_ sender: Any?) { delegate?.tabStripNewTab(self) }

    // MARK: - Dragging tabs

    /// Index a tab would take if dropped at `x` (among all tabs; the delegate keeps pinned tabs first).
    private func dropIndex(atX x: CGFloat, excluding skipped: Int? = nil) -> Int {
        itemViews.enumerated().filter { $0.offset != skipped && $0.element.frame.midX < x }.count
    }

    /// Follows the mouse after a click on a tab: reorders live while the pointer stays near the strip,
    /// and turns into a drag session (to another window, or out to a new one) once it leaves.
    fileprivate func trackDrag(from startIndex: Int, event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        var current = startIndex
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let point = next.locationInWindow
            if !moved, abs(point.x - start.x) < 5, abs(point.y - start.y) < 5 { continue }
            if !moved { Log.notice("tab drag started (tab \(startIndex))") }
            moved = true
            let local = convert(point, from: nil)
            if local.y < -30 || local.y > bounds.height + 30 || !bounds.insetBy(dx: -30, dy: 0).contains(NSPoint(x: local.x, y: bounds.midY)) {
                beginDragSession(index: current, event: next)
                return
            }
            let pinned = items[current].isPinned
            let pinnedCount = items.filter(\.isPinned).count
            let range = pinned ? 0...max(0, pinnedCount - 1) : pinnedCount...max(pinnedCount, items.count - 1)
            let target = min(max(dropIndex(atX: local.x, excluding: current), range.lowerBound), range.upperBound)
            guard target != current else { continue }
            delegate?.tabStrip(self, moveTabFrom: current, to: target)
            current = target
            layoutSubtreeIfNeeded()
        }
    }

    private func beginDragSession(index: Int, event: NSEvent) {
        guard itemViews.indices.contains(index), let id = delegate?.tabStrip(self, dragIDForTabAt: index) else { return }
        let view = itemViews[index]
        let item = NSPasteboardItem()
        item.setString(id, forType: Self.tabType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(view.frame, contents: image)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // No tab strip took it: it becomes its own window where it was dropped.
        guard operation.isEmpty,
              let id = session.draggingPasteboard.string(forType: Self.tabType) else { return }
        delegate?.tabStrip(self, detachTab: id, to: screenPoint)
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let id = info.draggingPasteboard.string(forType: Self.tabType),
              delegate?.tabStrip(self, canAcceptTab: id) == true else { return [] }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = sender.draggingPasteboard.string(forType: Self.tabType) else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        return delegate?.tabStrip(self, acceptTab: id, at: dropIndex(atX: x)) ?? false
    }

    fileprivate func select(_ index: Int) { delegate?.tabStrip(self, didSelect: index) }
    fileprivate func close(_ index: Int) { delegate?.tabStrip(self, didClose: index) }
    fileprivate func tooltip(_ index: Int) -> String { delegate?.tabStrip(self, tooltipFor: index) ?? "" }
    fileprivate func menu(_ index: Int) -> NSMenu? { delegate?.tabStrip(self, menuFor: index) }
    fileprivate func toggleMute(_ index: Int) { delegate?.tabStrip(self, toggleMuteAt: index) }
}

/// A single tab: icon, title, close button. Hovering shows a tooltip with memory usage.
/// Pinned tabs show only the icon and have no close button (⌘W still closes them).
final class TabItemView: NSView, NSViewToolTipOwner {
    private weak var strip: TabStripView?
    private var index = 0
    private var isActive = false
    private var isPinned = false
    private var hasAudioIcon = false
    private var isHovered = false { didSet { updateCloseVisibility(); needsDisplay = true } }
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var title = ""
    private var isLoading = false
    private(set) var configurationCount = 0

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        // Spinner replaces the icon while the tab loads, like Chrome.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(spinner)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close tab"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = String(localized: "Close tab (⌘W)")
        [icon, label, closeButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(index: Int, item: TabStripItem, isActive: Bool) {
        configurationCount += 1
        self.index = index
        self.isActive = isActive
        self.isPinned = item.isPinned
        title = item.title
        label.stringValue = item.title
        label.textColor = item.isSleeping ? .secondaryLabelColor : .labelColor
        hasAudioIcon = item.isMuted || item.isPlayingAudio
        if item.isMuted {
            icon.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: String(localized: "Muted"))
            icon.alphaValue = 1
        } else if item.isPlayingAudio {
            icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: String(localized: "Playing audio"))
            icon.alphaValue = 1
        } else if let favicon = item.favicon {
            // Site favicon; sleeping tabs are shown dimmed.
            icon.image = favicon
            icon.alphaValue = item.isSleeping ? 0.45 : 1
        } else {
            icon.image = NSImage(systemSymbolName: item.isSleeping ? "moon.zzz" : "globe", accessibilityDescription: nil)
            icon.alphaValue = 1
        }
        if item.isLoading != isLoading {
            isLoading = item.isLoading
            if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        closeButton.setAccessibilityLabel(String(localized: "Close tab \(item.title)"))
        closeButton.setAccessibilityIdentifier("askara.tab.\(index).close")
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("askara.tab.\(index)")
        var state = item.isLoading ? String(localized: ", loading") : (item.isSleeping ? String(localized: ", sleeping") : "")
        if item.isPinned { state += String(localized: ", pinned") }
        if item.isMuted { state += String(localized: ", muted") }
        setAccessibilityLabel(item.title + state)
        setAccessibilityValue(isActive)
        updateCloseVisibility()
        needsLayout = true
        needsDisplay = true
    }

    private func updateCloseVisibility() {
        // Like Chrome: narrow tabs show the close button only on the active tab / on hover.
        closeButton.isHidden = isPinned || !(isActive || isHovered || bounds.width > 110)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        if isPinned {
            icon.isHidden = isLoading
            spinner.isHidden = !isLoading
            icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
            spinner.frame = icon.frame
            label.isHidden = true
        } else {
            label.isHidden = false
            let showIcon = bounds.width > 44 || !isActive
            icon.isHidden = !showIcon || isLoading
            spinner.isHidden = !showIcon || !isLoading
            icon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
            spinner.frame = icon.frame
            let labelX: CGFloat = showIcon ? 34 : 10
            let labelHeight = label.intrinsicContentSize.height
            label.frame = NSRect(x: labelX, y: (h - labelHeight) / 2,
                                 width: max(0, bounds.width - labelX - 30), height: labelHeight)
        }
        closeButton.frame = NSRect(x: bounds.width - 26, y: (h - 18) / 2, width: 18, height: 18)
        updateCloseVisibility()

        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let strip else { return }
        if isActive {
            // Active tab: rounded top corners, blending into the toolbar below.
            strip.activeTabColor.setFill()
            let r: CGFloat = 8
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: bounds.height - r))
            path.appendArc(withCenter: NSPoint(x: r, y: bounds.height - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
            path.line(to: NSPoint(x: bounds.width - r, y: bounds.height))
            path.appendArc(withCenter: NSPoint(x: bounds.width - r, y: bounds.height - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: bounds.width, y: 0))
            path.close()
            path.fill()
        } else if isHovered {
            AskaraColors.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 4), xRadius: 8, yRadius: 8).fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.width - 1, y: 10, width: 1, height: max(0, bounds.height - 20)).fill()
        }
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only remove our own tracking area; tooltips have their own tracking.
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        // Speaker icon toggles mute, like Chrome.
        let point = convert(event.locationInWindow, from: nil)
        if hasAudioIcon, !icon.isHidden, icon.frame.insetBy(dx: -4, dy: -4).contains(point) {
            strip?.toggleMute(index)
            return
        }
        strip?.select(index)
        // Drag to reorder, or out of the strip to move the tab to another window.
        strip?.trackDrag(from: index, event: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

    override func menu(for event: NSEvent) -> NSMenu? { strip?.menu(index) }

    /// Middle-click closes the tab.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.close(index) } else { super.otherMouseUp(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        strip?.select(index)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = strip?.menu(index) else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        return true
    }

    @objc private func closeClicked(_ sender: Any?) { strip?.close(index) }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        let memory = strip?.tooltip(index) ?? ""
        return memory.isEmpty ? title : "\(title)\n\(memory)"
    }
}

/// Short message in the bottom-left corner, replacing a status bar.
final class ToastView: NSVisualEffectView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        isHidden = true
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `duration: nil` = stays visible until `hide()` is called.
    func show(_ text: String, duration: TimeInterval? = 3) {
        hideWork?.cancel()
        label.stringValue = text
        setAccessibilityLabel(text)
        isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        guard let duration else { return }
        let work = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        isHidden = true
    }
}
