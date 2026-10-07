import AppKit
import QuartzCore

/// Toolbar Downloads button. While downloads run it shows a progress ring around the arrow:
/// the ring fills as data arrives, or spins while the total size is still unknown.
/// Animations run in Core Animation (no redraw timer) and respect Reduce Motion.
final class DownloadsToolbarButton: FirstClickButton {
    /// nil: nothing running. 0: running, progress unknown. Above 0: fraction done (0...1).
    var progress: Double? {
        didSet { if progress != oldValue { ringView.update(progress: progress) } }
    }

    private let ringView = ProgressRingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addRing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addRing()
    }

    private func addRing() {
        ringView.frame = bounds
        ringView.autoresizingMask = [.width, .height]
        addSubview(ringView)
    }

    // Exposed for tests.
    var ringFraction: CGFloat { ringView.ring.isHidden ? 0 : ringView.ring.strokeEnd }
    var isRingVisible: Bool { !ringView.ring.isHidden }
    var isSpinning: Bool { ringView.ring.animation(forKey: ProgressRingView.spinKey) != nil }
}

/// The ring itself. A separate view so clicks pass through to the button.
private final class ProgressRingView: NSView {
    static let spinKey = "askara.downloads.spin"
    private static let diameter: CGFloat = 20
    private static let lineWidth: CGFloat = 2

    let track = CAShapeLayer()
    let ring = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        ring.strokeEnd = 0
        updateColors()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updatePaths()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Whether the layer's y axis points down; decides where "top" is and which way is clockwise.
    private var isYDown: Bool { ring.contentsAreFlipped() }

    func update(progress: Double?) {
        CATransaction.begin()
        // Animate the fill only while visible; appearing and disappearing are instant.
        CATransaction.setDisableActions(reduceMotion || progress == nil || ring.isHidden)
        defer { CATransaction.commit() }

        guard let progress else {
            track.isHidden = true
            ring.isHidden = true
            ring.removeAnimation(forKey: Self.spinKey)
            ring.strokeEnd = 0
            return
        }
        track.isHidden = false
        ring.isHidden = false
        if progress <= 0 {
            // Unknown size: a short arc that spins. With Reduce Motion only the track shows.
            ring.strokeEnd = reduceMotion ? 0 : 0.25
            if !reduceMotion, ring.animation(forKey: Self.spinKey) == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = isYDown ? 2 * CGFloat.pi : -2 * CGFloat.pi
                spin.duration = 1
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                ring.add(spin, forKey: Self.spinKey)
            }
        } else {
            ring.removeAnimation(forKey: Self.spinKey)
            ring.strokeEnd = CGFloat(min(progress, 1))
        }
    }

    private func updatePaths() {
        let d = Self.diameter
        let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let center = CGPoint(x: d / 2, y: d / 2)
        let radius = (d - Self.lineWidth) / 2
        // Start at 12 o'clock and run clockwise on screen.
        let path = CGMutablePath()
        if isYDown {
            path.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        } else {
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: -1.5 * .pi, clockwise: true)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, ring] {
            shape.frame = rect
            shape.path = path
        }
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
            ring.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }
}
