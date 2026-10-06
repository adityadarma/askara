import AppKit
import WebKit

/// Keeps one new-tab page (the search engine's or home page) loaded off-screen, so ⌘T shows an
/// already finished page. Pages like Google focus their own search box while loading; with the page
/// loaded in advance, nothing takes the keyboard away from the address bar after the tab opens.
@MainActor
final class SpareNewTab: NSObject, WKNavigationDelegate {
    /// A spare older than this is reloaded instead of used (search pages carry short-lived tokens).
    static let maxAge: TimeInterval = 30 * 60

    private let makeWebView: () -> WKWebView
    private var webView: WKWebView?
    private var requestedURL: URL?
    private var readyAt: Date?
    private var pending: DispatchWorkItem?

    init(makeWebView: @escaping () -> WKWebView) {
        self.makeWebView = makeWebView
    }

    /// Starts loading a spare page for `url` after `delay`, unless one for that URL already exists.
    func prepare(url: URL, after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.load(url) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Hands over the spare page if it's for `url` and has finished loading; nil otherwise, and
    /// the caller loads the tab the normal way.
    func take(for url: URL) -> WKWebView? {
        guard let web = webView, requestedURL == url, let readyAt, web.url != nil else { return nil }
        guard Date().timeIntervalSince(readyAt) < Self.maxAge else {
            discard()
            return nil
        }
        web.navigationDelegate = nil
        webView = nil
        requestedURL = nil
        self.readyAt = nil
        return web
    }

    /// Frees the spare page (memory pressure, window closing, or a failed load).
    func discard() {
        pending?.cancel()
        pending = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        requestedURL = nil
        readyAt = nil
    }

    private func load(_ url: URL) {
        pending = nil
        if webView != nil, requestedURL == url { return }
        discard()
        let web = makeWebView()
        // Only this object listens while the page is spare: no history entry, favicon, or tab updates.
        web.navigationDelegate = self
        webView = web
        requestedURL = url
        web.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        readyAt = Date()
    }

    // A failed spare is dropped; the next new tab loads normally and prepares a fresh one.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { discard() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { discard() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { discard() }
    }
}
