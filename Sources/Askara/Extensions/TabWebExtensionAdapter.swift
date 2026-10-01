import AppKit
import WebKit

extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }

    func indexInWindow(for context: WKWebExtensionContext) -> Int { owner?.index(of: self) ?? NSNotFound }

    /// Sleeping tabs have no WebView; extensions still see their URL and title.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? { title }

    func url(for context: WKWebExtensionContext) -> URL? { webView?.url ?? url }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(webView?.isLoading ?? false) }

    func isSelected(for context: WKWebExtensionContext) -> Bool { owner?.isActive(self) ?? false }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio }

    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.setPinned(pinned, tab: self)
        completionHandler(nil)
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext,
                  completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.setMuted(muted, tab: self)
        completionHandler(nil)
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double { zoom }

    func size(for context: WKWebExtensionContext) -> CGSize { webView?.bounds.size ?? .zero }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.activate(tab: self)
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext,
                     completionHandler: @escaping ((any Error)?) -> Void) {
        if selected { owner?.activate(tab: self) }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.load(url, in: self)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        zoom = zoomFactor
        webView?.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.close(tab: self)
        completionHandler(nil)
    }
}
