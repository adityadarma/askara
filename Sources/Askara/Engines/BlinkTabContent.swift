#if ASKARA_CEF
import AppKit
import CEFBridge
import AskaraCore

/// Blink page of one tab, hosted in a native CEF child view.
@MainActor
final class BlinkTabContent: TabContent {
    let browserView: AskaraCEFBrowserView
    var onEvent: ((TabContentEvent) -> Void)?
    private var permissionHandler: ((UInt64, URL, [PermissionKind], @escaping (Bool) -> Void) -> Void)?
    private var permissionCancellationHandler: ((UInt64) -> Void)?

    init(frame: NSRect, requestContext: AskaraCEFRequestContext) {
        browserView = AskaraCEFBrowserView(frame: frame, requestContext: requestContext)
        configureCallbacks()
    }

    private init(browserView: AskaraCEFBrowserView) {
        self.browserView = browserView
        configureCallbacks()
    }

    private func configureCallbacks() {
        browserView.autoresizingMask = [.width, .height]
        // CEF callbacks arrive on the main thread (CEF's UI thread is AppKit's main thread).
        browserView.onStateChanged = { [weak self] in self?.onEvent?(.stateChanged) }
        browserView.onMainFrameLoadStarted = { [weak self] url in
            self?.onEvent?(.mainFrameLoadStarted(url))
        }
        browserView.onLoadCompleted = { [weak self] in self?.onEvent?(.loadFinished) }
        browserView.onLoadFailed = { [weak self] url, code, message in
            self?.onEvent?(.loadFailed(url: url, code: code, message: message))
        }
        browserView.onOpenURLInNewTab = { [weak self] url in self?.onEvent?(.openInNewTab(url)) }
        browserView.onPopupRequested = { [weak self] popupView, url in
            guard let self else { return false }
            let popup = BlinkTabContent(browserView: popupView)
            self.onEvent?(.popup(popup, url))
            return popupView.window != nil
        }
        browserView.onClosed = { [weak self] in self?.onEvent?(.closed) }
        browserView.onPermissionRequested = { [weak self] requestID, origin, kinds, reply in
            guard let self else { return reply(false) }
            var mapped: [PermissionKind] = []
            if kinds.contains(.camera) { mapped.append(.camera) }
            if kinds.contains(.microphone) { mapped.append(.microphone) }
            if kinds.contains(.location) { mapped.append(.location) }
            guard !mapped.isEmpty, let handler = self.permissionHandler else { return reply(false) }
            handler(requestID, origin, mapped, reply)
        }
        browserView.onPermissionRequestCancelled = { [weak self] requestID in
            self?.permissionCancellationHandler?(requestID)
        }
    }

    var view: NSView { browserView }
    var url: URL? { browserView.url }
    var title: String? { browserView.pageTitle.isEmpty ? nil : browserView.pageTitle }
    var isLoading: Bool { browserView.isLoading }
    var estimatedProgress: Double { browserView.estimatedProgress }
    var canGoBack: Bool { browserView.canGoBack }
    var canGoForward: Bool { browserView.canGoForward }

    func load(_ url: URL) { browserView.loadURL(url) }
    func goBack() { browserView.goBack() }
    func goForward() { browserView.goForward() }
    func reload() { browserView.reload() }
    func stopLoading() { browserView.stopLoading() }
    func setZoom(_ zoom: Double) { browserView.setZoomFactor(zoom) }
    func setMuted(_ muted: Bool) { browserView.setAudioMuted(muted) }
    func executeJavaScript(_ source: String, completion: ((Error?) -> Void)?) {
        browserView.executeJavaScript(source, sourceURL: nil)
        completion?(nil)
    }

    func configureContentPolicy(blockedDomains: [String], adBlockExceptions: [String],
                                javaScriptBlockedDomains: [String], httpsOnly: Bool,
                                allowedHTTPHosts: [String]) {
        browserView.setBlockedDomains(blockedDomains, excludingSites: adBlockExceptions)
        browserView.setJavaScriptBlockedDomains(javaScriptBlockedDomains)
        browserView.setHTTPSOnlyEnabled(httpsOnly, allowedHTTPHosts: allowedHTTPHosts)
    }

    func onHTTPSFallback(_ handler: @escaping (URL, Int, String) -> Void) {
        browserView.onHTTPSFallbackRequired = { insecure, _, code, message in
            handler(insecure, code, message)
        }
    }

    func onDownload(_ handler: @escaping (AskaraCEFDownload) -> URL?) {
        browserView.onDownloadRequested = handler
    }

    func onPermissionRequest(
        _ handler: @escaping (UInt64, URL, [PermissionKind], @escaping (Bool) -> Void) -> Void,
        cancelled: @escaping (UInt64) -> Void
    ) {
        permissionHandler = handler
        permissionCancellationHandler = cancelled
    }

    func sendMouseClick(at point: NSPoint) { browserView.sendMouseClick(at: point) }

    func close() {
        browserView.removeFromSuperview()
        browserView.close()
        permissionHandler = nil
        permissionCancellationHandler = nil
    }
}
#endif
