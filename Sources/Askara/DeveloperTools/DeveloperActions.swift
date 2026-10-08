import AppKit
import AskaraCore
import CoreImage
import CoreImage.CIFilterBuiltins
import WebKit

/// Develop menu actions that only need the public window API. Actions that change tab state
/// (User Agent, Device Mode, Disable Caches) live next to the tab code in BrowserWindowController.
extension BrowserWindowController {
    // MARK: Copy as cURL

    /// The page request as a `curl` command, with the tab's user agent and the cookies the page would send.
    @objc func copyAsCurlAction(_ sender: Any?) {
        guard let web = currentTab?.webView, let url = web.url, DeveloperPage.isWeb(url) else { return }
        let store = web.configuration.websiteDataStore
        web.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            let agent = result as? String
            store.httpCookieStore.getAllCookies { cookies in
                let list = cookies.map {
                    CurlCommand.Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, isSecure: $0.isSecure)
                }
                let command = CurlCommand.make(url: url, userAgent: agent, cookies: list)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                let sendsCookies = list.contains { CurlCommand.matches($0, url: url) }
                self?.showToast(sendsCookies ? String(localized: "Copied as cURL with this site's cookies. Don't share it.")
                                             : String(localized: "Copied as cURL"), duration: 3)
            }
        }
    }

    // MARK: Open Page With

    @objc func openPageWithAction(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let url = currentTab?.webView?.url ?? currentTab?.url,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return NSSound.beep() }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: QR code

    /// Opens the page on a phone or tablet. localhost is swapped for this Mac's network address,
    /// since on another device it would point at that device.
    @objc func showPageQRCodeAction(_ sender: Any?) {
        guard let window, let pageURL = currentTab?.webView?.url ?? currentTab?.url, DeveloperPage.isWeb(pageURL) else { return }
        let url = LocalDevelopmentHost.reachableURL(pageURL, lanAddress: LocalNetwork.ipv4Address())
        guard let image = QRCode.image(for: url.absoluteString, side: 220) else {
            return showToast(String(localized: "Couldn't create a QR code for this address."), duration: 3)
        }
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityLabel(String(localized: "QR code for \(url.absoluteString)"))

        let alert = NSAlert()
        alert.messageText = String(localized: "Scan to Open on Another Device")
        var info = url.absoluteString
        if url != pageURL {
            info += "\n\n" + String(localized: "localhost was replaced with this Mac's network address. The server must accept connections from the network (for example, bind to 0.0.0.0).")
        } else if let host = pageURL.host, LocalDevelopmentHost.isLoopback(host) {
            info += "\n\n" + String(localized: "This address only works on this Mac. Connect to a network to get an address other devices can reach.")
        }
        alert.informativeText = info
        alert.accessoryView = imageView
        alert.addButton(withTitle: String(localized: "Done"))
        alert.addButton(withTitle: String(localized: "Copy Address"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            self?.showToast(String(localized: "Address copied"), duration: 1.5)
        }
    }

    // MARK: Clear Site Data

    /// Cookies, storage, and caches of the current site only. Other sites and logins stay.
    @objc func clearSiteDataAction(_ sender: Any?) {
        guard let web = currentTab?.webView, let host = activeSiteHost else { return }
        let site = SiteSettings.key(for: host)
        SiteDataCleaner.clear(host: host, in: web.configuration.websiteDataStore) { [weak self] in
            self?.showToast(String(localized: "Site data cleared for \(site)"), duration: 2)
        }
    }
}

enum DeveloperPage {
    static func isWeb(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }
}

/// HTTP caches of a website data store. Cookies, logins, and site storage are left untouched.
@MainActor
enum DeveloperCache {
    static let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                     WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]

    static func empty(_ store: WKWebsiteDataStore, completion: @escaping @MainActor () -> Void) {
        store.removeData(ofTypes: types, modifiedSince: .distantPast) {
            MainActor.assumeIsolated { completion() }
        }
    }
}

/// Removes one site's cookies and website data records (storage, caches, service workers).
@MainActor
enum SiteDataCleaner {
    static func clear(host: String, in store: WKWebsiteDataStore, completion: @escaping @MainActor () -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            cookies.filter { SiteDataDomain.matches($0.domain, site: host) }
                .forEach { store.httpCookieStore.delete($0) }
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let records = records.filter { SiteDataDomain.matches($0.displayName, site: host) }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                    MainActor.assumeIsolated { completion() }
                }
            }
        }
    }
}

/// Develop > Open Page With: filled when the menu opens, so newly installed browsers show up.
@MainActor
enum OpenWithMenu {
    static let id = NSUserInterfaceItemIdentifier("develop.openWith")

    static func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let installed = ExternalBrowser.known.compactMap { browser in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID).map { (browser, $0) }
        }
        guard !installed.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No other browsers found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return menu.addItem(empty)
        }
        for (browser, appURL) in installed {
            let item = NSMenuItem(title: browser.name, action: #selector(BrowserWindowController.openPageWithAction(_:)),
                                  keyEquivalent: "")
            item.representedObject = browser.bundleID
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }
}

enum QRCode {
    /// Black-on-white QR code, scaled by whole pixels so the modules stay sharp.
    static func image(for text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, (side / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

enum LocalNetwork {
    /// This Mac's IPv4 address on the local network (Wi-Fi/Ethernet preferred), or nil when offline.
    static func ipv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard LocalDevelopmentHost.isLocal(text) else { continue }
            candidates.append((String(cString: entry.ifa_name), text))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}
