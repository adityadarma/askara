import AppKit
import AskaraCore

/// Borderless panel that never becomes key, so the keyboard stays in the address bar.
private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Dropdown under the address bar showing matching history and bookmarks.
/// Built only once per window and hidden when not in use, so it costs nothing while browsing.
@MainActor
final class AddressSuggestionsController {
    private static let rowHeight: CGFloat = 30
    private static let padding: CGFloat = 5

    var onChoose: ((AddressSuggestion) -> Void)?
    private(set) var items: [AddressSuggestion] = []
    /// -1 means nothing is selected (the text the user typed).
    private(set) var selectedIndex = -1

    private let panel = SuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: true)
    private let list = NSView()
    private var rows: [SuggestionRowView] = []

    var isVisible: Bool { panel.isVisible }
    var selected: AddressSuggestion? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    init() {
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.addSubview(list)
        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(String(localized: "Suggestions"))
        background.setAccessibilityIdentifier("askara.address.suggestions")
        panel.contentView = background
    }

    func show(_ suggestions: [AddressSuggestion], below field: NSView) {
        guard !suggestions.isEmpty, let parent = field.window else { return hide() }
        items = suggestions
        selectedIndex = -1

        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        while rows.count < items.count {
            let row = SuggestionRowView()
            let index = rows.count
            row.onClick = { [weak self] in
                guard let self, self.items.indices.contains(index) else { return }
                self.onChoose?(self.items[index])
            }
            list.addSubview(row)
            rows.append(row)
        }

        let fieldRect = parent.convertToScreen(field.convert(field.bounds, to: nil))
        let height = CGFloat(items.count) * Self.rowHeight + Self.padding * 2
        let frame = NSRect(x: fieldRect.minX, y: fieldRect.minY - 4 - height, width: fieldRect.width, height: height)
        panel.setFrame(frame, display: false)
        list.frame = NSRect(x: Self.padding, y: Self.padding, width: frame.width - Self.padding * 2,
                            height: height - Self.padding * 2)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: list.bounds.height - CGFloat(index + 1) * Self.rowHeight,
                               width: list.bounds.width, height: Self.rowHeight)
            row.setAccessibilityIdentifier("askara.address.suggestion.\(index)")
            row.configure(items[index])
            row.isSelected = false
        }

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        selectedIndex = -1
    }

    /// Arrow keys: cycles typed text → first … last → typed text. Returns the new selection.
    @discardableResult
    func moveSelection(by delta: Int) -> AddressSuggestion? {
        guard !items.isEmpty else { return nil }
        var next = selectedIndex + delta
        if next < -1 { next = items.count - 1 } else if next >= items.count { next = -1 }
        selectedIndex = next
        for (index, row) in rows.enumerated() { row.isSelected = index == next }
        return selected
    }
}

/// One suggestion: favicon, page title, and address.
private final class SuggestionRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }
    private var isHovered = false { didSet { needsDisplay = true } }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        for label in [titleLabel, addressLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
        }
        titleLabel.font = .systemFont(ofSize: 13)
        addressLabel.font = .systemFont(ofSize: 12)
        [icon, titleLabel, addressLabel].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ suggestion: AddressSuggestion) {
        let address = Self.displayAddress(suggestion.url)
        let title = suggestion.title.isEmpty ? address : suggestion.title
        titleLabel.stringValue = title
        addressLabel.stringValue = suggestion.title.isEmpty ? "" : address
        let fallback = suggestion.kind == .bookmark ? "star" : "clock"
        icon.image = FaviconStore.shared.icon(for: suggestion.url)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
        setAccessibilityLabel(suggestion.title.isEmpty ? address : "\(title), \(address)")
        needsLayout = true
    }

    /// Address without "https://", "www." and trailing slash, as Safari shows it.
    private static func displayAddress(_ url: URL) -> String {
        var text = AddressSuggester.stripPrefixes(url.absoluteString)
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        let x: CGFloat = 32
        let available = max(0, bounds.width - x - 10)
        let titleHeight = titleLabel.intrinsicContentSize.height
        // Title takes what it needs up to 60%; the address fills the rest.
        let titleWidth = min(titleLabel.intrinsicContentSize.width, addressLabel.stringValue.isEmpty
                             ? available : available * 0.6)
        titleLabel.frame = NSRect(x: x, y: (h - titleHeight) / 2, width: titleWidth, height: titleHeight)
        let addressX = x + titleWidth + 10
        let addressHeight = addressLabel.intrinsicContentSize.height
        addressLabel.frame = NSRect(x: addressX, y: (h - addressHeight) / 2,
                                    width: max(0, bounds.width - addressX - 10), height: addressHeight)
    }

    private func updateAppearance() {
        titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        addressLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        icon.contentTintColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        setAccessibilitySelected(isSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor? = isSelected ? .selectedContentBackgroundColor
            : (isHovered ? NSColor.labelColor.withAlphaComponent(0.08) : nil)
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    // The panel is never key, so the first click must already count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
