import AppKit
import WebKit

/// Changes reported by non-WebKit engines. WebKit tabs report the same information through
/// WKNavigationDelegate and KVO, which BrowserWindowController observes directly.
enum TabContentEvent {
    /// Title, URL, loading state, progress, or back/forward availability changed.
    case stateChanged
    case mainFrameLoadStarted(URL)
    case loadFinished
    case loadFailed(url: URL?, code: Int?, message: String)
    /// The page asked for a popup (target=_blank, window.open). Opened as a new tab.
    case openInNewTab(URL)
    /// A native popup browser that must be adopted synchronously to preserve window.opener.
    case popup(any TabContent, URL?)
    /// The engine finished tearing the page down after `close()`.
    case closed
}

/// Engine-neutral surface of one tab's live page. Owned by exactly one `Tab`; `nil` on the tab
/// means it is asleep. Engine-specific features stay on the concrete type (e.g. `WebKitTabContent`).
@MainActor
protocol TabContent: AnyObject {
    var view: NSView { get }
    var url: URL? { get }
    var title: String? { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var onEvent: ((TabContentEvent) -> Void)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    /// 1 = 100%.
    func setZoom(_ zoom: Double)
    func setMuted(_ muted: Bool)
    func executeJavaScript(_ source: String, completion: ((Error?) -> Void)?)
    /// Stops the page and releases the engine's resources. The content is not reused afterwards.
    func close()
}

@MainActor
final class WebKitTabContent: TabContent {
    let webView: WKWebView
    /// Unused: WebKit state is observed through its delegates and KVO.
    var onEvent: ((TabContentEvent) -> Void)?

    init(_ webView: WKWebView) {
        self.webView = webView
    }

    var view: NSView { webView }
    var url: URL? { webView.url }
    var title: String? { webView.title }
    var isLoading: Bool { webView.isLoading }
    var estimatedProgress: Double { webView.estimatedProgress }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }
    func setZoom(_ zoom: Double) { webView.pageZoom = zoom }
    func setMuted(_ muted: Bool) { webView.askaraSetMuted(muted) }
    func executeJavaScript(_ source: String, completion: ((Error?) -> Void)?) {
        webView.evaluateJavaScript(source) { _, error in completion?(error) }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}
