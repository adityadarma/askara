import AppKit
import JavaScriptCore
import Testing
import AskaraCore
@testable import Askara

@Suite("AppKit UI components", .serialized)
struct AskaraUITests {
    @Test("Engine registry uses WebKit until another runtime is available")
    @MainActor
    func browserEngineRegistryFallback() {
        let registry = BrowserEngineRegistry()

        #expect(registry.adapter(for: .webkit).engine == .webkit)
        #expect(registry.adapter(for: .blink).engine == .webkit)
        #expect(registry.adapter(for: .gecko).engine == .webkit)
        #expect(registry.availability(of: .webkit) == .available)
        #expect(registry.availability(of: .blink) != .available)
        #expect(registry.availability(of: .gecko) != .available)
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

    @Test("Address suggestions cycle back to typed text")
    @MainActor
    func addressSuggestionKeyboardCycle() throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 120, width: 400, height: 30))
        parent.contentView?.addSubview(field)
        let controller = AddressSuggestionsController()
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
    func browserWindowSmokeTest() {
        _ = NSApplication.shared
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskaraUITests-\(UUID().uuidString)", isDirectory: true)
        let services = BrowserServices(storageDirectory: storage,
                                       dataStoreFactory: { _ in .nonPersistent() })
        let profile = ProfileData(id: UUID(), services: services, dataStore: .nonPersistent(),
                                  storageDirectory: storage.appendingPathComponent("profile", isDirectory: true))
        let controller = BrowserWindowController(profile: profile, isPrivate: true, services: services)
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
        #expect(identifiers.contains("askara.address"))
        #expect(identifiers.contains("askara.navigation.back"))
        #expect(identifiers.contains("askara.navigation.reload"))
        #expect(!FileManager.default.fileExists(atPath: storage.path))
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

        #expect(SourceWindow.openWindowCount == windowsBefore + 1)
        #expect(SourceWindow.closeObserverCount == observersBefore + 1)
        window.close()
        #expect(SourceWindow.openWindowCount == windowsBefore)
        #expect(SourceWindow.closeObserverCount == observersBefore)
    }
}
