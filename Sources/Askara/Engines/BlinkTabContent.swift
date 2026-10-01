#if ASKARA_CEF
import AppKit
import CEFBridge

/// Blink page of one tab, hosted in a native CEF child view.
@MainActor
final class BlinkTabContent: TabContent {
    let browserView: AskaraCEFBrowserView
    var onEvent: ((TabContentEvent) -> Void)?

    init(frame: NSRect, requestContext: AskaraCEFRequestContext) {
        browserView = AskaraCEFBrowserView(frame: frame, requestContext: requestContext)
        browserView.autoresizingMask = [.width, .height]
        // CEF callbacks arrive on the main thread (CEF's UI thread is AppKit's main thread).
        browserView.onStateChanged = { [weak self] in self?.onEvent?(.stateChanged) }
        browserView.onLoadCompleted = { [weak self] in self?.onEvent?(.loadFinished) }
        browserView.onLoadFailed = { [weak self] message in self?.onEvent?(.loadFailed(message)) }
        browserView.onOpenURLInNewTab = { [weak self] url in self?.onEvent?(.openInNewTab(url)) }
        browserView.onClosed = { [weak self] in self?.onEvent?(.closed) }
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

    func close() {
        browserView.removeFromSuperview()
        browserView.close()
    }
}
#endif
