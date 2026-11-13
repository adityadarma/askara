import AppKit
import QuartzCore
import UniformTypeIdentifiers

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

/// Compact toolbar popover that mirrors Chrome's active-download menu.
@MainActor
final class DownloadsPopoverController: NSViewController {
    private let manager: DownloadManager
    private let onShowAll: () -> Void
    private var observer: NSObjectProtocol?

    init(manager: DownloadManager, onShowAll: @escaping () -> Void) {
        self.manager = manager
        self.onShowAll = onShowAll
        super.init(nibName: nil, bundle: nil)
        observer = NotificationCenter.default.addObserver(forName: .askaraDownloadsChanged,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() { rebuild() }

    private func rebuild() {
        let items = Array(manager.running.prefix(3))
        let rowHeight: CGFloat = 54
        let listHeight = items.isEmpty ? 48 : CGFloat(items.count) * rowHeight
        let contentHeight = 12 + 25 + 8 + listHeight + 8 + 1 + 6 + 32 + 10
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: contentHeight))
        preferredContentSize = container.frame.size

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let title = NSTextField(labelWithString: String(localized: "Downloads"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(title)
        root.setCustomSpacing(8, after: title)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        if items.isEmpty {
            let empty = NSTextField(labelWithString: String(localized: "No active downloads"))
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.font = .systemFont(ofSize: 13)
            empty.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(empty)
            NSLayoutConstraint.activate([
                empty.widthAnchor.constraint(equalTo: rows.widthAnchor),
                empty.heightAnchor.constraint(equalToConstant: listHeight),
            ])
        } else {
            for item in items { rows.addArrangedSubview(makeRow(for: item, width: rows.widthAnchor, height: rowHeight)) }
        }
        root.addArrangedSubview(rows)
        root.setCustomSpacing(8, after: rows)

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        root.setCustomSpacing(6, after: separator)

        let showAll = NSButton(title: String(localized: "Show All Downloads"), target: self,
                               action: #selector(showAllDownloads(_:)))
        showAll.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: showAll.title)
        showAll.imagePosition = .imageLeading
        showAll.alignment = .left
        showAll.isBordered = false
        showAll.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(showAll)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            title.heightAnchor.constraint(equalToConstant: 25),
            rows.widthAnchor.constraint(equalTo: root.widthAnchor),
            rows.heightAnchor.constraint(equalToConstant: listHeight),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor),
            showAll.widthAnchor.constraint(equalTo: root.widthAnchor),
            showAll.heightAnchor.constraint(equalToConstant: 32),
        ])
        view = container
    }

    private func makeRow(for item: DownloadManager.Item, width: NSLayoutDimension, height: CGFloat) -> NSView {
        let ext = (item.filename as NSString).pathExtension
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: item.filename)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let status = NSTextField(labelWithString: item.statusText)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = item.fraction <= 0
        if progress.isIndeterminate { progress.startAnimation(nil) }
        else { progress.doubleValue = item.fraction }

        let text = NSStackView(views: [name, progress, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton()
        cancel.identifier = .init(item.id.uuidString)
        cancel.image = NSImage(systemSymbolName: "xmark.circle.fill",
                               accessibilityDescription: String(localized: "Cancel Download"))
        cancel.imagePosition = .imageOnly
        cancel.isBordered = false
        cancel.contentTintColor = .secondaryLabelColor
        cancel.target = self
        cancel.action = #selector(cancelDownload(_:))
        cancel.toolTip = String(localized: "Cancel Download")

        let row = NSStackView(views: [icon, text, cancel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: width),
            row.heightAnchor.constraint(equalToConstant: height),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 24),
            cancel.heightAnchor.constraint(equalToConstant: 24),
        ])
        return row
    }

    @objc private func cancelDownload(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let item = manager.running.first(where: { $0.id == id }) else { return }
        manager.cancel(item)
    }

    @objc private func showAllDownloads(_ sender: Any?) {
        view.window?.performClose(nil)
        onShowAll()
    }
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
