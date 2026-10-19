import AppKit
import WebKit

/// Full-page capture. WKWebView only renders what is on screen, so the view is made taller for the
/// moment of the snapshot. Scroll areas sized to the viewport (sidebars, content panels with
/// `height: 100vh`) then grow to show everything, and sticky/fixed elements appear once.
@MainActor
enum PageCapture {
    /// Longest result, in points. Very long pages (endless feeds) are cut here; PDF has no such limit.
    static let maxHeight: CGFloat = 16_000
    /// Bitmap size cap, so a wide and tall page can't use gigabytes of memory.
    private static let maxPixels: CGFloat = 60_000_000

    /// Extra height (CSS px) the page needs so no large scroll area (the page itself, or an inner
    /// scroller at least half as tall as the window) has anything left to scroll.
    private static let measureScript = """
    (() => {
      const root = document.scrollingElement || document.documentElement;
      let extra = Math.max(0, root.scrollHeight - window.innerHeight);
      if (!document.body) return extra;
      for (const e of document.body.querySelectorAll('*')) {
        if (e.clientHeight < window.innerHeight / 2 || e.scrollHeight <= e.clientHeight + 1) continue;
        if (!/(auto|scroll|overlay)/.test(getComputedStyle(e).overflowY)) continue;
        extra = Math.max(extra, e.scrollHeight - e.clientHeight);
      }
      return Math.ceil(extra);
    })()
    """

    static func fullPage(of web: WKWebView) async -> (image: NSImage, truncated: Bool)? {
        let original = web.frame
        guard original.width > 0, original.height > 0 else { return nil }
        // Always put the view back, whatever happens below.
        defer { web.frame = original }

        let zoom = web.pageZoom
        var height = original.height
        var truncated = false
        // A few rounds: growing the viewport changes `100vh` layouts, which can change what is left to scroll.
        for _ in 0..<3 {
            let extra = ((try? await web.evaluateJavaScript(measureScript)) as? NSNumber).map { CGFloat($0.doubleValue) * zoom } ?? 0
            guard extra >= 1 else { break }
            let target = min(height + extra, maxHeight)
            if target >= maxHeight { truncated = true }
            guard target > height else { break }
            height = target
            web.frame = NSRect(x: original.minX, y: original.maxY - height, width: original.width, height: height)
            // Let layout, lazy images, and scroll-linked content settle.
            try? await Task.sleep(for: .milliseconds(350))
        }

        let backing = web.window?.backingScaleFactor ?? 2
        let scale = max(0.25, min(backing, (maxPixels / (original.width * height)).squareRoot()))
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: original.width, height: height)
        // snapshotWidth is in points: only set it to lower the resolution of very large pages.
        if scale < backing { config.snapshotWidth = NSNumber(value: Double(original.width * scale / backing)) }
        config.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            web.takeSnapshot(with: config) { image, _ in continuation.resume(returning: image) }
        }
        guard let image else { return nil }
        return (image, truncated)
    }
}
