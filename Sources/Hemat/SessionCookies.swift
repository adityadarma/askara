import Foundation
import WebKit

/// WebKit discards session cookies (cookies without an expiry date) every time the app quits.
/// Many sites keep logins in this kind of cookie (e.g. corporate SSO), so logins are lost after
/// the browser is reopened. Like Chrome with "continue where you left off", Hemat saves them on quit
/// and restores them before tabs are restored.
///
/// The file is readable only by this user account (0600 permissions), like WebKit's own cookie file.
@MainActor
enum SessionCookies {
    private static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hemat/session-cookies.plist")

    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    static func save(completion: @escaping @MainActor () -> Void = {}) {
        store.getAllCookies { cookies in
            MainActor.assumeIsolated {
                let list = cookies.filter(\.isSessionOnly).map(plist)
                write(list)
                completion()
            }
        }
    }

    /// Installs saved cookies. `completion` is called once all are set, before tabs load.
    static func restore(completion: @escaping @MainActor () -> Void) {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              !list.isEmpty else { return completion() }
        let cookies = list.compactMap { entry -> HTTPCookie? in
            let properties = Dictionary(uniqueKeysWithValues: entry.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            return HTTPCookie(properties: properties)
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion() } }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Cookie properties in a form that can be saved to a plist.
    private static func plist(_ cookie: HTTPCookie) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in cookie.properties ?? [:] {
            switch value {
            case let value as String: result[key.rawValue] = value
            case let value as Date: result[key.rawValue] = value
            case let value as NSNumber: result[key.rawValue] = value
            case let value as URL: result[key.rawValue] = value.absoluteString
            default: result[key.rawValue] = String(describing: value)
            }
        }
        return result
    }

    private static func write(_ list: [[String: Any]]) {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Hemat: failed to save session cookies: \(error)")
        }
    }
}
