import AppKit
import WebKit
import AskaraCore

/// A single tab. `webView` is nil while the tab sleeps: only the URL, title, zoom, and
/// `interactionState` (back/forward history + scroll position) are kept.
@MainActor
final class Tab: NSObject {
    let id = UUID()
    /// Window that owns the tab (for the extension API).
    weak var owner: BrowserWindowController?
    var url: URL?
    /// URL shown in the address bar. Only updated once the page has loaded, so
    /// redirect hops (tracking links, SSO logins, etc.) stay hidden.
    var displayURL: URL?
    /// New tab (⌘T): the search engine's page loads, but the address bar stays empty and ready
    /// for typing, like Chrome's new tab page. Ends once the tab goes to another page.
    var hidesHomeAddress = false
    /// First page the new tab committed (after redirects); the address stays hidden only on it.
    var homeLandingURL: URL?
    /// New tab: put the cursor back in the address bar once the page has rendered, since pages
    /// like Google focus their own search box while loading and take the keyboard away.
    var refocusAddressAfterLoad = false
    var title: String
    var zoom: Double = 1
    var lastActive = Date()
    var interactionState: Any?
    /// Device Mode (Develop menu): emulated screen size and user agent. nil = off.
    var device: DevicePreset?
    var deviceLandscape = false
    /// Forced `prefers-color-scheme` (Develop > Appearance). nil = follow the system.
    var colorScheme: NSAppearance.Name?
    /// Pinned: icon-only at the start of the tab strip, never put to sleep.
    var isPinned = false
    /// Muted: page audio silenced. Kept while the tab sleeps and reapplied when it wakes.
    var isMuted = false
    /// RAM freed the last time this tab was put to sleep (Memory Saver). 0 = unknown.
    var freedBytes: UInt64 = 0
    /// HTTPS-Only Mode: the original http:// URL while its https:// upgrade is loading.
    var httpFallbackURL: URL?
    /// Frames on this page with unsubmitted form input (reported by FormGuard).
    var dirtyFrames: Set<String> = []
    var hasUnsavedInput: Bool { !dirtyFrames.isEmpty }
    var webView: WKWebView? {
        didSet {
            if webView == nil {
                observations.removeAll()
                dirtyFrames.removeAll()
            }
        }
    }
    var observations: [NSKeyValueObservation] = []

    init(url: URL?, title: String? = nil) {
        self.url = url
        self.displayURL = url
        self.title = title ?? url?.host ?? String(localized: "New Tab")
        super.init()
    }

    var isPlayingAudio: Bool {
        guard let webView else { return false }
        return webView.askaraIsPlayingAudio || webView.askaraIsCapturingMedia
    }
}

/// Address bar: the first click selects the whole URL (like Safari/Chrome), so it can be
/// retyped right away. Later clicks while editing place the cursor as usual.
final class AddressField: NSTextField {
    /// Set when the field has just become first responder. AppKit makes the field editable inside
    /// becomeFirstResponder, *before* mouseDown runs, so checking `currentEditor()` in mouseDown
    /// can't tell a focusing click from a click while already editing.
    private var justFocused = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            justFocused = true
            DispatchQueue.main.async { [weak self] in self?.justFocused = false }
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let selectAll = justFocused
        justFocused = false
        // super tracks the click/drag until the mouse button is released.
        super.mouseDown(with: event)
        // A drag that selected part of the text is respected.
        guard selectAll, let editor = currentEditor(), editor.selectedRange.length == 0 else { return }
        editor.selectAll(nil)
    }
}

/// Forwards JS messages without a retain cycle (WKUserContentController holds handlers strongly).
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserWindowController?
    init(_ target: BrowserWindowController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            // A tab dragged to another window keeps its web view; messages go to the window it's in now.
            let target = (message.webView as? AskaraWebView)?.browser ?? self.target
            switch message.name {
            case FormGuard.handlerName:
                guard let body = message.body as? [String: Any], let frame = body["frame"] as? String else { return }
                target?.formStateChanged(in: message.webView, frame: frame, dirty: (body["dirty"] as? Bool) ?? false)
            case ContextMenuProbe.handlerName:
                guard let web = message.webView as? AskaraWebView, let body = message.body as? [String: Any] else { return }
                func url(_ key: String) -> URL? {
                    guard let text = body[key] as? String, !text.isEmpty else { return nil }
                    return URL(string: text)
                }
                web.contextTarget = ContextTarget(link: url("link"), image: url("image"),
                                                  selection: body["selection"] as? String ?? "")
            default:
                target?.passkeyFailed(in: message.webView)
            }
        }
    }
}

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate,
                                     WKUIDelegate, NSSearchFieldDelegate, NSTextFieldDelegate,
                                     NSMenuItemValidation, TabStripDelegate {
    let isPrivate: Bool
    /// The profile whose logins, history, and bookmarks this window uses.
    let profile: ProfileData
    /// When this window was last focused; the most recent one is the profile's "current" window.
    private(set) var lastFocused = Date()

    private let dataStore: WKWebsiteDataStore
    private var tabs: [Tab] = []
    private var activeIndex = -1
    private var passkeyWarnedHosts: Set<String> = []
    private var focusAddressBarOnActivate = false
    private var services: BrowserServices { .shared }

    // UI
    private let tabStrip = TabStripView()
    private let toolbar = FillView()
    private let addressField = AddressField()
    /// Created on first keystroke in the address bar.
    private lazy var suggestions: AddressSuggestionsController = {
        let controller = AddressSuggestionsController()
        controller.onChoose = { [weak self] in self?.chooseSuggestion($0) }
        return controller
    }()
    /// What the user actually typed, restored when arrowing back past the first suggestion.
    private var typedAddress = ""
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let bookmarkButton = NSButton()
    /// Profile avatar at the right end of the toolbar, like Chrome.
    private let profileButton = FirstClickButton()
    private let bookmarkBar = BookmarkBarView()
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")
    private let contentView = NSView()
    private let toast = ToastView()
    private let loadingBar = LoadingBar()

    private var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    /// Loaded web view of the active tab (screenshot).
    var activeWebViewForCapture: WKWebView? { activeTab?.webView }

    init(profile: ProfileData, isPrivate: Bool) {
        self.profile = profile
        self.isPrivate = isPrivate
        // Private window: cookies/cache live in memory only and vanish when the window closes.
        dataStore = isPrivate ? .nonPersistent() : profile.dataStore

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        // Tabs sit in the titlebar area, like Chrome. An empty toolbar makes the titlebar as tall as
        // the tab strip so the red/yellow/green buttons line up with the tabs.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "AskaraTitlebar")
        window.toolbarStyle = .unifiedCompact
        window.center()
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        super.init(window: window)
        window.delegate = self
        let root = BrowserRootView()
        root.tabStrip = tabStrip
        window.contentView = root
        buildUI()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(bookmarksChanged),
                           name: .askaraBookmarksChanged, object: profile)
        center.addObserver(self, selector: #selector(profilesChanged),
                           name: .askaraProfilesChanged, object: nil)
        center.addObserver(self, selector: #selector(downloadEvent(_:)),
                           name: .askaraDownloadEvent, object: nil)
        center.addObserver(self, selector: #selector(refreshExtensionButtons),
                           name: .askaraExtensionsChanged, object: profile)
        center.addObserver(self, selector: #selector(preferencesChanged),
                           name: .askaraPreferencesChanged, object: nil)
        // Device Mode keeps the emulated screen centered and fitted when the window resizes.
        contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(contentViewResized(_:)),
                           name: NSView.frameDidChangeNotification, object: contentView)
        refreshExtensionButtons()
        extensionController?.didOpenWindow(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - UI

    private func buildUI() {
        guard let root = window?.contentView else { return }

        func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        configure(backButton, symbol: "arrow.left", label: String(localized: "Back (⌘[)"), action: #selector(backAction(_:)))
        configure(forwardButton, symbol: "arrow.right", label: String(localized: "Forward (⌘])"), action: #selector(forwardAction(_:)))
        configure(reloadButton, symbol: "arrow.clockwise", label: String(localized: "Reload (⌘R)"), action: #selector(reloadAction(_:)))
        configure(bookmarkButton, symbol: "star", label: String(localized: "Add bookmark (⌘D)"),
                  action: #selector(toggleBookmarkAction(_:)))

        tabStrip.delegate = self
        tabStrip.isPrivate = isPrivate

        addressField.placeholderString = isPrivate ? String(localized: "Private: search or enter address") : String(localized: "Search or enter address")
        addressField.setAccessibilityLabel(String(localized: "Address bar"))
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))
        addressField.delegate = self
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .large
        addressField.font = .systemFont(ofSize: 14)
        addressField.cell?.sendsActionOnEndEditing = false
        addressField.lineBreakMode = .byTruncatingTail
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureProfileButton()
        let toolbarStack = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, bookmarkButton, profileButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 6
        toolbarStack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 6, right: 10)

        // Find-in-page bar (⌘F), hidden by default.
        findField.placeholderString = String(localized: "Find in page")
        findField.setAccessibilityLabel(String(localized: "Find in page"))
        findField.sendsWholeSearchString = false
        findField.target = self
        findField.action = #selector(findFieldChanged(_:))
        findField.delegate = self
        let prev = NSButton()
        configure(prev, symbol: "chevron.up", label: String(localized: "Previous match (⇧⌘G)"), action: #selector(findPreviousAction(_:)))
        let next = NSButton()
        configure(next, symbol: "chevron.down", label: String(localized: "Next match (⌘G)"), action: #selector(findNextAction(_:)))
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(hideFindBar(_:)))
        done.bezelStyle = .rounded
        findStatus.textColor = .secondaryLabelColor
        findField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        [findField, prev, next, findStatus, NSView(), done].forEach(findBar.addArrangedSubview)
        findBar.orientation = .horizontal
        findBar.spacing = 6
        findBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 6, right: 10)
        findBar.isHidden = true

        // Toolbar + find bar in one block, colored the same as the active tab.
        toolbar.color = isPrivate ? AskaraColors.privateToolbar : AskaraColors.toolbar
        toolbar.zoomsOnDoubleClick = true
        bookmarkBar.delegate = self
        bookmarkBar.heightAnchor.constraint(equalToConstant: BookmarkBarView.height).isActive = true
        bookmarkBar.reload()
        updateBookmarkBarVisibility()
        let toolbarContent = NSStackView(views: [toolbarStack, bookmarkBar, findBar])
        toolbarContent.orientation = .vertical
        toolbarContent.spacing = 0
        for v in [toolbarStack, bookmarkBar, findBar] { v.widthAnchor.constraint(equalTo: toolbarContent.widthAnchor).isActive = true }

        for v in [tabStrip, toolbar, contentView, loadingBar, toast] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        toolbarContent.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarContent)

        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),

            toolbar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarContent.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarContent.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarContent.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarContent.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -1),

            contentView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Progress line sits on the toolbar's bottom edge, above the page.
            loadingBar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            loadingBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            loadingBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            loadingBar.heightAnchor.constraint(equalToConstant: 2),

            toast.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    func refreshTabStrip() {
        let items = tabs.map {
            TabStripItem(title: $0.title, isSleeping: $0.webView == nil, isPlayingAudio: $0.isPlayingAudio,
                         isLoading: $0.webView?.isLoading ?? false,
                         favicon: FaviconStore.shared.icon(for: $0.webView?.url ?? $0.url),
                         isPinned: $0.isPinned, isMuted: $0.isMuted)
        }
        tabStrip.update(items: items, activeIndex: activeIndex)
    }

    /// Settings changed (e.g. Memory Saver exceptions): redraw tab tooltips/state.
    @objc private func preferencesChanged() {
        refreshTabStrip()
        updateBookmarkBarVisibility()
    }

    /// Shown only when turned on and there's something on it. Private windows never show it
    /// (bookmarks still work from the menu).
    private func updateBookmarkBarVisibility() {
        bookmarkBar.isHidden = isPrivate || !services.preferences.showsBookmarksBar || profile.bookmarks.bar.isEmpty
    }

    /// View > Show/Hide Bookmarks Bar (⇧⌘B). Applies to all windows.
    @objc func toggleBookmarksBarAction(_ sender: Any?) {
        services.updatePreferences { $0.showsBookmarksBar.toggle() }
    }

    private func updateToolbar() {
        let tab = activeTab
        let web = tab?.webView
        backButton.isEnabled = web?.canGoBack ?? false
        forwardButton.isEnabled = web?.canGoForward ?? false
        if addressField.currentEditor() == nil {
            addressField.stringValue = addressText(for: tab)
        }
        // Title is still set for the Window menu, Mission Control, and VoiceOver, even though hidden.
        let title = tab?.title ?? "Askara"
        // Profile name in the title only once there is more than one profile (Window menu, Mission Control).
        let named = services.profileList.profiles.count > 1 ? "\(title) – \(profile.profile.name)" : title
        window?.title = isPrivate ? String(localized: "\(named) (Private)") : named
        let loading = web?.isLoading == true
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: loading ? String(localized: "Stop") : String(localized: "Reload"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        updateBookmarkButton()
    }

    private func updateBookmarkButton() {
        let url = activeTab?.url
        let saved = url.map(profile.bookmarks.contains) ?? false
        let label = saved ? String(localized: "Remove bookmark (⌘D)") : String(localized: "Add bookmark (⌘D)")
        bookmarkButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        bookmarkButton.contentTintColor = saved ? .systemYellow : .secondaryLabelColor
        bookmarkButton.toolTip = label
        bookmarkButton.setAccessibilityLabel(label)
        bookmarkButton.isEnabled = url != nil
    }

    func showToast(_ text: String, duration: TimeInterval? = 3) { toast.show(text, duration: duration) }

    @objc private func bookmarksChanged() {
        updateBookmarkButton()
        bookmarkBar.reload()
        updateBookmarkBarVisibility()
    }

    // MARK: - Profile button

    private func configureProfileButton() {
        profileButton.isBordered = false
        profileButton.imagePosition = .imageOnly
        profileButton.target = self
        profileButton.action = #selector(profileButtonClicked(_:))
        profileButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        profileButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateProfileButton()
    }

    private func updateProfileButton() {
        let current = profile.profile
        profileButton.image = ProfileColors.avatar(for: current, size: 20)
        // Private windows show the profile too, but dimmed: they don't use its logins.
        profileButton.alphaValue = isPrivate ? 0.6 : 1
        let label = isPrivate ? String(localized: "Profile: \(current.name) (private window)")
                              : String(localized: "Profile: \(current.name)")
        profileButton.toolTip = label
        profileButton.setAccessibilityLabel(label)
    }

    @objc private func profilesChanged() {
        // This window's profile was deleted: it's being closed.
        guard services.profileList.profile(profile.id) != nil else { return }
        updateProfileButton()
        updateToolbar()
    }

    @objc private func profileButtonClicked(_ sender: NSButton) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let menu = NSMenu()
        ProfileMenu.fill(menu, current: profile.id, target: delegate)
        // Actions act on the profile in use, which is this window's (it's key when clicked).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func downloadEvent(_ note: Notification) {
        guard services.keyBrowserWindow === self, let text = note.userInfo?["text"] as? String else { return }
        showToast(text, duration: 4)
    }

    // MARK: - TabStripDelegate

    func tabStrip(_ strip: TabStripView, didSelect index: Int) { activate(index: index) }
    func tabStrip(_ strip: TabStripView, didClose index: Int) { closeTab(at: index) }
    func tabStripNewTab(_ strip: TabStripView) { openBlankTab() }

    func tabStrip(_ strip: TabStripView, tooltipFor index: Int) -> String {
        guard tabs.indices.contains(index) else { return "" }
        let tab = tabs[index]
        // Only this tab's RAM usage.
        guard let web = tab.webView else {
            return tab.freedBytes > 0 ? String(localized: "Sleeping: freed about \(ProcessMemory.format(tab.freedBytes))")
                                      : String(localized: "RAM: 0 MB (sleeping)")
        }
        var lines: [String] = []
        if let pid = web.askaraProcessID, let bytes = ProcessMemory.footprint(pid: pid) {
            lines.append(String(localized: "RAM: \(ProcessMemory.format(bytes))"))
        } else {
            lines.append(String(localized: "RAM: unknown"))
        }
        if tab.isPinned {
            lines.append(String(localized: "Pinned: never sleeps"))
        } else if keepsAwake(tab) {
            lines.append(String(localized: "Memory Saver exception: never sleeps"))
        }
        return lines.joined(separator: "\n")
    }

    func tabStrip(_ strip: TabStripView, menuFor index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        return tabMenu(for: tabs[index])
    }

    func tabStrip(_ strip: TabStripView, toggleMuteAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        setMuted(!tabs[index].isMuted, tab: tabs[index])
    }

    // MARK: - Dragging tabs

    func tabStrip(_ strip: TabStripView, moveTabFrom from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        var order = tabs
        order.insert(order.remove(at: from), at: to)
        reorder(order)
        tabsChanged()
    }

    func tabStrip(_ strip: TabStripView, dragIDForTabAt index: Int) -> String? {
        // Private windows each have their own temporary data store, so their tabs stay put.
        guard tabs.indices.contains(index), !isPrivate else { return nil }
        return tabs[index].id.uuidString
    }

    /// The window currently holding a dragged tab.
    private func draggedTab(_ id: String) -> (window: BrowserWindowController, tab: Tab)? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        for window in services.windows {
            if let tab = window.tabs.first(where: { $0.id == uuid }) { return (window, tab) }
        }
        return nil
    }

    func tabStrip(_ strip: TabStripView, canAcceptTab id: String) -> Bool {
        // Only between windows of the same profile: the page keeps that profile's logins.
        guard let source = draggedTab(id)?.window else { return false }
        return !isPrivate && !source.isPrivate && source.profile === profile
    }

    func tabStrip(_ strip: TabStripView, acceptTab id: String, at index: Int) -> Bool {
        guard tabStrip(strip, canAcceptTab: id), let (source, tab) = draggedTab(id),
              let oldIndex = source.tabs.firstIndex(where: { $0 === tab }) else { return false }
        if source === self {
            // Dropped back on its own strip.
            let target = index > oldIndex ? index - 1 : index
            tabStrip(strip, moveTabFrom: oldIndex, to: clampedIndex(target, pinned: tab.isPinned, excluding: tab))
            return true
        }
        source.removeTabForMove(tab)
        adopt(tab, at: index, from: source, oldIndex: oldIndex)
        return true
    }

    func tabStrip(_ strip: TabStripView, detachTab id: String, to screenPoint: NSPoint) {
        guard !isPrivate, let (source, tab) = draggedTab(id),
              let oldIndex = source.tabs.firstIndex(where: { $0 === tab }) else { return }
        let topLeft = NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 20)
        if source.tabs.count == 1 {
            // The window's only tab: just move the window there.
            source.window?.setFrameTopLeftPoint(topLeft)
            return
        }
        let target = services.makeWindow(profile: profile)
        if let window = target.window, let source = source.window {
            window.setContentSize(source.contentLayoutRect.size)
            window.setFrameTopLeftPoint(topLeft)
        }
        source.removeTabForMove(tab)
        target.adopt(tab, at: 0, from: source, oldIndex: oldIndex)
    }

    /// Position among pinned tabs for a pinned tab, after them otherwise.
    private func clampedIndex(_ index: Int, pinned: Bool, excluding tab: Tab? = nil) -> Int {
        let others = tabs.filter { $0 !== tab }
        let pinnedCount = others.filter(\.isPinned).count
        return pinned ? min(max(0, index), pinnedCount) : min(max(pinnedCount, index), others.count)
    }

    /// Takes a tab out of this window without closing its page (it's moving to another window).
    fileprivate func removeTabForMove(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.webView?.removeFromSuperview()
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeIndex = -1
            window?.close()
            return
        }
        if index < activeIndex {
            activeIndex -= 1
            refreshTabStrip()
        } else if index == activeIndex {
            activeIndex = -1
            activate(index: min(index, tabs.count - 1))
        } else {
            refreshTabStrip()
        }
        sessionChanged()
    }

    /// Takes over a tab (with its live page, history, and scroll position) from another window.
    fileprivate func adopt(_ tab: Tab, at index: Int, from source: BrowserWindowController, oldIndex: Int) {
        tab.owner = self
        // Re-point delegates and observers at this window.
        if let web = tab.webView { attach(web, to: tab) }
        let position = clampedIndex(index, pinned: tab.isPinned)
        tabs.insert(tab, at: position)
        if position <= activeIndex { activeIndex += 1 }
        extensionController?.didMoveTab(tab, from: oldIndex, in: source)
        activate(index: position)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        sessionChanged()
    }

    // MARK: - Tab lifecycle

    /// New tab from ⌘T / the + button: shows the search engine's page (or the home page), with an
    /// empty, focused address bar so the user can type right away.
    func openBlankTab() {
        focusAddressBarOnActivate = true
        newTab(url: services.homeURL)
        activeTab?.hidesHomeAddress = true
        activeTab?.refocusAddressAfterLoad = true
        addressField.stringValue = ""
    }

    /// The new tab's page has rendered: empty, focused address bar, unless the user already typed
    /// there or clicked into the page.
    private func refocusAddressBarIfNeeded(_ tab: Tab) {
        guard tab.refocusAddressAfterLoad, tab === activeTab, window?.isKeyWindow == true else { return }
        tab.refocusAddressAfterLoad = false
        guard tab.hidesHomeAddress else { return }
        let editing = addressField.currentEditor() != nil
        if editing, !addressField.stringValue.isEmpty { return } // already typing: leave it alone
        if !editing, let web = tab.webView, window?.firstResponder !== web,
           window?.firstResponder !== window { return } // focus moved elsewhere on purpose
        addressField.stringValue = ""
        focusAddressBar(nil)
    }

    /// Address bar text for a tab. Empty on a new tab's start page.
    private func addressText(for tab: Tab?) -> String {
        guard let tab else { return "" }
        if tab.hidesHomeAddress {
            if tab.homeLandingURL == nil || tab.displayURL == tab.homeLandingURL { return "" }
            // Moved on to another page (link, search, pushState): show addresses from now on.
            tab.hidesHomeAddress = false
        }
        return AddressParser.displayString(for: tab.displayURL)
    }

    /// `activate: false` opens the tab in the background, asleep (using no RAM).
    func newTab(url: URL?, activate: Bool = true) {
        if activate || tabs.isEmpty {
            insertTab(url: url, at: tabs.count, activate: true)
        } else {
            insertTab(url: url, at: activeIndex + 1, activate: false)
            showToast(String(localized: "Opened in background tab (sleeping until clicked)"), duration: 2)
        }
    }

    /// The only path for adding tabs, so extensions are always notified.
    @discardableResult
    func insertTab(url: URL?, at index: Int, activate: Bool, webView: WKWebView? = nil) -> Tab {
        // nil = empty tab (e.g. ⌘T, or an extension opening a tab without an address).
        let tab = Tab(url: url)
        tab.owner = self
        if let webView { attach(webView, to: tab) }
        // New tabs never go between pinned tabs.
        let firstUnpinned = tabs.firstIndex { !$0.isPinned } ?? tabs.count
        let position = min(max(firstUnpinned, index), tabs.count)
        tabs.insert(tab, at: position)
        if position <= activeIndex { activeIndex += 1 }
        extensionController?.didOpenTab(tab)
        if activate || activeIndex < 0 {
            self.activate(index: position)
        } else {
            refreshTabStrip()
        }
        sessionChanged()
        return tab
    }

    // MARK: - Tab access for extensions

    /// Extension controller, for normal windows only. Private windows are invisible to extensions.
    var extensionController: WKWebExtensionController? {
        isPrivate ? nil : profile.extensions.controller
    }

    var allTabs: [Tab] { tabs }
    var loadedWebViews: [WKWebView] { tabs.compactMap(\.webView) }
    var currentTab: Tab? { activeTab }
    func index(of tab: Tab) -> Int { tabs.firstIndex { $0 === tab } ?? NSNotFound }
    func isActive(_ tab: Tab) -> Bool { activeTab === tab }

    func activate(tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        activate(index: index)
        showWindow(nil)
    }

    func close(tab: Tab) {
        if let index = tabs.firstIndex(where: { $0 === tab }) { closeTab(at: index) }
    }

    /// Loads a URL in a given tab. A sleeping tab just gets its URL replaced and loads when opened.
    func load(_ url: URL, in tab: Tab) {
        if tab === activeTab { return load(url) }
        tab.hidesHomeAddress = false
        tab.url = url
        tab.displayURL = url
        tab.interactionState = nil
        tab.webView?.load(URLRequest(url: url))
    }

    private func tabChanged(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        extensionController?.didChangeTabProperties(properties, for: tab)
    }

    /// Loads a URL in the active tab (or a new tab if there is none).
    func load(_ url: URL) {
        guard let tab = activeTab else { return newTab(url: url) }
        tab.hidesHomeAddress = false
        tab.url = url
        // The typed address stays visible until the final page (after redirects) is done.
        tab.displayURL = url
        tab.interactionState = nil
        let web = tab.webView ?? wake(tab, loadURL: false)
        web.load(URLRequest(url: url))
        window?.makeFirstResponder(web)
    }

    func restore(_ saved: SessionState.SavedWindow) {
        tabs = saved.tabs.map { saved in
            let tab = Tab(url: saved.url, title: saved.title)
            tab.owner = self
            tab.isPinned = saved.isPinned ?? false
            tab.isMuted = saved.isMuted ?? false
            return tab
        }
        tabs.forEach { extensionController?.didOpenTab($0) }
        let active = tabs.indices.contains(saved.activeIndex) ? tabs[saved.activeIndex] : nil
        normalizeTabOrder()
        activate(index: active.flatMap { a in tabs.firstIndex { $0 === a } } ?? 0)
        // Pinned tabs are loaded at launch, like Chrome, so mail/chat apps are ready.
        for tab in tabs where tab.isPinned && tab.webView == nil { wake(tab) }
    }

    func savedState() -> SessionState.SavedWindow {
        var saved: [SessionState.SavedTab] = []
        var active = 0
        for (index, tab) in tabs.enumerated() {
            // Temporary extension pages (e.g. passkey confirmation) are not restored.
            guard let url = tab.webView?.url ?? tab.url, url.scheme != "webkit-extension" else { continue }
            if index == activeIndex { active = saved.count }
            saved.append(.init(url: url, title: tab.title, isPinned: tab.isPinned, isMuted: tab.isMuted))
        }
        return .init(tabs: saved, activeIndex: active)
    }

    private func sessionChanged() {
        if !isPrivate { profile.scheduleSessionSave() }
    }

    private func activate(index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index != activeIndex { hideFindBar(nil) }
        let previous = activeTab
        previous?.lastActive = Date()
        previous?.webView?.removeFromSuperview()

        activeIndex = index
        let tab = tabs[index]
        tab.lastActive = Date()
        let webView = tab.webView ?? wake(tab)
        if previous !== tab { extensionController?.didActivateTab(tab, previousActiveTab: previous) }
        refreshExtensionButtons()

        contentView.addSubview(webView)
        layoutWebView(of: tab)
        // Fill the address bar before focusing: while editing, updateToolbar won't overwrite it,
        // so the previous tab's URL could linger.
        addressField.abortEditing()
        addressField.stringValue = addressText(for: tab)
        if focusAddressBarOnActivate {
            focusAddressBarOnActivate = false
            focusAddressBar(nil)
        } else {
            window?.makeFirstResponder(tab.url == nil ? addressField : webView)
        }

        refreshTabStrip()
        updateToolbar()
        loadingBar.update(loading: webView.isLoading, progress: webView.estimatedProgress, animated: false)
        // Tab count and memory limits are enforced across all windows right away.
        services.enforceHibernation()
    }

    /// Creates a WebView for a tab (new or sleeping). If the tab slept, back/forward
    /// history and scroll position are restored via `interactionState`.
    @discardableResult
    private func wake(_ tab: Tab, loadURL: Bool = true) -> WKWebView {
        let configuration = (isPrivate ? nil : profile.extensions.webViewConfiguration(for: tab.url))
            ?? makeConfiguration()
        let webView = AskaraWebView(frame: contentView.bounds, configuration: configuration)
        attach(webView, to: tab)
        guard loadURL else { return webView }
        if let state = tab.interactionState {
            webView.interactionState = state
            tab.interactionState = nil
        } else if let url = tab.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    private func attach(_ webView: WKWebView, to tab: Tab) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.pageZoom = tab.zoom
        // Inspectable from Web Inspector (Develop menu) and from Safari > Develop.
        webView.isInspectable = true
        (webView as? AskaraWebView)?.browser = self
        tab.webView = webView
        // A tab woken from sleep keeps its Device Mode, Appearance, and mute settings.
        webView.customUserAgent = tab.device?.userAgent
        webView.appearance = tab.colorScheme.flatMap(NSAppearance.init(named:))
        if tab.isMuted { webView.askaraSetMuted(true) }

        tab.observations = [
            webView.observe(\.title) { [weak self, weak tab] web, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, let title = web.title, !title.isEmpty else { return }
                    tab.title = title
                    if !self.isPrivate, let url = web.url { self.profile.updateHistoryTitle(title, for: url) }
                    self.tabChanged(tab, .title)
                    self.refreshTabStrip()
                    self.updateToolbar()
                }
            },
            webView.observe(\.url) { [weak self, weak tab] web, _ in
                MainActor.assumeIsolated {
                    guard let tab, let url = web.url else { return }
                    tab.url = url
                    self?.tabChanged(tab, .URL)
                    // During navigation the URL can jump due to redirects: don't show it.
                    // The address bar updates in didCommit (final page starts showing). Without navigation
                    // (e.g. SPA via pushState), show it immediately.
                    if !web.isLoading {
                        tab.displayURL = url
                        self?.updateToolbar()
                    }
                }
            },
            webView.observe(\.isLoading) { [weak self, weak tab] web, _ in
                MainActor.assumeIsolated {
                    // Navigation failed before commit: revert to the URL of the page being shown.
                    if !web.isLoading, let tab, let url = web.url { tab.displayURL = url }
                    if let tab { self?.tabChanged(tab, .loading) }
                    // estimatedProgress hits 1.0 before isLoading becomes false, so the bar can only
                    // be hidden from here.
                    if let self, let tab, tab === self.activeTab {
                        self.loadingBar.update(loading: web.isLoading, progress: web.estimatedProgress)
                    }
                    self?.updateToolbar()
                    self?.refreshTabStrip()
                }
            },
            webView.observe(\.estimatedProgress) { [weak self, weak tab] web, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab === self.activeTab else { return }
                    self.loadingBar.update(loading: web.isLoading, progress: web.estimatedProgress)
                }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateToolbar() }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateToolbar() }
            },
            webView.observe(\.cameraCaptureState) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshTabStrip() }
            },
            webView.observe(\.microphoneCaptureState) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshTabStrip() }
            },
        ]
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = UserAgent.applicationName
        // No video/audio autoplay: saves RAM, CPU, and battery.
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Popups only from user clicks.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        // Extensions (e.g. Bitwarden) inject their scripts via this controller. Not for private windows.
        if let extensionController { config.webExtensionController = extensionController }
        if let list = services.ruleList { config.userContentController.add(list) }
        // Detect form input in all frames (including iframes) so tabs with input aren't put to sleep.
        config.userContentController.add(WeakScriptHandler(self), name: FormGuard.handlerName)
        config.userContentController.addUserScript(WKUserScript(
            source: FormGuard.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // Link/image/text under the cursor for the context menu.
        config.userContentController.add(WeakScriptHandler(self), name: ContextMenuProbe.handlerName)
        config.userContentController.addUserScript(WKUserScript(
            source: ContextMenuProbe.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // "Inspect Element" in the context menu.
        DevTools.enable(on: config)
        if !Passkey.isAvailable {
            // Without the entitlement, WebKit always rejects passkeys. Detect it so we can explain.
            config.userContentController.add(WeakScriptHandler(self), name: "askaraPasskey")
            config.userContentController.addUserScript(WKUserScript(
                source: Passkey.detectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        return config
    }

    func applyRuleList(_ list: WKContentRuleList) {
        for tab in tabs {
            guard let controller = tab.webView?.configuration.userContentController else { continue }
            controller.removeAllContentRuleLists()
            controller.add(list)
        }
    }

    // MARK: - Hibernation

    /// Snapshots for the global policy. Shared process memory is counted only once.
    func hibernationSnapshots(seenProcesses: inout Set<pid_t>) -> [TabSnapshot] {
        tabs.enumerated().map { index, tab in
            var bytes: UInt64 = 0
            if let pid = tab.webView?.askaraProcessID, seenProcesses.insert(pid).inserted {
                bytes = ProcessMemory.footprint(pid: pid) ?? 0
            }
            // A muted tab's sound doesn't matter to the user, but a call (camera/mic) still does.
            let audible = tab.isMuted ? (tab.webView?.askaraIsCapturingMedia ?? false) : tab.isPlayingAudio
            return TabSnapshot(id: tab.id, lastActive: tab.lastActive, isLoaded: tab.webView != nil,
                               isActive: index == activeIndex, memoryBytes: bytes,
                               isPlayingAudio: audible, hasUnsavedInput: tab.hasUnsavedInput,
                               keepAwake: keepsAwake(tab))
        }
    }

    /// Pinned tabs and Memory Saver exception sites never sleep.
    private func keepsAwake(_ tab: Tab) -> Bool {
        if tab.isPinned { return true }
        guard let host = (tab.webView?.url ?? tab.url)?.host else { return false }
        return services.preferences.keepsAwake(host: host)
    }

    /// `force`: the user asked (Sleep Background Tabs), so exceptions and pinned tabs aren't spared.
    /// `reasons`: why each tab sleeps, for the log.
    func hibernate(tabIDs: Set<UUID>, force: Bool = false, reasons: [UUID: HibernationReason] = [:]) {
        var changed = false
        for (index, tab) in tabs.enumerated()
        where index != activeIndex && tabIDs.contains(tab.id) && !tab.hasUnsavedInput && (force || !keepsAwake(tab))
            && tab.webView != nil {
            tab.freedBytes = services.exclusiveFootprint(of: tab.webView)
            let reason = force ? "manual" : (reasons[tab.id]?.rawValue ?? "collapsed")
            Log.notice("Askara: tab slept (\(reason), idle \(Int(Date().timeIntervalSince(tab.lastActive)))s, "
                       + "\(ProcessMemory.format(tab.freedBytes))): \(tab.webView?.url?.host ?? tab.url?.host ?? "?")")
            services.recordFreed(tab.freedBytes)
            dropWebView(of: tab)
            changed = true
        }
        if changed { refreshTabStrip() }
    }

    /// "Sleep Background Tabs" menu: every tab except the active one (and pinned tabs) in this window.
    @objc func hibernateNowAction(_ sender: Any?) {
        let before = tabs.filter { $0.webView != nil }.count
        hibernate(tabIDs: Set(tabs.filter { !$0.isPinned }.map(\.id)), force: true)
        let slept = before - tabs.filter { $0.webView != nil }.count
        showToast(slept > 0 ? String(localized: "\(slept) tabs put to sleep") : String(localized: "No active background tabs"), duration: 2)
    }

    private func dropWebView(of tab: Tab) {
        guard let web = tab.webView else { return }
        if let url = web.url { tab.url = url }
        // Keep back/forward history and scroll position so the tab feels intact when woken.
        tab.interactionState = web.interactionState
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
        tab.webView = nil
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if !isPrivate, let url = tab.webView?.url ?? tab.url {
            profile.recentlyClosed.push(ClosedTab(url: url, title: tab.title))
        }
        dropWebView(of: tab)
        tabs.remove(at: index)
        extensionController?.didCloseTab(tab, windowIsClosing: tabs.isEmpty)
        if tabs.isEmpty {
            activeIndex = -1
            window?.close()
            return
        }
        if index < activeIndex {
            activeIndex -= 1
            refreshTabStrip()
        } else if index == activeIndex {
            activeIndex = -1 // old tab is already detached; don't touch it again
            activate(index: min(index, tabs.count - 1))
        } else {
            refreshTabStrip()
        }
        sessionChanged()
    }

    // MARK: - Tab order, pinning, muting

    /// Replaces the tab order, keeping the active tab and telling extensions about moves.
    private func reorder(_ newOrder: [Tab]) {
        guard newOrder.map(ObjectIdentifier.init) != tabs.map(ObjectIdentifier.init) else { return }
        let active = activeTab
        let old = tabs
        tabs = newOrder
        if let active, let index = tabs.firstIndex(where: { $0 === active }) { activeIndex = index }
        guard let controller = extensionController else { return }
        for (newIndex, tab) in tabs.enumerated() {
            if let oldIndex = old.firstIndex(where: { $0 === tab }), oldIndex != newIndex {
                controller.didMoveTab(tab, from: oldIndex, in: self)
            }
        }
    }

    /// Pinned tabs first, otherwise in the same order.
    private func normalizeTabOrder() {
        reorder(tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned })
    }

    /// The tab a menu item acts on: the right-clicked tab, or the active tab (main menu).
    private func targetTab(_ sender: Any?) -> Tab? {
        ((sender as? NSMenuItem)?.representedObject as? Tab).flatMap { t in tabs.contains { $0 === t } ? t : nil }
            ?? activeTab
    }

    private func tabsChanged() {
        refreshTabStrip()
        sessionChanged()
    }

    func setPinned(_ pinned: Bool, tab: Tab) {
        guard tab.isPinned != pinned, tabs.contains(where: { $0 === tab }) else { return }
        var order = tabs.filter { $0 !== tab }
        let pinnedCount = order.filter(\.isPinned).count
        tab.isPinned = pinned
        // Pinning puts the tab at the end of the pinned tabs; unpinning puts it right after them.
        order.insert(tab, at: pinnedCount)
        reorder(order)
        normalizeTabOrder()
        tabChanged(tab, .pinned)
        tabsChanged()
        // A pinned tab never sleeps, so load it now.
        if pinned, tab.webView == nil { wake(tab); refreshTabStrip() }
    }

    func setMuted(_ muted: Bool, tab: Tab) {
        guard tab.isMuted != muted else { return }
        tab.isMuted = muted
        tab.webView?.askaraSetMuted(muted)
        tabChanged(tab, .muted)
        refreshTabStrip()
        sessionChanged()
    }

    @objc func togglePinTabAction(_ sender: Any?) {
        guard let tab = targetTab(sender) else { return }
        setPinned(!tab.isPinned, tab: tab)
    }

    @objc func toggleMuteTabAction(_ sender: Any?) {
        guard let tab = targetTab(sender) else { return }
        setMuted(!tab.isMuted, tab: tab)
    }

    @objc func duplicateTabAction(_ sender: Any?) {
        guard let tab = targetTab(sender), let url = tab.webView?.url ?? tab.url,
              let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let copy = insertTab(url: url, at: index + 1, activate: true)
        copy.zoom = tab.zoom
        copy.webView?.pageZoom = tab.zoom
    }

    @objc func reloadTabAction(_ sender: Any?) {
        guard let tab = targetTab(sender) else { return }
        if let web = tab.webView { web.reload() } else { activate(tab: tab) }
    }

    @objc func closeTargetTabAction(_ sender: Any?) {
        guard let tab = targetTab(sender) else { return }
        close(tab: tab)
    }

    /// Closes every other tab except pinned ones (they're meant to stay).
    @objc func closeOtherTabsAction(_ sender: Any?) {
        guard let keep = targetTab(sender) else { return }
        activate(tab: keep)
        for tab in tabs.reversed() where tab !== keep && !tab.isPinned { close(tab: tab) }
    }

    // MARK: - Tab menu

    private func menuItem(_ title: String, _ action: Selector, _ object: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    private func tabMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "Reload"), #selector(reloadTabAction(_:)), tab))
        menu.addItem(menuItem(String(localized: "Duplicate Tab"), #selector(duplicateTabAction(_:)), tab))
        menu.addItem(menuItem(tab.isPinned ? String(localized: "Unpin Tab") : String(localized: "Pin Tab"),
                              #selector(togglePinTabAction(_:)), tab))
        menu.addItem(menuItem(tab.isMuted ? String(localized: "Unmute Tab") : String(localized: "Mute Tab"),
                              #selector(toggleMuteTabAction(_:)), tab))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Close Tab"), #selector(closeTargetTabAction(_:)), tab))
        menu.addItem(menuItem(String(localized: "Close Other Tabs"), #selector(closeOtherTabsAction(_:)), tab))
        return menu
    }

    // MARK: - Memory Saver

    /// View > Keep This Site Awake: the active site's tabs never sleep (Memory Saver exception).
    @objc func toggleKeepAwakeAction(_ sender: Any?) {
        guard let host = activeSiteHost else { return }
        let site = SiteSettings.key(for: host)
        let awake = services.preferences.keepsAwake(host: host)
        services.updatePreferences { prefs in
            if awake {
                // Also covers an exception saved for a parent domain.
                SiteSettings.candidates(for: host).forEach { prefs.removeKeepAwakeSite($0) }
            } else {
                prefs.addKeepAwakeSite(site)
            }
        }
        showToast(awake ? String(localized: "\(site) can sleep again") : String(localized: "\(site) will stay awake"),
                  duration: 2)
    }

    // MARK: - Actions: tabs & navigation

    @objc func newTabAction(_ sender: Any?) { openBlankTab() }
    @objc func closeTabAction(_ sender: Any?) { closeTab(at: activeIndex) }
    @objc func backAction(_ sender: Any?) { activeTab?.webView?.goBack() }
    @objc func forwardAction(_ sender: Any?) { activeTab?.webView?.goForward() }

    /// Data for the Tab menu: open tabs only.
    var tabMenuEntries: [(title: String, isActive: Bool, isSleeping: Bool)] {
        tabs.enumerated().map { ($1.title, $0 == activeIndex, $1.webView == nil) }
    }

    @objc func selectTabFromMenu(_ sender: NSMenuItem) { activate(index: sender.tag) }

    /// ⌘1–⌘8 select the nth tab, ⌘9 selects the last tab.
    @objc func selectTabNumberAction(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        activate(index: sender.tag >= 9 ? tabs.count - 1 : min(sender.tag - 1, tabs.count - 1))
    }

    @objc func reloadAction(_ sender: Any?) {
        guard let web = activeTab?.webView else { return }
        if web.isLoading { web.stopLoading() } else { web.reload() }
    }

    @objc func nextTabAction(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        activate(index: (activeIndex + 1) % tabs.count)
    }

    @objc func previousTabAction(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        activate(index: (activeIndex - 1 + tabs.count) % tabs.count)
    }

    @objc func focusAddressBar(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressSubmitted(_ sender: NSTextField) {
        if let chosen = suggestions.isVisible ? suggestions.selected : nil { return chooseSuggestion(chosen) }
        suggestions.hide()
        guard let url = AddressParser.url(from: sender.stringValue,
                                          searchTemplate: services.searchEngine.searchTemplate) else { return }
        load(url)
    }

    private func chooseSuggestion(_ suggestion: AddressSuggestion) {
        suggestions.hide()
        addressField.stringValue = AddressParser.displayString(for: suggestion.url)
        load(suggestion.url)
    }

    private func updateSuggestions() {
        typedAddress = addressField.stringValue
        let found = AddressSuggester.suggestions(for: typedAddress, history: profile.history.entries,
                                                 bookmarks: profile.bookmarks.bookmarks)
        if found.isEmpty { suggestions.hide() } else { suggestions.show(found, below: addressField) }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        updateSuggestions()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        // Let a click on a suggestion row land before the panel disappears.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.addressField.currentEditor() == nil else { return }
            self.suggestions.hide()
        }
    }

    /// ⌘D / star: adds the page and shows a popover to rename or pick a folder, like Chrome.
    /// Already bookmarked: the popover opens for editing (Remove is there).
    @objc func toggleBookmarkAction(_ sender: Any?) {
        guard let tab = activeTab, let url = tab.webView?.url ?? tab.url else { return }
        let existing = profile.bookmarks.node(for: url)
        let id = existing?.id ?? profile.editBookmarks { $0.add(url: url, title: tab.title)?.id }
        guard let id else { return }
        if window?.isVisible == true, !bookmarkButton.isHiddenOrHasHiddenAncestor {
            BookmarkPopover.show(profile: profile, id: id, relativeTo: bookmarkButton)
        } else {
            showToast(String(localized: "Bookmark added: \(tab.title)"), duration: 2)
        }
    }

    @objc func openInSafariAction(_ sender: Any?) {
        guard let url = activeTab?.url,
              let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        else { return }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Actions: context menu

    @objc func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        newTab(url: url)
    }

    @objc func openLinkInBackgroundTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        newTab(url: url, activate: false)
    }

    @objc func openLinkInPrivateWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.makeWindow(profile: profile, isPrivate: true).newTab(url: url)
    }

    @objc func searchSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let url = services.searchEngine.searchURL(for: text) else { return }
        newTab(url: url)
    }

    @objc func copyPageAddress(_ sender: Any?) {
        guard let url = activeTab?.displayURL ?? activeTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast(String(localized: "Address copied"), duration: 1.5)
    }

    // MARK: - Actions: Develop

    @objc func showWebInspectorAction(_ sender: Any?) { openDevTools(.inspector) }
    @objc func showConsoleAction(_ sender: Any?) { openDevTools(.console) }
    @objc func showResourcesAction(_ sender: Any?) { openDevTools(.resources) }
    @objc func selectElementAction(_ sender: Any?) { openDevTools(.elementSelection) }

    private func openDevTools(_ panel: DevTools.Panel) {
        guard let web = activeTab?.webView else { return }
        if !DevTools.open(panel, for: web) {
            showToast(String(localized: "Web Inspector isn't available on this macOS version. Use Safari > Develop > Askara."), duration: 5)
        }
    }

    @objc func viewSourceAction(_ sender: Any?) {
        guard let url = activeTab?.webView?.url, ["http", "https"].contains(url.scheme ?? "") else { return }
        activeTab?.webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else { return }
            SourceWindow.show(html: html, url: url, relativeTo: self.window)
        }
    }

    @objc func reloadIgnoringCacheAction(_ sender: Any?) { activeTab?.webView?.reloadFromOrigin() }

    /// Host of the active page, for per-site settings. nil on non-web pages.
    var activeSiteHost: String? {
        guard let url = activeTab?.webView?.url ?? activeTab?.url, ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Blocks or allows JavaScript on the current site (and its subdomains). Saved, like Chrome's site settings.
    @objc func toggleSiteJavaScriptAction(_ sender: Any?) {
        guard let host = activeSiteHost else { return }
        let block = !services.siteSettings.isJavaScriptBlocked(host: host)
        services.setJavaScriptBlocked(block, host: host)
        let site = SiteSettings.key(for: host)
        showToast(block ? String(localized: "JavaScript blocked on \(site)") : String(localized: "JavaScript allowed on \(site)"),
                  duration: 3)
        // The setting applies on the next navigation: reload every open tab of this site.
        services.windows.forEach { $0.reloadTabs(relatedTo: host) }
    }

    func reloadTabs(relatedTo host: String) {
        for tab in tabs {
            guard let web = tab.webView, let tabHost = web.url?.host, SiteSettings.isRelated(tabHost, host) else { continue }
            web.reload()
        }
    }

    // MARK: - Actions: custom site code

    @objc func editSiteCodeAction(_ sender: Any?) {
        guard let host = activeSiteHost else { return }
        SiteCodeWindowController.show(host: host, relativeTo: window) { host, code, reload in
            let services = BrowserServices.shared
            services.setCustomization(code, host: host)
            services.windows.forEach { $0.siteCodeChanged(host: host, reload: reload) }
            services.keyBrowserWindow?.showToast(code.isEmpty ? String(localized: "Custom code removed for \(host)")
                                                              : String(localized: "Custom code saved for \(host)"),
                                                 duration: 2)
        }
    }

    /// CSS updates live; JavaScript only runs again on reload (re-running it could double its effects).
    func siteCodeChanged(host: String, reload: Bool) {
        for tab in tabs {
            guard let web = tab.webView, let tabHost = web.url?.host, SiteSettings.isRelated(tabHost, host) else { continue }
            if reload { web.reload() } else { applySiteCSS(to: web) }
        }
    }

    private func siteCustomizations(for web: WKWebView) -> [SiteCustomization]? {
        guard let url = web.url, ["http", "https"].contains(url.scheme ?? ""), let host = url.host else { return nil }
        return services.siteSettings.customizations(matching: host)
    }

    private func applySiteCSS(to web: WKWebView) {
        guard let list = siteCustomizations(for: web) else { return }
        let css = list.map(\.css).joined(separator: "\n")
        // Removing also covers CSS deleted in the editor while the page is open.
        web.evaluateJavaScript(SiteCodeScript.css(css) ?? SiteCodeScript.removeCSS)
    }

    private func applySiteJavaScript(to web: WKWebView) {
        guard let list = siteCustomizations(for: web) else { return }
        for code in list.map(\.javaScript) where !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            web.evaluateJavaScript(SiteCodeScript.javaScript(code)) { [weak self, weak web] _, error in
                // Syntax errors land here; runtime errors are logged to the page console.
                guard let self, let error, let web, web === self.activeTab?.webView else { return }
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    ?? error.localizedDescription
                self.showToast(String(localized: "Custom JavaScript error: \(message)"), duration: 5)
            }
        }
    }

    // MARK: - Actions: device mode & appearance

    /// Menu item tag: 0 = off, n = DevicePreset.all[n - 1].
    @objc func deviceModeAction(_ sender: NSMenuItem) {
        guard let tab = activeTab else { return }
        let presets = DevicePreset.all
        let device = presets.indices.contains(sender.tag - 1) ? presets[sender.tag - 1] : nil
        guard device != tab.device else { return }
        let userAgentChanged = device?.userAgent != tab.device?.userAgent
        tab.device = device
        tab.webView?.customUserAgent = device?.userAgent
        layoutWebView(of: tab)
        // Servers pick mobile/desktop pages from the user agent, so the page must be fetched again.
        if userAgentChanged { tab.webView?.reload() }
        showToast(device.map { String(localized: "Device Mode: \($0.name)") } ?? String(localized: "Device Mode off"),
                  duration: 2)
    }

    @objc func rotateDeviceAction(_ sender: Any?) {
        guard let tab = activeTab, tab.device != nil else { return }
        tab.deviceLandscape.toggle()
        layoutWebView(of: tab)
    }

    /// Menu item tag: 0 = system, 1 = light, 2 = dark. Changes `prefers-color-scheme` live, no reload needed.
    @objc func colorSchemeAction(_ sender: NSMenuItem) {
        guard let tab = activeTab else { return }
        let schemes: [NSAppearance.Name?] = [nil, .aqua, .darkAqua]
        tab.colorScheme = schemes.indices.contains(sender.tag) ? schemes[sender.tag] : nil
        tab.webView?.appearance = tab.colorScheme.flatMap(NSAppearance.init(named:))
    }

    /// Full size normally. In Device Mode: the device's size, centered, scaled down to fit the window.
    /// `pageZoom` is scaled by the same factor, so the page still lays out at the device's CSS width.
    private func layoutWebView(of tab: Tab) {
        guard let web = tab.webView, web.superview === contentView else { return }
        guard let device = tab.device else {
            web.autoresizingMask = [.width, .height]
            web.frame = contentView.bounds
            web.pageZoom = tab.zoom
            contentView.layer?.backgroundColor = nil
            return
        }
        let size = device.size(landscape: tab.deviceLandscape)
        let width = CGFloat(size.width), height = CGFloat(size.height)
        let available = contentView.bounds.insetBy(dx: 16, dy: 16)
        let scale = max(0.25, min(1, available.width / width, available.height / height))
        let frameSize = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        web.autoresizingMask = []
        web.frame = NSRect(x: ((contentView.bounds.width - frameSize.width) / 2).rounded(),
                           y: ((contentView.bounds.height - frameSize.height) / 2).rounded(),
                           width: frameSize.width, height: frameSize.height)
        web.pageZoom = scale * tab.zoom
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }

    @objc private func contentViewResized(_ note: Notification) {
        guard let tab = activeTab, tab.device != nil else { return }
        layoutWebView(of: tab)
    }

    // MARK: - Actions: zoom & print

    @objc func zoomInAction(_ sender: Any?) { setZoom(ZoomLevels.zoomIn(from: activeTab?.zoom ?? 1)) }
    @objc func zoomOutAction(_ sender: Any?) { setZoom(ZoomLevels.zoomOut(from: activeTab?.zoom ?? 1)) }
    @objc func zoomResetAction(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: Double) {
        guard let tab = activeTab else { return }
        tab.zoom = zoom
        // Device Mode combines zoom with its fit-to-window scale.
        if tab.device != nil { layoutWebView(of: tab) } else { tab.webView?.pageZoom = zoom }
        showToast(String(localized: "Zoom \(ZoomLevels.label(zoom))"), duration: 1.5)
    }

    @objc func printPageAction(_ sender: Any?) {
        guard let web = activeTab?.webView, let window else { return }
        let operation = web.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = web.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Find in page

    @objc func showFindBar(_ sender: Any?) {
        findBar.isHidden = false
        window?.makeFirstResponder(findField)
        findField.selectText(nil)
    }

    @objc func hideFindBar(_ sender: Any?) {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findStatus.stringValue = ""
        if let web = activeTab?.webView {
            web.evaluateJavaScript("window.getSelection().removeAllRanges()")
            window?.makeFirstResponder(web)
        }
    }

    @objc func findNextAction(_ sender: Any?) { find(backwards: false) }
    @objc func findPreviousAction(_ sender: Any?) { find(backwards: true) }
    @objc private func findFieldChanged(_ sender: Any?) { find(backwards: false) }

    private func find(backwards: Bool) {
        let query = findField.stringValue
        guard let web = activeTab?.webView, !query.isEmpty else {
            findStatus.stringValue = ""
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        web.find(query, configuration: config) { [weak self] result in
            self?.findStatus.stringValue = result.matchFound ? "" : String(localized: "Not found")
        }
    }

    /// Enter/Shift+Enter and Esc in the find bar; Esc in the address bar restores the URL.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === findField {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideFindBar(nil)
                return true
            default:
                return false
            }
        }
        if control === addressField, suggestions.isVisible {
            let delta: Int? = switch selector {
            case #selector(NSResponder.moveDown(_:)): 1
            case #selector(NSResponder.moveUp(_:)): -1
            default: nil
            }
            if let delta {
                let chosen = suggestions.moveSelection(by: delta)
                addressField.stringValue = chosen?.url.absoluteString ?? typedAddress
                textView.moveToEndOfDocument(nil)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                // First Esc closes the list and restores what was typed; the second restores the URL.
                suggestions.hide()
                addressField.stringValue = typedAddress
                return true
            }
        }
        if control === addressField, selector == #selector(NSResponder.cancelOperation(_:)) {
            addressField.stringValue = addressText(for: activeTab)
            if let web = activeTab?.webView { window?.makeFirstResponder(web) }
            return true
        }
        return false
    }

    // MARK: - Form input

    func formStateChanged(in webView: WKWebView?, frame: String, dirty: Bool) {
        guard let webView, let tab = tabs.first(where: { $0.webView === webView }) else { return }
        if dirty { tab.dirtyFrames.insert(frame) } else { tab.dirtyFrames.remove(frame) }
    }

    // MARK: - Passkey

    /// Called from the detection script when a page fails to use a passkey (NotAllowedError).
    func passkeyFailed(in webView: WKWebView?) {
        guard let webView, webView === activeTab?.webView, let window, window.attachedSheet == nil else { return }
        let host = webView.url?.host ?? ""
        // Once per site per window, to avoid nagging.
        guard passkeyWarnedHosts.insert(host).inserted else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Passkeys can't be used in Askara yet")
        alert.informativeText = String(localized: "macOS only lets third-party browsers use passkeys and security keys if the app is signed with a special entitlement from Apple (requires an Apple Developer account). This Askara build doesn't have that entitlement yet, so passkey requests are always rejected by the system.\n\nFor now, sign in to \(host.isEmpty ? String(localized: "this site") : host) through Safari, or use a password.")
        alert.addButton(withTitle: String(localized: "Open in Safari"))
        alert.addButton(withTitle: String(localized: "Close"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.openInSafariAction(nil) }
        }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let web = activeTab?.webView
        switch item.action {
        case #selector(backAction(_:)): return web?.canGoBack ?? false
        case #selector(forwardAction(_:)): return web?.canGoForward ?? false
        case #selector(toggleBookmarksBarAction(_:)):
            item.title = services.preferences.showsBookmarksBar ? String(localized: "Hide Bookmarks Bar")
                                                                : String(localized: "Show Bookmarks Bar")
            return !isPrivate
        case #selector(fullPageScreenshotAction(_:)):
            return activeTab?.webView?.url != nil
        case #selector(toggleBookmarkAction(_:)):
            guard let url = activeTab?.url else { return false }
            item.title = profile.bookmarks.contains(url) ? String(localized: "Remove Bookmark") : String(localized: "Add Bookmark")
            return true
        case #selector(findNextAction(_:)), #selector(findPreviousAction(_:)):
            return web != nil && !findField.stringValue.isEmpty
        case #selector(printPageAction(_:)), #selector(showFindBar(_:)), #selector(reloadAction(_:)),
             #selector(showWebInspectorAction(_:)), #selector(showConsoleAction(_:)),
             #selector(showResourcesAction(_:)), #selector(selectElementAction(_:)),
             #selector(reloadIgnoringCacheAction(_:)):
            return web != nil
        case #selector(toggleSiteJavaScriptAction(_:)):
            guard let host = activeSiteHost else {
                item.title = String(localized: "Block JavaScript on This Site")
                return false
            }
            let site = SiteSettings.key(for: host)
            item.title = services.siteSettings.isJavaScriptBlocked(host: host)
                ? String(localized: "Allow JavaScript on \(site)") : String(localized: "Block JavaScript on \(site)")
            return true
        case #selector(editSiteCodeAction(_:)):
            return activeSiteHost != nil
        case #selector(deviceModeAction(_:)):
            let presets = DevicePreset.all
            let current = activeTab?.device.flatMap { d in presets.firstIndex(of: d).map { $0 + 1 } } ?? 0
            item.state = item.tag == current ? .on : .off
            return web != nil
        case #selector(rotateDeviceAction(_:)):
            item.state = activeTab?.deviceLandscape == true ? .on : .off
            return activeTab?.device != nil
        case #selector(colorSchemeAction(_:)):
            let schemes: [NSAppearance.Name?] = [nil, .aqua, .darkAqua]
            item.state = schemes.indices.contains(item.tag) && schemes[item.tag] == activeTab?.colorScheme ? .on : .off
            return web != nil
        case #selector(viewSourceAction(_:)):
            return ["http", "https"].contains(web?.url?.scheme ?? "")
        case #selector(copyPageAddress(_:)):
            return activeTab?.url != nil
        case #selector(openInSafariAction(_:)):
            return activeTab?.url != nil
        case #selector(selectTabNumberAction(_:)):
            // ⌘n does nothing if the nth tab doesn't exist (⌘9 = last tab).
            return item.tag == 9 ? !tabs.isEmpty : item.tag <= tabs.count
        case #selector(zoomResetAction(_:)):
            return abs((activeTab?.zoom ?? 1) - 1) > 0.001
        case #selector(togglePinTabAction(_:)):
            let tab = targetTab(item)
            item.title = tab?.isPinned == true ? String(localized: "Unpin Tab") : String(localized: "Pin Tab")
            return tab != nil
        case #selector(toggleMuteTabAction(_:)):
            let tab = targetTab(item)
            item.title = tab?.isMuted == true ? String(localized: "Unmute Tab") : String(localized: "Mute Tab")
            return tab != nil
        case #selector(toggleKeepAwakeAction(_:)):
            guard let host = activeSiteHost else { return false }
            item.state = services.preferences.keepsAwake(host: host) ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - WKNavigationDelegate

    /// The `preferences` variant lets JavaScript be switched per navigation, for per-site blocking.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // HTTPS-Only Mode: load the https:// version instead; the http:// URL is kept for the fallback prompt.
        if action.targetFrame?.isMainFrame ?? true, let url = action.request.url, let secure = httpsUpgrade(for: url),
           let tab = tabs.first(where: { $0.webView === webView }) {
            decisionHandler(.cancel, preferences)
            // The https:// page redirected back to http:// on the same site: the site has no working
            // HTTPS. Upgrading again would loop, so ask instead.
            if let pending = tab.httpFallbackURL, pending.host?.lowercased() == url.host?.lowercased() {
                tab.httpFallbackURL = nil
                let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "The site redirected its secure page back to HTTP."),
                ])
                offerInsecureFallback(url, error: error, in: tab)
                return
            }
            tab.httpFallbackURL = url
            webView.load(URLRequest(url: secure))
            return
        }
        let policy = navigationPolicy(for: action)
        // Preferences only take effect for main-frame navigations; iframes follow their page.
        if policy == .allow, action.targetFrame?.isMainFrame ?? true,
           let host = action.request.url?.host, !host.isEmpty {
            preferences.allowsContentJavaScript = !services.siteSettings.isJavaScriptBlocked(host: host)
        }
        decisionHandler(policy, preferences)
    }

    private func navigationPolicy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }

        guard let url = action.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        let isUserClick = action.navigationType == .linkActivated

        // ⌘+click: open in a background tab (asleep until opened).
        if isUserClick, action.modifierFlags.contains(.command), ["http", "https"].contains(scheme) {
            newTab(url: url, activate: false)
            return .cancel
        }

        // mailto:, tel:, zoommtg:, etc. go to the matching app, only when clicked by the user.
        let webSchemes: Set<String> = ["http", "https", "about", "file", "blob", "data", "javascript"]
        // Internal extension pages (settings, popups opened in a tab) still load in Askara.
        if !webSchemes.contains(scheme), !(profile.loadedExtensions?.isExtensionURL(url) ?? false) {
            if isUserClick { NSWorkspace.shared.open(url) }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if response.isForMainFrame, !response.canShowMIMEType || disposition.hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        services.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        services.downloads.track(download)
    }

    /// The final page starts showing: all server redirects are done, so this URL is the one
    /// displayed. The address bar always matches the visible content.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.webView === webView }), let url = webView.url else { return }
        tab.url = url
        tab.displayURL = url
        if tab.hidesHomeAddress, tab.homeLandingURL == nil { tab.homeLandingURL = url }
        tab.httpFallbackURL = nil
        // New page: the old page's form input is gone.
        tab.dirtyFrames.removeAll()
        if tab === activeTab { updateToolbar() }
        // As early as possible so the page doesn't flash without the custom CSS.
        applySiteCSS(to: webView)
        applySiteJavaScript(to: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Again once loaded: at commit time the document can still be too empty to take the CSS.
        applySiteCSS(to: webView)
        if let tab = tabs.first(where: { $0.webView === webView }), tab.refocusAddressAfterLoad {
            // After the page's own autofocus scripts have run.
            DispatchQueue.main.async { [weak self, weak tab] in
                MainActor.assumeIsolated { if let tab { self?.refocusAddressBarIfNeeded(tab) } }
            }
        }
        if !isPrivate, let url = webView.url { profile.recordVisit(url: url, title: webView.title) }
        sessionChanged()
        loadFavicon(for: webView)
    }

    /// Fetch the page's icon list, then download the best match (once per site per app session).
    private func loadFavicon(for webView: WKWebView) {
        guard let pageURL = webView.url, ["http", "https"].contains(pageURL.scheme ?? "") else { return }
        webView.evaluateJavaScript(FaviconStore.script) { [weak self] result, _ in
            guard let self else { return }
            let candidates = result as? [[String: Any]] ?? []
            FaviconStore.shared.update(pageURL: pageURL, candidates: candidates, persist: !self.isPrivate) {
                BrowserServices.shared.windows.forEach { $0.refreshTabStrip() }
            }
        }
    }

    /// If the page process crashes or is killed by the system, treat the tab as sleeping.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        // Killed by macOS (usually out of memory) or crashed: the page has to load again.
        Log.notice("Askara: page process ended, tab will reload: \(webView.url?.host ?? "?")")
        if index == activeIndex {
            webView.reload()
        } else {
            dropWebView(of: tabs[index])
            refreshTabStrip()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        if let tab = tabs.first(where: { $0.webView === webView }), let insecure = tab.httpFallbackURL {
            tab.httpFallbackURL = nil
            let nsError = error as NSError
            // Cancelled (user stopped, or a new navigation started): no prompt.
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            return offerInsecureFallback(insecure, error: nsError, in: tab)
        }
        showLoadError(error, in: webView)
    }

    // MARK: - HTTPS-Only Mode

    /// https:// URL to load instead, when HTTPS-Only Mode is on and the user hasn't allowed HTTP for the site.
    private func httpsUpgrade(for url: URL) -> URL? {
        guard services.preferences.httpsOnly, let host = url.host,
              !services.httpAllowedHosts.contains(SitePermissions.key(for: host)) else { return nil }
        return HTTPSUpgrade.upgradedURL(for: url)
    }

    /// Like Chrome's "Connection is not secure" interstitial, as a sheet: go back, or continue over HTTP.
    private func offerInsecureFallback(_ url: URL, error: NSError, in tab: Tab) {
        guard let window, let host = url.host else { return }
        if tab !== activeTab { activate(tab: tab) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "\(host) doesn't support a secure connection")
        alert.informativeText = String(localized: "HTTPS-Only Mode is on. Over HTTP, anyone on the network can see or change what you send and receive on this site, including passwords.")
            + "\n\n" + error.localizedDescription
        alert.addButton(withTitle: String(localized: "Go Back"))
        alert.addButton(withTitle: String(localized: "Continue to HTTP Site"))
        alert.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard let self, let tab else { return }
            if response == .alertSecondButtonReturn {
                // Allowed until Askara quits, like Chrome.
                self.services.httpAllowedHosts.insert(SitePermissions.key(for: host))
                self.load(url, in: tab)
            } else if tab.webView?.canGoBack == true {
                tab.webView?.goBack()
            } else {
                tab.displayURL = tab.webView?.url ?? tab.displayURL
                self.updateToolbar()
            }
        }
    }

    private func showLoadError(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        // Not a real error: navigation was cancelled, or the page turned into a download.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        guard webView === activeTab?.webView else { return }
        showToast(String(localized: "Failed to load: \(nsError.localizedDescription)"), duration: 5)
    }

    // MARK: - WKUIDelegate

    /// target=_blank and window.open: the popup WebView becomes a new tab. A WebView built with
    /// WebKit's `configuration` keeps `window.opener`, so OAuth/payment logins still work.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = AskaraWebView(frame: contentView.bounds, configuration: configuration)
        insertTab(url: navigationAction.request.url, at: activeIndex + 1, activate: true, webView: popup)
        return popup
    }

    /// window.close() from the page.
    func webViewDidClose(_ webView: WKWebView) {
        if let index = tabs.firstIndex(where: { $0.webView === webView }) { closeTab(at: index) }
    }

    private func pageAlert(_ frame: WKFrameInfo, message: String) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? String(localized: "This page says") : String(localized: "\(host) says")
        alert.informativeText = message
        return alert
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let window else { return completionHandler() }
        let alert = pageAlert(frame, message: message)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let window else { return completionHandler(false) }
        let alert = pageAlert(frame, message: message)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let alert = pageAlert(frame, message: prompt)
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        input.setAccessibilityLabel(prompt)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
        }
    }

    // MARK: - Permissions (camera, microphone, location)

    /// Camera/microphone. Remembered per site like Chrome; macOS also asks once for Askara itself.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let kinds: [PermissionKind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        decidePermission(kinds, host: origin.host, in: webView) { decisionHandler($0 ? .grant : .deny) }
    }

    /// Location, via WebKit's private delegate call (the public API has no geolocation prompt on macOS).
    /// Without it WebKit denies location, so implementing it only adds a choice for the user.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decidePermission([.location], host: origin.host, in: webView) { decisionHandler($0 ? .grant : .deny) }
    }

    /// Uses the saved choice, or asks. Private windows ask every time and don't remember "Always".
    private func decidePermission(_ kinds: [PermissionKind], host: String, in webView: WKWebView,
                                  completion: @escaping @MainActor (Bool) -> Void) {
        guard !host.isEmpty else { return completion(false) }
        if !isPrivate, let saved = profile.permissions.decision(for: kinds, host: host) {
            return completion(saved == .allow)
        }
        guard let window, let tab = tabs.first(where: { $0.webView === webView }) else { return completion(false) }
        // Only the visible tab may ask, so a background page can't pop up a prompt.
        if tab !== activeTab { return completion(false) }

        let what: String
        if kinds == [.location] {
            what = String(localized: "\(host) wants to know your location")
        } else if kinds.count == 2 {
            what = String(localized: "\(host) wants to use your camera and microphone")
        } else if kinds == [.camera] {
            what = String(localized: "\(host) wants to use your camera")
        } else {
            what = String(localized: "\(host) wants to use your microphone")
        }
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = isPrivate
            ? String(localized: "In a private window this choice isn't remembered.")
            : String(localized: "You can change this later in Settings > Site Permissions.")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        if !isPrivate {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Remember for this site")
            alert.suppressionButton?.state = .on
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            let allowed = response == .alertFirstButtonReturn
            if let self, !self.isPrivate, alert.suppressionButton?.state == .on {
                kinds.forEach { self.profile.setPermission(allowed ? .allow : .block, for: $0, host: host) }
            }
            completion(allowed)
        }
    }

    /// <input type="file">
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.lastActive = Date()
        lastFocused = Date()
        if !isPrivate { services.profileUsed(profile) }
        extensionController?.didFocusWindow(self)
    }

    // In full screen macOS moves the titlebar (with the empty toolbar that sizes it) into its own
    // opaque strip at the top, which covers the tab strip. Hiding the toolbar there leaves only the
    // thin titlebar that slides in when the pointer reaches the top, like Safari. Restored before
    // leaving full screen so the red/yellow/green buttons line up with the tabs again.
    func windowWillEnterFullScreen(_ notification: Notification) {
        suggestions.hide()
        window?.toolbar?.isVisible = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
    }

    func windowDidResignKey(_ notification: Notification) { suggestions.hide() }
    func windowWillStartLiveResize(_ notification: Notification) { suggestions.hide() }
    func windowWillMove(_ notification: Notification) { suggestions.hide() }

    func windowWillClose(_ notification: Notification) {
        suggestions.hide()
        services.windowWillClose(self)
        let closing = tabs
        tabs.forEach(dropWebView(of:))
        tabs.removeAll()
        if let controller = extensionController {
            closing.forEach { controller.didCloseTab($0, windowIsClosing: true) }
            controller.didCloseWindow(self)
        }
    }

    // MARK: - Extension buttons

    private var extensionButtons: [NSButton] = []
    private var extensionPopover: NSPopover?

    /// One button per active extension, right of the address bar. Icon and badge come from the extension.
    @objc func refreshExtensionButtons() {
        guard let stack = bookmarkButton.superview as? NSStackView else { return }
        extensionButtons.forEach { $0.removeFromSuperview() }
        extensionButtons.removeAll()
        guard !isPrivate else { return }

        for (index, entry) in (profile.loadedExtensions?.loaded ?? []).enumerated() {
            let action = entry.context.action(for: activeTab)
            let label = action?.label.isEmpty == false ? action!.label : (entry.context.webExtension.displayName ?? entry.item.name)
            let button = FirstClickButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = action?.icon(for: NSSize(width: 18, height: 18))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: label)
            button.tag = index
            button.target = self
            button.action = #selector(extensionButtonClicked(_:))
            let badge = action?.badgeText ?? ""
            button.toolTip = badge.isEmpty ? label : "\(label) (\(badge))"
            button.setAccessibilityLabel(button.toolTip)
            button.isEnabled = action?.isEnabled ?? true
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            if !badge.isEmpty { addBadge(badge, to: button) }
            // Extension buttons sit between the bookmark star and the profile avatar.
            stack.insertArrangedSubview(button, at: stack.arrangedSubviews.firstIndex(of: profileButton) ?? stack.arrangedSubviews.count)
            extensionButtons.append(button)
        }
    }

    private func addBadge(_ text: String, to button: NSButton) {
        let badge = NSTextField(labelWithString: text)
        badge.font = .boldSystemFont(ofSize: 8)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            badge.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            badge.heightAnchor.constraint(equalToConstant: 11),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 11),
        ])
    }

    @objc private func extensionButtonClicked(_ sender: NSButton) {
        let loaded = profile.loadedExtensions?.loaded ?? []
        guard loaded.indices.contains(sender.tag) else { return }
        // WebKit handles the click: opens the popup (via the presentActionPopup delegate) or sends the onClicked event.
        // Don't touch action.popupWebView before this: WebKit only presents a popup whose page finishes
        // loading after performAction, so an early (preloaded) page never gets shown.
        loaded[sender.tag].context.performAction(for: activeTab)
    }

    private var popoverAppearanceObservation: NSKeyValueObservation?

    /// WebKit forces the popover to light (Aqua) when the popup page declares no `color-scheme`,
    /// which Bitwarden doesn't, even though its own CSS is dark. That leaves a white arrow under
    /// the toolbar button. Keep the popover on the window's appearance instead (nil = inherit).
    private func followWindowAppearance(_ popover: NSPopover) {
        popover.appearance = nil
        popoverAppearanceObservation = popover.observe(\.appearance, options: [.new]) { popover, _ in
            MainActor.assumeIsolated {
                if popover.appearance != nil { popover.appearance = nil }
            }
        }
    }

    /// Shows the extension popup below its button. WebKit has already prepared the NSPopover.
    func presentExtensionPopup(_ action: WKWebExtension.Action) -> Bool {
        guard let popover = action.popupPopover else { return false }
        let index = profile.loadedExtensions?.loaded.firstIndex { $0.context === action.webExtensionContext }
        let anchor: NSView = index.flatMap { extensionButtons.indices.contains($0) ? extensionButtons[$0] : nil }
            ?? addressField
        showWindow(nil)
        extensionPopover?.close()
        popover.behavior = .transient
        followWindowAppearance(popover)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        extensionPopover = popover
        return true
    }
}

// MARK: - Window as WKWebExtensionWindow

extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        return window.isZoomed ? .maximized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }

    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        showWindow(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}


// MARK: - Bookmarks bar

extension BrowserWindowController: BookmarkBarDelegate {
    var bookmarkBarProfile: ProfileData { profile }

    func bookmarkBar(_ bar: BookmarkBarView, open url: URL, newTab: Bool) {
        if newTab { self.newTab(url: url) } else { load(url) }
    }

    func bookmarkBar(_ bar: BookmarkBarView, openAll urls: [URL]) {
        urls.forEach { newTab(url: $0) }
    }
}

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
