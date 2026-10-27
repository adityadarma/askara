import AppKit
import ApplicationServices
import AskaraCore

/// Keeps the system Picture in Picture window where the user drops it.
///
/// macOS draws that window in `PIPAgent`, a separate system process, so Askara cannot place it
/// with AppKit. After a drag ends, the agent snaps the window to the nearest screen corner. This
/// watches mouse events, and when a drag of the PiP window ends it moves the window to where it
/// was dropped through the Accessibility API (which needs the user's permission).
@MainActor
final class PictureInPictureMover {
    static let shared = PictureInPictureMover()

    private static let agentBundleID = "com.apple.PIPAgent"
    private static let savedOriginKey = "PictureInPictureOrigin"

    private struct Gesture {
        let window: AXUIElement
        let startPointer: CGPoint
        /// Where inside the window the user grabbed it.
        let grabOffset: CGPoint
        let startSize: CGSize
        var isDragging = false
        /// Last window frame seen while dragging; the source of truth when the drag was a resize.
        var lastFrame: CGRect
    }

    private var monitor: Any?
    private var gesture: Gesture?
    private var holdTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?

    private var isEnabled: Bool { BrowserServices.shared.preferences.pipFreePlacement }

    private var isPictureInPictureActive: Bool {
        BrowserServices.shared.windows.contains { $0.allTabs.contains { $0.isPictureInPicture } }
    }

    func start() {
        NotificationCenter.default.addObserver(forName: .askaraPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Asks macOS for the Accessibility permission (shows the system prompt once). No-op when granted.
    static func requestAccessibilityAccess() {
        guard !AXIsProcessTrusted() else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Called when a tab's video enters Picture in Picture: puts the window at the last position.
    func pictureInPictureDidStart() {
        guard isEnabled, AXIsProcessTrusted(), let saved = savedOrigin else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            var previous: CGRect?
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                guard let self, self.gesture == nil,
                      let window = self.pictureInPictureWindow(), let frame = self.frame(of: window) else { continue }
                // The window flies in from the video first. Move it once it stops.
                guard previous == frame else { previous = frame; continue }
                let target = PictureInPicturePlacement.clamp(
                    origin: saved, size: frame.size, within: Self.visibleBounds(containing: saved))
                if abs(frame.minX - target.x) > 1 || abs(frame.minY - target.y) > 1 {
                    self.setOrigin(target, of: window)
                    self.hold(window, at: target)
                }
                return
            }
        }
    }

    // MARK: - Mouse tracking

    private func refresh() {
        if isEnabled, monitor == nil {
            // Mouse events in other apps' windows (the PiP window) arrive through a global monitor.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } else if !isEnabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            gesture = nil
            holdTask?.cancel()
            restoreTask?.cancel()
        }
    }

    private func handle(_ event: NSEvent) {
        guard AXIsProcessTrusted() else { gesture = nil; return }
        let pointer = Self.topLeft(NSEvent.mouseLocation)
        switch event.type {
        case .leftMouseDown:
            gesture = nil
            let active = isPictureInPictureActive
            guard active else { return }
            let window = pictureInPictureWindow(containing: pointer)
            Log.notice("PiP mover: mouse down, window found: \(window != nil)")
            guard let window, let frame = frame(of: window) else { return }
            holdTask?.cancel()
            gesture = Gesture(window: window, startPointer: pointer,
                              grabOffset: CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY),
                              startSize: frame.size, lastFrame: frame)
        case .leftMouseDragged:
            guard var current = gesture else { return }
            if !current.isDragging, PictureInPicturePlacement.isDrag(from: current.startPointer, to: pointer) {
                current.isDragging = true
            }
            if current.isDragging, let frame = frame(of: current.window) { current.lastFrame = frame }
            gesture = current
        case .leftMouseUp:
            guard let current = gesture else { return }
            gesture = nil
            Log.notice("PiP mover: mouse up, dragging: \(current.isDragging)")
            if current.isDragging { drop(current, pointer: pointer) }
        default:
            break
        }
    }

    /// The drag ended: macOS is about to snap the window to a corner. Put it where it was dropped.
    private func drop(_ gesture: Gesture, pointer: CGPoint) {
        let size = gesture.lastFrame.size
        let resized = abs(size.width - gesture.startSize.width) > 1 || abs(size.height - gesture.startSize.height) > 1
        let bounds = Self.visibleBounds(containing: pointer)
        let target = resized
            ? PictureInPicturePlacement.clamp(origin: gesture.lastFrame.origin, size: size, within: bounds)
            : PictureInPicturePlacement.origin(pointer: pointer, grabOffset: gesture.grabOffset, size: size, within: bounds)
        savedOrigin = target
        Log.notice("PiP mover: drop at \(Int(pointer.x)),\(Int(pointer.y)) -> target \(Int(target.x)),\(Int(target.y)), resized: \(resized)")
        // Right now, before the agent starts its snap animation, then keep correcting.
        setOrigin(target, of: gesture.window)
        hold(gesture.window, at: target)
    }

    /// The agent animates the window toward a corner for a moment after the mouse button goes up.
    /// Checking every frame keeps the window from visibly drifting before it is put back.
    private func hold(_ window: AXUIElement, at target: CGPoint) {
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            for _ in 0..<90 {
                if Task.isCancelled { return }
                guard let self, let frame = self.frame(of: window) else { return }
                if abs(frame.minX - target.x) > 0.5 || abs(frame.minY - target.y) > 0.5 {
                    self.setOrigin(target, of: window)
                }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    // MARK: - Remembered position

    /// Last position, in the same top-left coordinates as the Accessibility API. Local to this Mac.
    private var savedOrigin: CGPoint? {
        get { UserDefaults.standard.string(forKey: Self.savedOriginKey).map(NSPointFromString).map { CGPoint(x: $0.x, y: $0.y) } }
        set { UserDefaults.standard.set(newValue.map { NSStringFromPoint(NSPoint(x: $0.x, y: $0.y)) }, forKey: Self.savedOriginKey) }
    }

    // MARK: - Accessibility

    private func pictureInPictureWindow(containing point: CGPoint? = nil) -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID)
            .first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A stuck agent must not freeze the browser.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let frame = frame(of: window) else { return false }
            // A little slack: the window's soft edge and a fast pointer can sit just outside its frame.
            return point.map { frame.insetBy(dx: -12, dy: -12).contains($0) } ?? true
        }
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private func setOrigin(_ origin: CGPoint, of window: AXUIElement) {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    // MARK: - Coordinates

    /// AppKit points have their origin at the bottom left of the main display; Accessibility and
    /// CGEvent use the top left.
    private static func topLeft(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    /// Where the window may go on the display under `point` (the main display when none matches):
    /// the whole screen edge to edge, so it can sit in a real corner. Only the top stops below the
    /// menu bar, which would otherwise cover the window's title area.
    private static func visibleBounds(containing point: CGPoint) -> CGRect {
        let screens = NSScreen.screens
        guard let main = screens.first else { return .zero }
        func topLeft(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: main.frame.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let screen = screens.first { topLeft($0.frame).contains(point) } ?? main
        let full = topLeft(screen.frame)
        let usableTop = topLeft(screen.visibleFrame).minY
        return CGRect(x: full.minX, y: usableTop, width: full.width, height: full.maxY - usableTop)
    }
}
