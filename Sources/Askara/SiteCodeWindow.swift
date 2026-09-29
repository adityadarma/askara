import AppKit
import AskaraCore

/// Editor for a site's custom CSS and JavaScript (Develop > Custom CSS & JavaScript…).
/// One window per site; opening it again brings the existing one forward.
@MainActor
final class SiteCodeWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: SiteCodeWindowController] = [:]

    /// `reload` is true for "Save & Reload".
    typealias SaveHandler = (_ host: String, _ customization: SiteCustomization, _ reload: Bool) -> Void

    private let host: String
    private let onSave: SaveHandler
    private let enabledBox = NSButton(checkboxWithTitle: String(localized: "Enabled"), target: nil, action: nil)
    private let cssView: NSTextView
    private let jsView: NSTextView
    private let cssScroll: NSScrollView
    private let jsScroll: NSScrollView

    static func show(host rawHost: String, relativeTo parent: NSWindow?, onSave: @escaping SaveHandler) {
        let host = SiteSettings.key(for: rawHost)
        if let existing = open[host] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SiteCodeWindowController(host: host, onSave: onSave)
        open[host] = controller
        if let window = controller.window {
            if let parent {
                window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 60, y: parent.frame.maxY - 60))
            } else {
                window.center()
            }
        }
        controller.showWindow(nil)
    }

    private init(host: String, onSave: @escaping SaveHandler) {
        self.host = host
        self.onSave = onSave
        (cssScroll, cssView) = Self.makeCodeView(label: String(localized: "Custom CSS"))
        (jsScroll, jsView) = Self.makeCodeView(label: String(localized: "Custom JavaScript"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Custom Code: \(host)")
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let saved = BrowserServices.shared.siteSettings.customization(for: host) ?? SiteCustomization()
        cssView.string = saved.css
        jsView.string = saved.javaScript
        enabledBox.state = saved.isEnabled ? .on : .off
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Plain-text editor for code: monospaced, no smart quotes/dashes/autocorrect (they would break code).
    private static func makeCodeView(label: String) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.isRichText = false
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.usesFindBar = true
        text.setAccessibilityLabel(label)
        return (scroll, text)
    }

    private func buildUI() {
        guard let root = window?.contentView else { return }

        let scope = NSTextField(wrappingLabelWithString:
            String(localized: "Applies to \(host) and its subdomains. Runs even if the site blocks scripts or JavaScript is blocked for it."))
        scope.textColor = .secondaryLabelColor
        scope.font = .systemFont(ofSize: 12)

        let cssLabel = NSTextField(labelWithString: String(localized: "CSS (applied as the page loads)"))
        let jsLabel = NSTextField(labelWithString: String(localized: "JavaScript (runs after the page loads)"))
        [cssLabel, jsLabel].forEach { $0.font = .boldSystemFont(ofSize: 12) }

        let remove = NSButton(title: String(localized: "Remove"), target: self, action: #selector(removeAction(_:)))
        let save = NSButton(title: String(localized: "Save"), target: self, action: #selector(saveAction(_:)))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.toolTip = String(localized: "Save and apply the CSS to open pages (⌘S)")
        let saveReload = NSButton(title: String(localized: "Save & Reload"), target: self,
                                  action: #selector(saveAndReloadAction(_:)))
        saveReload.keyEquivalent = "r"
        saveReload.keyEquivalentModifierMask = .command
        saveReload.toolTip = String(localized: "Save and reload the page to run the JavaScript (⌘R)")
        saveReload.bezelColor = .controlAccentColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [remove, enabledBox, spacer, save, saveReload])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [scope, cssLabel, cssScroll, jsLabel, jsScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: scope)
        stack.setCustomSpacing(12, after: cssScroll)
        stack.setCustomSpacing(12, after: jsScroll)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scope.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            cssScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            jsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            cssScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            jsScroll.heightAnchor.constraint(equalTo: cssScroll.heightAnchor),
        ])
        window?.initialFirstResponder = cssView
    }

    private var current: SiteCustomization {
        SiteCustomization(css: cssView.string, javaScript: jsView.string, isEnabled: enabledBox.state == .on)
    }

    @objc private func saveAction(_ sender: Any?) { onSave(host, current, false) }

    @objc private func saveAndReloadAction(_ sender: Any?) { onSave(host, current, true) }

    @objc private func removeAction(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove custom code for \(host)?")
        alert.informativeText = String(localized: "The CSS and JavaScript for this site will be deleted.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.onSave(self.host, SiteCustomization(), false)
            self.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[host] = nil
    }
}
