import AppKit

/// Draggable line between the two pages of Split View. Double-click puts it back in the middle.
final class SplitDividerView: NSView {
    /// Wider than the drawn line so it's easy to grab.
    static let hitWidth: CGFloat = 7

    /// Pointer position along the superview's x axis while dragging.
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(localized: "Split View divider"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: ((bounds.width - 1) / 2).rounded(.down), y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
}
