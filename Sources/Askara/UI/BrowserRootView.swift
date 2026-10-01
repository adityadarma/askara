import AppKit

/// Window content view. With a full-size content view the tab strip sits under the titlebar, and
/// the window server moves the window on any drag there before the app sees the events, so tabs
/// couldn't be dragged. AppKit asks the content view which part of the titlebar area is "opaque"
/// (not a window-drag area) through this private method, the same one Chromium implements.
/// Empty space in the strip still moves the window: TabStripView.mouseDown calls performDrag.
final class BrowserRootView: NSView {
    weak var tabStrip: TabStripView?

    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect {
        guard let tabStrip, !tabStrip.isHidden else { return .zero }
        return convert(tabStrip.bounds, from: tabStrip)
    }
}
