import AppKit
import JavaScriptCore
import Testing
import WebKit
import AskaraCore
@testable import Askara

/// AppKit's window open/close animation keeps an unretained pointer to its window. If a test
/// releases a window while that animation is still running, the process crashes later in
/// `_NSWindowTransformAnimation dealloc`. Windows shown by tests are kept for the whole run.
@MainActor
enum TestWindows {
    private static var kept: [AnyObject] = []
    static func keep(_ window: NSWindow?) {
        guard let window else { return }
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        kept.append(window)
    }
    /// Objects that own a window internally (e.g. the suggestions panel).
    static func keep(owner: AnyObject) { kept.append(owner) }
}

/// Collects messages the passkey detection script posts, like the real window controller does.
@MainActor
private final class PasskeyProbe: NSObject, WKScriptMessageHandler {
    private(set) var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}

@MainActor
private func passkeyWebView(probe: PasskeyProbe, html: String, injectScript: Bool = true) async throws -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.add(probe, name: "askaraPasskey")
    if injectScript {
        config.userContentController.addUserScript(WKUserScript(
            source: Passkey.detectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    // An https base URL makes the page a secure context, so navigator.credentials exists.
    web.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
    for _ in 0..<100 where web.isLoading || web.url == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    return web
}

@Suite("AppKit UI components", .serialized)
struct AskaraUITests {
    @Test("Responsible footprint includes the process itself")
    func responsibleFootprintIncludesSelf() throws {
        let own = try #require(ProcessMemory.footprint(pid: getpid()))
        let total = try #require(ProcessMemory.responsibleFootprint(of: getpid()))
        #expect(total >= own)
        let processes = try #require(ProcessMemory.responsibleProcesses(of: getpid()))
        #expect(processes.contains { $0.pid == getpid() })
        #expect(processes == processes.sorted { $0.bytes > $1.bytes })
    }

    @Test("WebKit helper processes get readable names")
    func helperProcessNames() {
        #expect(ProcessMemory.displayName(for: "com.apple.WebKit.GPU") != "com.apple.WebKit.GPU")
        #expect(ProcessMemory.displayName(for: "com.apple.WebKit.Networking") != "com.apple.WebKit.Networking")
        #expect(ProcessMemory.displayName(for: "SomethingElse") == "SomethingElse")
    }

    @Test("Other processes popover lists what it is given")
    @MainActor
    func otherProcessesPopover() {
        _ = NSApplication.shared
        let list = OtherProcessesViewController()
        _ = list.view
        let items = [ProcessMemory.Usage(pid: 10, name: "com.apple.WebKit.GPU", bytes: 20_000_000),
                     ProcessMemory.Usage(pid: 11, name: "com.apple.WebKit.WebContent", bytes: 300_000_000)]
        list.update(items)
        #expect(list.itemsForTesting == items)
    }

    @Test("Spare new tab hands over only a finished page for the same URL")
    @MainActor
    func spareNewTabHandover() async throws {
        let url = try #require(URL(string: "data:text/html,<title>Spare</title><input autofocus>"))
        let other = try #require(URL(string: "data:text/html,other"))
        let spare = SpareNewTab { WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)) }

        #expect(spare.take(for: url) == nil) // nothing prepared yet
        spare.prepare(url: url, after: 0)
        var web: WKWebView?
        for _ in 0..<100 where web == nil {
            try await Task.sleep(for: .milliseconds(50))
            #expect(spare.take(for: other) == nil) // different URL is never handed over
            web = spare.take(for: url)
        }
        let page = try #require(web)
        #expect(page.navigationDelegate == nil) // caller attaches its own delegate
        #expect(page.url == url)
        #expect(!page.isLoading)
        #expect(spare.take(for: url) == nil) // handed over once

        spare.prepare(url: url, after: 0)
        spare.discard() // cancels the pending load
        try await Task.sleep(for: .milliseconds(300))
        #expect(spare.take(for: url) == nil)
    }

    @Test("Loading bar exposes progress and never moves backwards")
    @MainActor
    func loadingBarProgress() {
        let bar = LoadingBar(frame: NSRect(x: 0, y: 0, width: 200, height: 2))

        #expect(bar.isHidden)
        bar.update(loading: true, progress: 0.35, animated: false)
        #expect(!bar.isHidden)
        #expect(bar.accessibilityValue() as? Int == 35)

        bar.update(loading: true, progress: 0.2, animated: false)
        #expect(bar.accessibilityValue() as? Int == 35)

        bar.update(loading: false, progress: 1, animated: false)
        #expect(bar.isHidden)
    }

    @Test("Tab strip renders active, sleeping, pinned, and muted states")
    @MainActor
    func tabStripStateAndLayout() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: TabStripView.height))
        strip.update(items: [
            TabStripItem(title: "Pinned", isSleeping: true, isPlayingAudio: false, isPinned: true),
            TabStripItem(title: "Active", isSleeping: false, isPlayingAudio: false),
            TabStripItem(title: "Muted", isSleeping: false, isPlayingAudio: false, isMuted: true),
        ], activeIndex: 1)
        strip.layoutSubtreeIfNeeded()

        let tabs = strip.subviews.compactMap { $0 as? TabItemView }
        #expect(tabs.count == 3)
        #expect(strip.accessibilityIdentifier() == "askara.tabs")
        #expect(tabs[0].frame.width == TabStripView.pinnedWidth)
        #expect(tabs[0].accessibilityIdentifier() == "askara.tab.0")
        #expect((tabs[0].accessibilityLabel() ?? "").contains("pinned"))
        #expect(tabs[0].accessibilityValue() as? Bool == false)
        #expect(tabs[1].accessibilityValue() as? Bool == true)
        #expect((tabs[2].accessibilityLabel() ?? "").contains("muted"))

        let initialConfigurationCounts = tabs.map(\.configurationCount)
        strip.update(items: [
            TabStripItem(title: "Pinned", isSleeping: true, isPlayingAudio: false, isPinned: true),
            TabStripItem(title: "Active", isSleeping: false, isPlayingAudio: false),
            TabStripItem(title: "Muted", isSleeping: false, isPlayingAudio: false, isMuted: true),
        ], activeIndex: 1)
        #expect(tabs.map(\.configurationCount) == initialConfigurationCounts)

        strip.update(items: [TabStripItem(title: "Only", isSleeping: false, isPlayingAudio: false)],
                     activeIndex: 0)
        #expect(strip.subviews.compactMap { $0 as? TabItemView }.count == 1)
    }

    @Test("Crowded tab strip keeps the active tab wide enough and icons on the left")
    @MainActor
    func crowdedTabStripLayout() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: TabStripView.height))
        let items = (0..<22).map { TabStripItem(title: "Tab \($0)", isSleeping: false, isPlayingAudio: false) }
        strip.update(items: items, activeIndex: 12)
        strip.layoutSubtreeIfNeeded()

        let tabs = strip.subviews.compactMap { $0 as? TabItemView }
        #expect(tabs.count == 22)
        #expect(tabs.allSatisfy { !$0.isHidden }) // 22 tabs still fit at the 28 pt minimum
        #expect(tabs[12].frame.width >= TabStripView.activeMinWidth)
        #expect(tabs[11].frame.width < TabStripView.activeMinWidth)
        // No overlap: each tab starts where the previous one ends.
        for (a, b) in zip(tabs, tabs.dropFirst()) { #expect(abs(a.frame.maxX - b.frame.minX) < 0.5) }

        // Moving the active tab moves the extra room with it.
        strip.update(items: items, activeIndex: 3)
        strip.layoutSubtreeIfNeeded()
        #expect(tabs[3].frame.width >= TabStripView.activeMinWidth)
        #expect(tabs[12].frame.width < TabStripView.activeMinWidth)
    }

    @Test("Crowded tabs still show a few letters of the title; only the active one has a close button")
    @MainActor
    func crowdedTabsShowTitlesAndActiveClose() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: TabStripView.height))
        let items = (0..<20).map { TabStripItem(title: "Title \($0)", isSleeping: false, isPlayingAudio: false) }
        strip.update(items: items, activeIndex: 5)
        strip.layoutSubtreeIfNeeded()
        let tabs = strip.subviews.compactMap { $0 as? TabItemView }

        // ~50 pt wide: icon plus a couple of letters, and no close button on inactive tabs.
        let inactive = tabs[0]
        #expect(inactive.frame.width < TabItemView.compactWidth)
        #expect(inactive.frame.width >= 48)
        #expect(inactive.showsTitleForTesting)
        #expect(!inactive.showsCloseButtonForTesting)

        // The active tab keeps its title and its close button.
        #expect(tabs[5].showsTitleForTesting)
        #expect(tabs[5].showsCloseButtonForTesting)

        // Too narrow for any letters: icon only.
        let tight = TabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: TabStripView.height))
        tight.update(items: (0..<30).map { TabStripItem(title: "Tab \($0)", isSleeping: false, isPlayingAudio: false) },
                     activeIndex: 10)
        tight.layoutSubtreeIfNeeded()
        let narrow = tight.subviews.compactMap { $0 as? TabItemView }
        #expect(!narrow[0].showsTitleForTesting)
        #expect(narrow[10].showsCloseButtonForTesting)
    }

    @Test("Address suggestions cycle back to typed text")
    @MainActor
    func addressSuggestionKeyboardCycle() throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        TestWindows.keep(parent)
        let field = NSTextField(frame: NSRect(x: 20, y: 120, width: 400, height: 30))
        parent.contentView?.addSubview(field)
        let controller = AddressSuggestionsController()
        TestWindows.keep(owner: controller)
        let first = AddressSuggestion(kind: .history, url: try #require(URL(string: "https://example.com")),
                                      title: "Example")
        let second = AddressSuggestion(kind: .bookmark, url: try #require(URL(string: "https://swift.org")),
                                       title: "Swift")

        controller.show([first, second], below: field)
        #expect(controller.items == [first, second])
        #expect(controller.selected == nil)
        #expect(controller.moveSelection(by: 1) == first)
        #expect(controller.moveSelection(by: 1) == second)
        #expect(controller.moveSelection(by: 1) == nil)
        #expect(controller.moveSelection(by: -1) == second)

        controller.hide()
        #expect(controller.items.isEmpty)
        #expect(controller.selectedIndex == -1)
        parent.close()
    }

    @Test("Short address suggestion titles keep their full width")
    @MainActor
    func shortAddressSuggestionTitleWidth() throws {
        _ = NSApplication.shared
        let row = SuggestionRowView()
        row.frame = NSRect(x: 0, y: 0, width: 900, height: 30)
        row.configure(AddressSuggestion(kind: .history,
                                        url: try #require(URL(string: "https://sso.example/login")),
                                        title: "SSO"))
        row.layoutSubtreeIfNeeded()

        #expect(row.titleWidthForTesting >= row.titleTextWidthForTesting)
        // The raw string width alone is too narrow: the cell adds padding on both sides.
        let raw = ("SSO" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        #expect(row.titleWidthForTesting >= ceil(raw) + 4)

        // Reusing the row for a long title and back must not keep the old width.
        row.configure(AddressSuggestion(kind: .history,
                                        url: try #require(URL(string: "https://example.com/a")),
                                        title: String(repeating: "Long title ", count: 20)))
        row.layoutSubtreeIfNeeded()
        row.configure(AddressSuggestion(kind: .history,
                                        url: try #require(URL(string: "https://sso.example/login")),
                                        title: "SSO"))
        row.layoutSubtreeIfNeeded()
        #expect(row.titleWidthForTesting >= ceil(raw) + 4)
        #expect(row.titleWidthForTesting < 100)
    }

    @Test("Restore caps eager pinned tabs to the loaded-tab budget")
    @MainActor
    func restoredPinnedTabBudget() {
        let active = Tab(url: URL(string: "https://active.example"))
        active.isPinned = true
        let pinned = (0..<5).map { index -> Tab in
            let tab = Tab(url: URL(string: "https://pinned\(index).example"))
            tab.isPinned = true
            return tab
        }
        let ordinary = Tab(url: URL(string: "https://ordinary.example"))
        let all = [active] + pinned + [ordinary]

        let constrained = BrowserWindowController.restoredPinnedTabsToPreload(
            all, active: active, maxLoadedTabs: 2, loadedTabCount: 1)
        #expect(constrained.count == 1)
        #expect(constrained[0] === pinned[0])

        let roomy = BrowserWindowController.restoredPinnedTabsToPreload(
            all, active: active, maxLoadedTabs: 20, loadedTabCount: 1)
        #expect(roomy.count == pinned.count)
        #expect(!roomy.contains { $0 === active || $0 === ordinary })

        let reservedForNextWindow = BrowserWindowController.restoredPinnedTabsToPreload(
            all, active: active, maxLoadedTabs: 3, loadedTabCount: 1, reservedLoadedSlots: 1)
        #expect(reservedForNextWindow.count == 1)

        // 0 = no limit, but startup is still capped at the largest setting.
        let unlimited = BrowserWindowController.restoredPinnedTabsToPreload(
            all, active: active, maxLoadedTabs: 0, loadedTabCount: 1)
        #expect(unlimited.count == pinned.count)

        let exhaustedByOtherWindows = BrowserWindowController.restoredPinnedTabsToPreload(
            all, active: active, maxLoadedTabs: 2, loadedTabCount: 2)
        #expect(exhaustedByOtherWindows.isEmpty)
    }

    @Test("PiP observer ignores unrelated DOM churn and coalesces video changes")
    @MainActor
    func pictureInPictureObserverIsThrottled() throws {
        let aggregate = BrowserWindowController.aggregatePictureInPictureStates([
            (eligible: true, active: true),
            (eligible: false, active: false),
        ])
        #expect(aggregate.eligible)
        #expect(aggregate.active)

        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() }
        context.evaluateScript("""
        var messages = [];
        var rafCallbacks = [];
        var listeners = {};
        var videos = [];
        var queryCount = 0;
        var rectCount = 0;
        var observerCallback = null;
        var window = {
          webkit: { messageHandlers: { askaraPiP: {
            postMessage: function(value) { messages.push(value); }
          } } },
          addEventListener: function(name, callback) { listeners['window:' + name] = callback; }
        };
        var document = {
          pictureInPictureElement: null,
          documentElement: {},
          querySelectorAll: function() { queryCount += 1; return videos; },
          addEventListener: function(name, callback) { listeners[name] = callback; }
        };
        function requestAnimationFrame(callback) { rafCallbacks.push(callback); return rafCallbacks.length; }
        function MutationObserver(callback) { observerCallback = callback; this.observe = function() {}; }
        function flushFrame() {
          var callbacks = rafCallbacks;
          rafCallbacks = [];
          callbacks.forEach(function(callback) { callback(); });
        }
        function mutation(hasVideo) {
          return { target: { nodeName: 'DIV' }, addedNodes: [{
            nodeName: 'DIV', querySelector: function() { return hasVideo ? {} : null; }
          }], removedNodes: [] };
        }
        """)
        context.evaluateScript(PictureInPictureScript.source)
        #expect(exception == nil)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 1)
        #expect(context.evaluateScript("queryCount")?.toInt32() == 1)

        context.evaluateScript("for (var i = 0; i < 1000; i++) observerCallback([mutation(false)]);")
        #expect(context.evaluateScript("rafCallbacks.length")?.toInt32() == 0)
        #expect(context.evaluateScript("queryCount")?.toInt32() == 1)

        context.evaluateScript("for (var i = 0; i < 1000; i++) observerCallback([mutation(true)]);")
        #expect(context.evaluateScript("rafCallbacks.length")?.toInt32() == 1)
        context.evaluateScript("flushFrame()")
        // State stayed ineligible, so the native message is deduplicated.
        #expect(context.evaluateScript("messages.length")?.toInt32() == 1)
        #expect(context.evaluateScript("queryCount")?.toInt32() == 2)

        context.evaluateScript("""
        videos = [{ readyState: 2, videoWidth: 640, videoHeight: 360, paused: false,
                    webkitPresentationMode: 'inline',
                    getBoundingClientRect: function() { rectCount += 1; return { width: 640, height: 360 }; } }];
        listeners.loadedmetadata();
        flushFrame();
        """)
        #expect(exception == nil)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 2)
        #expect(context.evaluateScript("messages[1].eligible")?.toBool() == true)
        #expect(context.evaluateScript("typeof messages[1].frame === 'string' && messages[1].frame.length > 0")?.toBool() == true)
        #expect(context.evaluateScript("rectCount")?.toInt32() == 1)

        context.evaluateScript("document.pictureInPictureElement = videos[0]; listeners.enterpictureinpicture();")
        #expect(context.evaluateScript("rafCallbacks.length")?.toInt32() == 0)
        #expect(context.evaluateScript("messages.length")?.toInt32() == 3)
        #expect(context.evaluateScript("messages[2].active")?.toBool() == true)
        context.evaluateScript("listeners['window:pagehide']();")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 4)
        #expect(context.evaluateScript("messages[3].eligible || messages[3].active")?.toBool() == false)
        #expect(context.evaluateScript("messages[0].frame === messages[3].frame")?.toBool() == true)
        context.evaluateScript("listeners['window:pageshow']();")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 5)
        #expect(context.evaluateScript("messages[4].active")?.toBool() == true)
        context.evaluateScript("listeners['window:pagehide'](); listeners['window:pageshow']();")
        #expect(context.evaluateScript("messages.length")?.toInt32() == 7)
        #expect(context.evaluateScript("messages[6].active")?.toBool() == true)
    }

    @Test("Full browser chrome launches with one isolated WebView")
    @MainActor
    func browserWindowSmokeTest() throws {
        _ = NSApplication.shared
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskaraUITests-\(UUID().uuidString)", isDirectory: true)
        let services = BrowserServices(storageDirectory: storage)
        let profile = ProfileData(id: UUID(), services: services, dataStore: .nonPersistent(),
                                  storageDirectory: storage.appendingPathComponent("profile", isDirectory: true))
        let controller = BrowserWindowController(profile: profile, isPrivate: true, services: services)
        TestWindows.keep(controller.window)
        controller.showWindow(nil)
        controller.newTab(url: nil)
        defer { controller.window?.close() }

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let views = controller.window?.contentView.map { [$0] + descendants(of: $0) } ?? []
        let identifiers = Set(views.compactMap { $0.accessibilityIdentifier() })

        #expect(controller.window?.isVisible == true)
        #expect(controller.loadedWebViews.count == 1)
        #expect(controller.tabMenuEntries.count == 1)
        #expect(identifiers.contains("askara.tabs"))
        #expect(identifiers.contains("askara.tabs.new"))
        #expect(identifiers.contains("askara.tabs.search"))
        #expect(identifiers.contains("askara.address"))
        #expect(identifiers.contains("askara.navigation.back"))
        #expect(identifiers.contains("askara.navigation.reload"))
        #expect(identifiers.contains("askara.extensions"))
        #expect(identifiers.contains("askara.downloads"))
        #expect(!FileManager.default.fileExists(atPath: storage.path))

        let url = try #require(URL(string: "https://example.com"))
        controller.load(url)
        controller.duplicateTabInBackgroundAction(nil)
        #expect(controller.tabMenuEntries.count == 2)
        #expect(controller.loadedWebViews.count == 1)
        #expect(controller.allTabs[1].webView == nil)
        #expect(controller.allTabs[1].url?.host == url.host)
    }

    @Test("Source window releases its close observer")
    @MainActor
    func sourceWindowObserverLifecycle() throws {
        _ = NSApplication.shared
        let windowsBefore = SourceWindow.openWindowCount
        let observersBefore = SourceWindow.closeObserverCount
        let sourceURL = try #require(URL(string: "https://example.com"))
        let window = try #require(SourceWindow.show(
            html: "<html><body>fixture</body></html>",
            url: sourceURL,
            relativeTo: nil))
        TestWindows.keep(window)

        #expect(SourceWindow.openWindowCount == windowsBefore + 1)
        #expect(SourceWindow.closeObserverCount == observersBefore + 1)
        window.close()
        #expect(SourceWindow.openWindowCount == windowsBefore)
        #expect(SourceWindow.closeObserverCount == observersBefore)
    }

    /// Mimics Bitwarden: it replaces navigator.credentials.create and rejects with NotAllowedError.
    private static let extensionRejects = """
    navigator.credentials.create = async () => {
      throw new DOMException("Invalid 'sameOriginWithAncestors' value", "NotAllowedError");
    };
    """
    private static let createCall = """
    navigator.credentials.create({ publicKey: { challenge: new Uint8Array(4), rp: { name: 'x' },
      user: { id: new Uint8Array(4), name: 'u', displayName: 'u' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }]%@ } }).catch(() => {}); 1
    """

    @MainActor
    private func waitForPasskeyMessage(_ probe: PasskeyProbe) async throws -> [String: Any]? {
        for _ in 0..<60 where probe.messages.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        return probe.messages.first
    }

    @Test("Passkey detection reports an extension rejecting a request from a frame")
    @MainActor
    func passkeyDetectionFrameRejection() async throws {
        _ = NSApplication.shared
        let probe = PasskeyProbe()
        // Extension assigns after the detection script (document start order: detection first).
        let web = try await passkeyWebView(probe: probe, html: "<script>\(Self.extensionRejects)</script>")
        _ = try? await web.evaluateJavaScript(String(format: Self.createCall, ""))
        let message = try #require(try await waitForPasskeyMessage(probe))
        #expect(message["reason"] as? String == "frame")
        #expect(message["name"] as? String == "create")
    }

    @Test("Passkey detection also works when the extension replaced the function first")
    @MainActor
    func passkeyDetectionExtensionFirst() async throws {
        _ = NSApplication.shared
        let probe = PasskeyProbe()
        let web = try await passkeyWebView(probe: probe, html: "<script>\(Self.extensionRejects)</script>",
                                           injectScript: false)
        _ = try? await web.evaluateJavaScript(Passkey.detectionScript)
        _ = try? await web.evaluateJavaScript(String(format: Self.createCall, ""))
        let message = try #require(try await waitForPasskeyMessage(probe))
        #expect(message["reason"] as? String == "frame")
    }

    @Test("Passkey detection recognises a request for a physical security key")
    @MainActor
    func passkeyDetectionSecurityKey() async throws {
        _ = NSApplication.shared
        let probe = PasskeyProbe()
        let web = try await passkeyWebView(probe: probe, html: "<script>\(Self.extensionRejects)</script>")
        let extra = ", authenticatorSelection: { authenticatorAttachment: 'cross-platform' }"
        _ = try? await web.evaluateJavaScript(String(format: Self.createCall, extra))
        let message = try #require(try await waitForPasskeyMessage(probe))
        #expect(message["reason"] as? String == "securityKey")
    }

    @Test("Passkey detection reports a rejection that happens inside an iframe")
    @MainActor
    func passkeyDetectionInsideIframe() async throws {
        _ = NSApplication.shared
        let probe = PasskeyProbe()
        let inner = "<script>\(Self.extensionRejects)\(String(format: Self.createCall, ""))</script>"
            .replacingOccurrences(of: "\"", with: "&quot;")
        let web = try await passkeyWebView(probe: probe, html: "<iframe srcdoc=\"\(inner)\"></iframe>")
        _ = web
        let message = try #require(try await waitForPasskeyMessage(probe))
        #expect(message["reason"] as? String == "frame")
    }

    @Test("Reader extracts the article and skips navigation, comments, and scripts")
    @MainActor
    func readerExtractsArticle() async throws {
        _ = NSApplication.shared
        let paragraph = String(repeating: "This is a sentence of real article text. ", count: 4)
        let html = """
        <html><head><title>Big Story</title><meta name="author" content="Ada"></head><body>
        <nav><ul><li>Home</li><li>About</li></ul></nav>
        <article>
          <h1>Big Story</h1>
          <h2>First part</h2>
          <p>\(paragraph)</p><p>\(paragraph)</p><p>\(paragraph)</p>
          <ul><li>Point one</li></ul>
          <pre>let x = 1\n  let y = 2</pre>
          <div class="comments"><p>\(paragraph) SPAM COMMENT</p></div>
          <script>var leaked = 'SCRIPT BODY TEXT'</script>
        </article>
        <footer><p>\(paragraph) FOOTER</p></footer>
        </body></html>
        """
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        web.loadHTMLString(html, baseURL: URL(string: "https://news.example/story"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }

        let payload = try await web.evaluateJavaScript(ReaderMode.extractionScript, in: nil, contentWorld: .defaultClient)
        let article = try #require(ReaderArticle(payload: payload))
        #expect(article.isReadable)
        #expect(article.title == "Big Story")
        #expect(article.byline == "Ada")
        let text = article.blocks.map { block -> String in
            switch block {
            case let .paragraph(t), let .listItem(t), let .quote(t), let .code(t), let .heading(_, t): return t
            case let .image(_, alt): return alt
            }
        }.joined(separator: "\n")
        #expect(text.contains("real article text"))
        #expect(text.contains("Point one"))
        #expect(text.contains("let y = 2"))
        #expect(!text.contains("SPAM COMMENT"))
        #expect(!text.contains("FOOTER"))
        #expect(!text.contains("Home"))
        #expect(!text.contains("SCRIPT BODY TEXT"))
    }

    @Test("Reader reports a page without article text as not readable")
    @MainActor
    func readerRejectsThinPage() async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        web.loadHTMLString("<html><body><h1>Login</h1><form><input></form><p>Short.</p></body></html>",
                           baseURL: URL(string: "https://app.example/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        let payload = try await web.evaluateJavaScript(ReaderMode.extractionScript, in: nil, contentWorld: .defaultClient)
        if let article = ReaderArticle(payload: payload) { #expect(!article.isReadable) }
    }

    // MARK: - YouTube ads

    /// A page shaped like YouTube: the first player response is an inline `var`, later ones come
    /// through `JSON.parse` and `Response.json()`. Results are written to `document.body.dataset`.
    private static let youTubeAdPage = """
    <html><head>
    <script>
      var ytInitialPlayerResponse = {"adPlacements": [1], "playerAds": [1], "videoDetails": {"videoId": "a"}};
    </script>
    </head><body>
    <div id="masthead-ad">AD BANNER</div>
    <div class="html5-video-player">
      <video></video>
      <button class="ytp-skip-ad-button" onclick="document.body.dataset.skipped = '1'">Skip</button>
    </div>
    <script>
      const d = document.body.dataset;
      const r = window.ytInitialPlayerResponse;
      d.initialAds = String('adPlacements' in r || 'playerAds' in r);
      d.initialVideo = r.videoDetails.videoId;
      const parsed = JSON.parse('{"playerResponse": {"adSlots": [1], "videoDetails": {"videoId": "b"}}}');
      d.parsedAds = String('adSlots' in parsed.playerResponse);
      d.parsedVideo = parsed.playerResponse.videoDetails.videoId;
      new Response('{"adPlacements": [1], "videoDetails": {"videoId": "c"}}').json().then((j) => {
        d.fetchedAds = String('adPlacements' in j);
        d.fetchedVideo = j.videoDetails.videoId;
      });
    </script>
    </body></html>
    """

    private static let resultsScript = "JSON.stringify(document.body.dataset)"

    @MainActor
    private func youTubeWebView(exceptions: [String]) async throws -> WKWebView {
        _ = NSApplication.shared
        let json = BlockList.contentRuleListJSON(domains: [], excludingSites: exceptions)
        // Compiling also proves WebKit accepts every selector in YouTubeAdRules.
        let list = try #require(try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "askara-test-youtube-\(exceptions.count)",
                                    encodedContentRuleList: json))
        let config = WKWebViewConfiguration()
        config.userContentController.add(list)
        config.userContentController.addUserScript(WKUserScript(
            source: YouTubeAdBlocker.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.loadHTMLString(Self.youTubeAdPage, baseURL: URL(string: "https://www.youtube.com/watch?v=test"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        return web
    }

    @MainActor
    private func results(_ web: WKWebView) async throws -> [String: String] {
        let text = try #require(try await web.evaluateJavaScript(Self.resultsScript) as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
    }

    @Test("YouTube ad data is removed from player responses; the video data stays")
    @MainActor
    func youTubeAdsRemoved() async throws {
        let web = try await youTubeWebView(exceptions: [])
        let r = try await results(web)
        #expect(r["initialAds"] == "false")
        #expect(r["parsedAds"] == "false")
        #expect(r["fetchedAds"] == "false")
        #expect(r["initialVideo"] == "a")
        #expect(r["parsedVideo"] == "b")
        #expect(r["fetchedVideo"] == "c")
        let banner = try await web.evaluateJavaScript(
            "getComputedStyle(document.getElementById('masthead-ad')).display") as? String
        #expect(banner == "none")
    }

    @Test("An ad that still gets through is skipped")
    @MainActor
    func youTubeFallbackSkips() async throws {
        let web = try await youTubeWebView(exceptions: [])
        _ = try await web.evaluateJavaScript(
            "document.querySelector('.html5-video-player').classList.add('ad-showing'); true")
        try await Task.sleep(for: .milliseconds(800))
        #expect(try await results(web)["skipped"] == "1")
    }

    @Test("Ad-block exception for youtube.com turns YouTube blocking off")
    @MainActor
    func youTubeExceptionRespected() async throws {
        let web = try await youTubeWebView(exceptions: ["youtube.com"])
        let r = try await results(web)
        #expect(r["initialAds"] == "true")
        #expect(r["parsedAds"] == "true")
        #expect(r["fetchedAds"] == "true")
        let banner = try await web.evaluateJavaScript(
            "getComputedStyle(document.getElementById('masthead-ad')).display") as? String
        #expect(banner != "none")
    }
}
