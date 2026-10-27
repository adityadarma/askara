import CoreGraphics
import Foundation

/// Geometry for keeping the system Picture in Picture window where the user drops it.
/// All coordinates have their origin at the top left of the main display (y grows downward),
/// the same space the Accessibility API and CGEvent use.
public enum PictureInPicturePlacement {
    /// Pointer travel below this is a click on the window's controls, not a drag.
    public static let minimumDrag: CGFloat = 4

    /// The system PiP window is larger than the picture it shows: it keeps a transparent margin
    /// (measured on macOS 26: 24 pt left and right, 4 pt top and bottom) for its shadow. The window may
    /// extend this far past the allowed area so the picture itself can touch the edge.
    public static let transparentMargin = CGSize(width: 24, height: 4)

    public static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= minimumDrag
    }

    /// Where the window's top-left corner goes after a drag: the window keeps the spot the user
    /// grabbed under the pointer, and stays fully inside `bounds`.
    public static func origin(pointer: CGPoint, grabOffset: CGPoint, size: CGSize, within bounds: CGRect,
                              bleed: CGSize = transparentMargin) -> CGPoint {
        clamp(origin: CGPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y), size: size,
              within: bounds, bleed: bleed)
    }

    /// Moves `origin` the least needed so a window of `size` fits inside `bounds`.
    /// `bleed` is how far the window's transparent margin may reach past `bounds` on each side.
    /// A window larger than `bounds` is pinned to its top-left corner.
    public static func clamp(origin: CGPoint, size: CGSize, within bounds: CGRect,
                             bleed: CGSize = transparentMargin) -> CGPoint {
        let minX = bounds.minX - bleed.width, minY = bounds.minY - bleed.height
        return CGPoint(x: min(max(origin.x, minX), max(minX, bounds.maxX - size.width + bleed.width)),
                       y: min(max(origin.y, minY), max(minY, bounds.maxY - size.height + bleed.height)))
    }
}
