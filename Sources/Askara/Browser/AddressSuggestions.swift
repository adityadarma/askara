import AppKit
import AskaraCore

/// Borderless panel that never becomes key, so the keyboard stays in the address bar.
private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSBezierPath {
    /// Rounded rect with separate top and bottom radii. Views here are not flipped, so top is maxY.
    static func rect(_ r: NSRect, topRadius: CGFloat, bottomRadius: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + bottomRadius, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - bottomRadius, y: r.minY))
        if bottomRadius > 0 {
            p.appendArc(withCenter: NSPoint(x: r.maxX - bottomRadius, y: r.minY + bottomRadius),
                        radius: bottomRadius, startAngle: 270, endAngle: 360)
        }
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - topRadius))
        if topRadius > 0 {
            p.appendArc(withCenter: NSPoint(x: r.maxX - topRadius, y: r.maxY - topRadius),
                        radius: topRadius, startAngle: 0, endAngle: 90)
        }
        p.line(to: NSPoint(x: r.minX + topRadius, y: r.maxY))
        if topRadius > 0 {
            p.appendArc(withCenter: NSPoint(x: r.minX + topRadius, y: r.maxY - topRadius),
                        radius: topRadius, startAngle: 90, endAngle: 180)
        }
        p.line(to: NSPoint(x: r.minX, y: r.minY + bottomRadius))
        if bottomRadius > 0 {
            p.appendArc(withCenter: NSPoint(x: r.minX + bottomRadius, y: r.minY + bottomRadius),
                        radius: bottomRadius, startAngle: 180, endAngle: 270)
        }
        p.close()
        return p
    }
}

/// Panel background that continues the address bar: same fill and border, open at the top so the
/// two read as one shape.
private final class SuggestionBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath.rect(bounds, topRadius: 0, bottomRadius: 10).fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let border = NSBezierPath.rect(bounds.insetBy(dx: 0.5, dy: 0.5), topRadius: 0, bottomRadius: 9.5)
        border.lineWidth = 1
        border.stroke()
        // Erase the top border line so the seam with the address bar disappears.
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 1, y: bounds.height - 1, width: bounds.width - 2, height: 1).fill()
    }
}

/// Dropdown under the address bar showing matching history and bookmarks.
/// Built only once per window and hidden when not in use, so it costs nothing while browsing.
@MainActor
final class AddressSuggestionsController {
    private static let rowHeight: CGFloat = 30
    private static let padding: CGFloat = 5

    var onChoose: ((AddressSuggestion) -> Void)?
    /// Called with true when the list opens and false when it closes, so the address bar can
    /// square its bottom corners and join the list.
    var onVisibilityChange: ((Bool) -> Void)?
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
        // No window shadow: it would spill onto the address bar and break the joined look.
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true

        let background = SuggestionBackgroundView()
        background.addSubview(list)
        background.setAccessibilityRole(.list)
        background.setAccessibilityLabel(String(localized: "Suggestions"))
        background.setAccessibilityIdentifier("askara.address.suggestions")
        panel.contentView = background
    }

    /// `field` is the whole address bar; the list is flush against its bottom edge and as wide as it.
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
        let frame = NSRect(x: fieldRect.minX, y: fieldRect.minY - height, width: fieldRect.width, height: height)
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
        onVisibilityChange?(true)
    }

    /// Drops the highlighted row but keeps the list on screen, so typing doesn't flicker the panel
    /// while the next results are ranked. Enter then submits the typed text, not a stale row.
    func clearSelection() {
        selectedIndex = -1
        for row in rows { row.isSelected = false }
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        selectedIndex = -1
        onVisibilityChange?(false)
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

/// Placeholder icon for sites without a favicon yet: first letter of the host on a muted color
/// that is the same every launch for the same host (like Arc and Vivaldi), instead of a generic glyph.
@MainActor
enum SiteMonogram {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func image(for url: URL) -> NSImage {
        let host = AddressSuggester.stripPrefixes(url.host?.lowercased() ?? url.absoluteString.lowercased())
        let key = host as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let letter = host.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
        // Stable hash: Swift's hashValue changes on every launch.
        var hash: UInt32 = 5381
        for byte in host.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        let hue = CGFloat(hash % 360) / 360
        let fill = NSColor(hue: hue, saturation: 0.42, brightness: 0.66, alpha: 1)

        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2,
                                                  y: (rect.height - size.height) / 2),
                                      withAttributes: attributes)
            return true
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// One suggestion: favicon, page title, and address.
final class SuggestionRowView: NSView {
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

    var titleWidthForTesting: CGFloat { titleLabel.frame.width }
    /// Width the title needs to draw without truncating, padding included.
    var titleTextWidthForTesting: CGFloat { ceil(Self.fittingWidth(of: titleLabel)) }

    private static func fittingWidth(of label: NSTextField) -> CGFloat {
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1000)
        if let cell = label.cell {
            // A fresh cell measures the current string only, never the field's previous frame.
            return cell.cellSize(forBounds: unbounded).width
        }
        let font = label.font ?? NSFont.systemFont(ofSize: 13)
        return (label.stringValue as NSString).size(withAttributes: [.font: font]).width + 4
    }

    private static let magnifier: NSImage? = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))

    func configure(_ suggestion: AddressSuggestion) {
        if suggestion.kind == .search {
            let subtitle = suggestion.subtitle ?? ""
            titleLabel.stringValue = suggestion.title
            addressLabel.stringValue = subtitle
            // The search engine's own favicon when known (the "G" for Google); otherwise a thin magnifier.
            icon.image = FaviconStore.shared.icon(for: suggestion.url) ?? Self.magnifier
            setAccessibilityLabel(subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(subtitle)")
            needsLayout = true
            return
        }
        let address = Self.displayAddress(suggestion.url)
        let title = suggestion.title.isEmpty ? address : suggestion.title
        titleLabel.stringValue = title
        addressLabel.stringValue = suggestion.title.isEmpty ? "" : address
        icon.image = FaviconStore.shared.icon(for: suggestion.url) ?? SiteMonogram.image(for: suggestion.url)
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
        // A truncating NSTextField can report its previous frame as its intrinsic width. Measure
        // the actual string so short titles never become "S…" or "Goo…" after row reuse.
        // The cell size includes the cell's internal padding; the raw string width alone is a few
        // points short, which truncated very short titles.
        let measuredTitle = ceil(Self.fittingWidth(of: titleLabel))
        let maximumTitle = addressLabel.stringValue.isEmpty ? available : min(420, max(100, available * 0.5))
        let titleWidth = min(measuredTitle, maximumTitle)
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
