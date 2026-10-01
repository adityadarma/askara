import AppKit

/// Toolbar button that reacts to the click that also activates the window. A plain NSButton in an
/// inactive window swallows the first click (it only brings the window forward), so the extension
/// popup would need a second click.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
