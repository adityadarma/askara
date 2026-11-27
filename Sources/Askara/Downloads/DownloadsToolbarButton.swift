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

/// Compact toolbar popover for the five most recent downloads, including completed items.
@MainActor
final class DownloadsPopoverController: NSViewController {
    static let maxVisibleItems = 5

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

    static func visibleItems(from items: [DownloadManager.Item]) -> [DownloadManager.Item] {
        Array(items.prefix(maxVisibleItems))
    }

    private func rebuild() {
        let items = Self.visibleItems(from: manager.items)
        let rowHeight: CGFloat = 62
        let separatorHeight: CGFloat = items.count > 1 ? CGFloat(items.count - 1) : 0
        let listHeight = items.isEmpty ? 64 : CGFloat(items.count) * rowHeight + separatorHeight
        let contentHeight = 14 + 24 + 10 + listHeight + 10 + 1 + 6 + 34 + 10
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: contentHeight))
        preferredContentSize = container.frame.size

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        let title = NSTextField(labelWithString: String(localized: "Downloads"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        if !items.isEmpty {
            let activeCount = manager.running.count
            let summaryText = activeCount > 0 ? String(localized: "\(activeCount) active")
                : String(localized: "Recent")
            let summary = NSTextField(labelWithString: summaryText)
            summary.font = .systemFont(ofSize: 11, weight: .medium)
            summary.textColor = .secondaryLabelColor
            header.addArrangedSubview(summary)
        }
        root.addArrangedSubview(header)
        root.setCustomSpacing(10, after: header)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        if items.isEmpty {
            let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.circle",
                                                       accessibilityDescription: nil) ?? NSImage())
            emptyIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            emptyIcon.contentTintColor = .tertiaryLabelColor
            let emptyText = NSTextField(labelWithString: String(localized: "No downloads yet"))
            emptyText.textColor = .secondaryLabelColor
            emptyText.font = .systemFont(ofSize: 12)
            let empty = NSStackView(views: [emptyIcon, emptyText])
            empty.orientation = .vertical
            empty.alignment = .centerX
            empty.spacing = 5
            rows.addArrangedSubview(empty)
            NSLayoutConstraint.activate([
                empty.widthAnchor.constraint(equalTo: rows.widthAnchor),
                empty.heightAnchor.constraint(equalToConstant: listHeight),
            ])
        } else {
            for (index, item) in items.enumerated() {
                let row = makeRow(for: item, height: rowHeight)
                rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                if index < items.count - 1 {
                    let divider = NSBox()
                    divider.boxType = .separator
                    rows.addArrangedSubview(divider)
                    divider.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                    divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                }
            }
        }
        root.addArrangedSubview(rows)
        root.setCustomSpacing(10, after: rows)

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
        showAll.font = .systemFont(ofSize: 13, weight: .medium)
        root.addArrangedSubview(showAll)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            rows.widthAnchor.constraint(equalTo: root.widthAnchor),
            rows.heightAnchor.constraint(equalToConstant: listHeight),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor),
            showAll.widthAnchor.constraint(equalTo: root.widthAnchor),
            showAll.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = container
    }

    private func makeRow(for item: DownloadManager.Item, height: CGFloat) -> NSView {
        let exists = item.destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let fileImage: NSImage
        if exists, let path = item.destination?.path {
            fileImage = NSWorkspace.shared.icon(forFile: path)
        } else {
            let ext = (item.filename as NSString).pathExtension
            fileImage = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        let icon = NSImageView(image: fileImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.alphaValue = exists || item.state == .running ? 1 : 0.55
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: item.filename)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.textColor = exists || item.state == .running ? .labelColor : .secondaryLabelColor
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let presentation = rowPresentation(for: item)
        let stateIcon = NSImageView(image: NSImage(systemSymbolName: presentation.symbol,
                                                   accessibilityDescription: nil) ?? NSImage())
        stateIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        stateIcon.contentTintColor = presentation.color
        let status = NSTextField(labelWithString: presentation.text)
        status.font = item.state == .running
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        status.textColor = presentation.color
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusLine = NSStackView(views: [stateIcon, status])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 4

        var textViews: [NSView] = [name, statusLine]
        var progress: NSProgressIndicator?
        if item.state == .running {
            let indicator = NSProgressIndicator()
            indicator.style = .bar
            indicator.controlSize = .small
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.isIndeterminate = item.fraction <= 0
            if indicator.isIndeterminate { indicator.startAnimation(nil) }
            else { indicator.doubleValue = item.fraction }
            textViews.append(indicator)
            progress = indicator
        }

        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action = NSButton()
        action.identifier = .init(item.id.uuidString)
        action.imagePosition = .imageOnly
        action.isBordered = false
        action.contentTintColor = .secondaryLabelColor
        action.target = self
        if item.state == .running {
            let label = String(localized: "Cancel Download")
            action.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: label)
            action.action = #selector(cancelDownload(_:))
            action.toolTip = label
        } else if item.state == .finished, exists {
            let label = String(localized: "Show in Finder")
            action.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: label)
            action.action = #selector(revealDownload(_:))
            action.toolTip = label
        } else {
            action.image = nil
            action.isEnabled = false
        }

        let row = NSStackView(views: [icon, text, action])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            row.heightAnchor.constraint(equalToConstant: height),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            stateIcon.widthAnchor.constraint(equalToConstant: 12),
            stateIcon.heightAnchor.constraint(equalToConstant: 12),
            action.widthAnchor.constraint(equalToConstant: 24),
            action.heightAnchor.constraint(equalToConstant: 24),
        ]
        if let progress { constraints.append(progress.widthAnchor.constraint(equalTo: text.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func rowPresentation(for item: DownloadManager.Item) -> (text: String, symbol: String, color: NSColor) {
        let host = item.sourceURL?.host
        switch item.state {
        case .running:
            let parts = [item.statusText, host].compactMap { $0 }
            return (parts.joined(separator: " · "), "arrow.down", .controlAccentColor)
        case .cancelled:
            return (item.statusText, "xmark.circle", .secondaryLabelColor)
        case .failed:
            return (item.statusText, "exclamationmark.circle.fill", .systemRed)
        case .finished:
            switch item.scanState {
            case .waiting, .scanning:
                return (item.statusText, "shield", .secondaryLabelColor)
            case .failed:
                return (item.statusText, "exclamationmark.triangle.fill", .systemOrange)
            case .complete where item.risks.contains(where: \.isHighRisk):
                return (item.statusText, "exclamationmark.triangle.fill", .systemOrange)
            case .complete:
                let size = item.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                let parts = [String(localized: "Completed"), size].compactMap { $0 }
                return (parts.joined(separator: " · "), "checkmark.circle.fill", .systemGreen)
            }
        }
    }

    @objc private func cancelDownload(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let item = manager.running.first(where: { $0.id == id }) else { return }
        manager.cancel(item)
    }

    @objc private func revealDownload(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let url = manager.items.first(where: { $0.id == id })?.destination,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
