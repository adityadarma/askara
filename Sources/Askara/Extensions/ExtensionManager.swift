import AppKit
import WebKit
import AskaraCore

extension Notification.Name {
    static let askaraExtensionsChanged = Notification.Name("AskaraExtensionsChanged")
}

/// A Safari extension (Web Extension) found inside an installed app.
struct InstalledExtension: Equatable {
    let bundleID: String
    let name: String
    let bundleURL: URL
}

/// Loads installed Safari extensions (e.g. Bitwarden) via the WKWebExtension API. One per profile:
/// each profile has its own enabled list and extension storage (e.g. a separate Bitwarden vault login).
///
/// Extensions load only after the user enables them and approves their permissions. That choice is saved,
/// and approved permissions are re-granted every time the profile opens.
@MainActor
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    private struct Keys {
        let enabled: String
        let identifiers: String
        let pinned: String
        init(profile: UUID) {
            // The first profile keeps the keys from before profiles existed.
            let suffix = profile == Profile.defaultID ? "" : ".\(profile.uuidString)"
            enabled = "AskaraEnabledExtensions" + suffix
            identifiers = "AskaraExtensionIdentifiers" + suffix
            pinned = "AskaraPinnedExtensions" + suffix
        }
    }

    let controller: WKWebExtensionController
    private(set) var installed: [InstalledExtension] = []
    /// Stable order (matching the installed list) so toolbar buttons don't move around.
    private(set) var loaded: [(item: InstalledExtension, context: WKWebExtensionContext)] = []
    private var enabledIDs: Set<String>
    private var pinnedIDs: Set<String>
    private let keys: Keys
    private unowned let profile: ProfileData
    private var errorObservers: [NSObjectProtocol] = []
    private var services: BrowserServices { .shared }

    init(profile: ProfileData) {
        self.profile = profile
        keys = Keys(profile: profile.id)
        // Persistent storage, so extension logins/vaults survive a restart. Separate per profile.
        let configuration = profile.id == Profile.defaultID
            ? WKWebExtensionController.Configuration.default()
            : WKWebExtensionController.Configuration(identifier: profile.id)
        // Requests made by extensions use this profile's cookies.
        configuration.defaultWebsiteDataStore = profile.dataStore
        // Extension pages (background, popup) also need the Safari user agent; Bitwarden uses it
        // to identify the browser.
        let webConfig = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webConfig.applicationNameForUserAgent = UserAgent.applicationName
        configuration.webViewConfiguration = webConfig
        controller = WKWebExtensionController(configuration: configuration)
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: keys.enabled) ?? [])
        pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: keys.pinned) ?? [])
        super.init()
        controller.delegate = self
    }

    /// Scheme for extension pages, matching Safari so extensions that check it work.
    static let extensionScheme = "safari-web-extension"

    /// Also accepts WebKit's default scheme, e.g. for tabs saved by older versions.
    static func isExtensionScheme(_ scheme: String?) -> Bool {
        scheme == extensionScheme || scheme == "webkit-extension"
    }

    /// Custom base-URL schemes must be registered before any match pattern is used.
    private static let registerScheme: Void = {
        WKWebExtension.MatchPattern.registerCustomURLScheme(extensionScheme)
    }()

    // MARK: - Discovery & loading

    func start() {
        _ = Self.registerScheme
        Task { @MainActor in
            // The app folder scan runs off the main thread.
            self.installed = await Task.detached(priority: .utility) { Self.discover() }.value
            for item in self.installed where self.enabledIDs.contains(item.bundleID) {
                guard !self.isShutDown else { return }
                do { try await self.load(item) } catch {
                    Log.error("Askara: failed to load extension \(item.name): \(error)")
                }
            }
            self.changed()
        }
    }

    /// Finds app extensions of type `com.apple.Safari.web-extension` in /Applications and ~/Applications.
    nonisolated static func discover() -> [InstalledExtension] {
        let fm = FileManager.default
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        var result: [InstalledExtension] = []
        for root in roots {
            guard let apps = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension == "app" {
                let plugins = app.appendingPathComponent("Contents/PlugIns")
                guard let appexes = try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
                else { continue }
                let appName = fm.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let found = appexes.compactMap { appex -> InstalledExtension? in
                    guard appex.pathExtension == "appex",
                          let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist"))
                              as? [String: Any],
                          let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                          point == "com.apple.Safari.web-extension",
                          let id = info["CFBundleIdentifier"] as? String else { return nil }
                    return InstalledExtension(bundleID: id, name: appName, bundleURL: appex)
                }
                // One app with several extensions: distinguish them by appex file name.
                result += found.count > 1
                    ? found.map { .init(bundleID: $0.bundleID,
                                        name: "\(appName) – \($0.bundleURL.deletingPathExtension().lastPathComponent)",
                                        bundleURL: $0.bundleURL) }
                    : found
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isShutDown = false

    /// The profile's last window closed: unload extensions to free their background pages.
    func shutDown() {
        isShutDown = true
        errorObservers.forEach(NotificationCenter.default.removeObserver)
        errorObservers.removeAll()
        for entry in loaded { try? controller.unload(entry.context) }
        loaded.removeAll()
        changed()
    }

    func isEnabled(_ item: InstalledExtension) -> Bool { enabledIDs.contains(item.bundleID) }

    func isPinned(_ item: InstalledExtension) -> Bool { pinnedIDs.contains(item.bundleID) }

    func setPinned(_ pinned: Bool, item: InstalledExtension) {
        if pinned { pinnedIDs.insert(item.bundleID) } else { pinnedIDs.remove(item.bundleID) }
        UserDefaults.standard.set(pinnedIDs.sorted(), forKey: keys.pinned)
        changed()
    }

    func context(for item: InstalledExtension) -> WKWebExtensionContext? {
        loaded.first { $0.item.bundleID == item.bundleID }?.context
    }

    /// Reads the manifest without loading it, for display in the approval dialog.
    func inspect(_ item: InstalledExtension) async throws -> WKWebExtension {
        guard let bundle = Bundle(url: item.bundleURL) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: item.bundleURL.path])
        }
        return try await WKWebExtension(appExtensionBundle: bundle)
    }

    func enable(_ item: InstalledExtension) async throws {
        try await load(item)
        enabledIDs.insert(item.bundleID)
        saveEnabled()
        changed()
    }

    func disable(_ item: InstalledExtension) {
        if let index = loaded.firstIndex(where: { $0.item.bundleID == item.bundleID }) {
            try? controller.unload(loaded[index].context)
            loaded.remove(at: index)
        }
        enabledIDs.remove(item.bundleID)
        saveEnabled()
        changed()
    }

    private func load(_ item: InstalledExtension) async throws {
        guard context(for: item) == nil else { return }
        let ext = try await inspect(item)
        guard !isShutDown, context(for: item) == nil else { return }
        let context = WKWebExtensionContext(for: ext)
        // Stable ID per extension: extension storage (vault, settings) is tied to this ID.
        context.uniqueIdentifier = stableIdentifier(for: item.bundleID)
        // Use Safari's scheme instead of WebKit's default `webkit-extension://`. Safari extensions
        // check it: Bitwarden's inline menu only loads its button/list iframes from
        // chrome-extension:, moz-extension:, or safari-web-extension: URLs.
        if let base = URL(string: "\(Self.extensionScheme)://\(context.uniqueIdentifier.lowercased())/") {
            context.baseURL = base
        }
        // Permissions were approved when the user enabled the extension.
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        // Extensions don't access private windows.
        context.hasAccessToPrivateData = false
        // Inspectable via Safari > Develop > Askara, to debug a stuck extension.
        context.isInspectable = true
        try controller.load(context)
        loaded.append((item, context))
        // Log extension errors (manifest, background script) to the system log for diagnosis.
        errorObservers.append(NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification,
                                               object: context, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let context = note.object as? WKWebExtensionContext else { return }
                for error in context.errors { Log.error("Askara extension \(item.name): \(error.localizedDescription)") }
            }
        })
        context.errors.forEach { Log.error("Askara extension \(item.name): \($0.localizedDescription)") }
        // Load the background page now so the popup doesn't lag on the first click.
        Task { @MainActor in
            do { try await context.loadBackgroundContent() }
            catch { Log.error("Askara extension \(item.name): background failed: \(error)") }
        }
        loaded.sort { a, b in
            (installed.firstIndex(of: a.item) ?? 0) < (installed.firstIndex(of: b.item) ?? 0)
        }
    }

    private func stableIdentifier(for bundleID: String) -> String {
        var map = UserDefaults.standard.dictionary(forKey: keys.identifiers) as? [String: String] ?? [:]
        if let existing = map[bundleID] { return existing }
        let id = UUID().uuidString
        map[bundleID] = id
        UserDefaults.standard.set(map, forKey: keys.identifiers)
        return id
    }

    private func saveEnabled() {
        UserDefaults.standard.set(enabledIDs.sorted(), forKey: keys.enabled)
    }

    private func changed() {
        NotificationCenter.default.post(name: .askaraExtensionsChanged, object: profile)
    }

    /// Extension internal page URLs (popup, settings) must not be blocked by the navigation policy.
    func isExtensionURL(_ url: URL) -> Bool { controller.extensionContext(for: url) != nil }

    /// Extension pages (e.g. Bitwarden's passkey confirmation window) only load with that extension's
    /// WebView configuration; with a normal tab configuration the page is blank.
    func webViewConfiguration(for url: URL?) -> WKWebViewConfiguration? {
        guard let url, Self.isExtensionScheme(url.scheme) else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: - Permission text for dialogs

    static func describe(_ ext: WKWebExtension) -> [String] {
        let names: [String: String] = [
            "tabs": String(localized: "See the list of tabs and their addresses"),
            "activeTab": String(localized: "Access the current tab when you use it"),
            "storage": String(localized: "Store data on this device"),
            "unlimitedStorage": String(localized: "Store data on this device"),
            "webRequest": String(localized: "Monitor page network requests"),
            "webNavigation": String(localized: "Monitor page navigation"),
            "clipboardWrite": String(localized: "Write to the clipboard"),
            "clipboardRead": String(localized: "Read the clipboard"),
            "contextMenus": String(localized: "Add items to the right-click menu"),
            "menus": String(localized: "Add items to the right-click menu"),
            "alarms": String(localized: "Run scheduled tasks"),
            "nativeMessaging": String(localized: "Communicate with its app (not supported by Askara)"),
            "cookies": String(localized: "Read and change cookies"),
            "scripting": String(localized: "Run scripts on pages"),
            "notifications": String(localized: "Show notifications"),
            "declarativeNetRequest": String(localized: "Block or modify network requests"),
        ]
        var lines: [String] = []
        let patterns = ext.allRequestedMatchPatterns
        if patterns.contains(where: \.matchesAllURLs) || patterns.contains(where: \.matchesAllHosts) {
            lines.append(String(localized: "Read and change content on all websites you visit"))
        } else if !patterns.isEmpty {
            let sites = patterns.map(\.string).sorted().joined(separator: ", ")
            lines.append(String(localized: "Read and change content on websites: \(sites)"))
        }
        for permission in ext.requestedPermissions.map(\.rawValue).sorted() {
            let text = names[permission] ?? permission
            if !lines.contains(text) { lines.append(text) }
        }
        return lines
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        profile.windows.filter { !$0.isPrivate }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedWindow
    }

    /// This profile's normal window in use (or used most recently).
    private var focusedWindow: BrowserWindowController? {
        if let key = services.keyBrowserWindow, key.profile === profile, !key.isPrivate { return key }
        return profile.windows.filter { !$0.isPrivate }.max { $0.lastFocused < $1.lastFocused }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindowController)
            ?? focusedWindow
            ?? services.makeWindow(profile: profile)
        let tab = window.insertTab(url: configuration.url, at: configuration.index,
                                   activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = services.makeWindow(profile: profile)
        if configuration.tabURLs.isEmpty {
            window.openBlankTab()
        } else {
            for (index, url) in configuration.tabURLs.enumerated() {
                window.insertTab(url: url, at: index, activate: index == 0)
            }
        }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        openOptions(extensionContext)
        completionHandler(nil)
    }

    func openOptions(_ context: WKWebExtensionContext) {
        guard let url = context.optionsPageURL else { return }
        services.open(url, newTab: true, nonPrivate: true, profile: profile)
    }

    /// Additional permissions requested at runtime (outside the manifest): ask the user.
    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let list = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        confirm(extensionContext, detail: String(localized: "Additional permissions: \(list)")) { completionHandler($0 ? permissions : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap(\.host)).sorted().joined(separator: ", ")
        confirm(extensionContext, detail: String(localized: "Access to websites: \(hosts)")) { completionHandler($0 ? urls : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let list = matchPatterns.map(\.string).sorted().joined(separator: ", ")
        confirm(extensionContext, detail: String(localized: "Access to websites: \(list)")) { completionHandler($0 ? matchPatterns : [], nil) }
    }

    private func confirm(_ context: WKWebExtensionContext, detail: String, _ done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let name = context.webExtension.displayName ?? String(localized: "Extension")
        alert.messageText = String(localized: "\(name) is requesting permission")
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Deny"))
        guard let window = focusedWindow?.window else {
            return done(alert.runModal() == .alertFirstButtonReturn)
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        changed()
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        let window = (action.associatedTab as? Tab)?.owner ?? focusedWindow
        guard let window, window.presentExtensionPopup(action) else {
            return completionHandler(CocoaError(.featureUnsupported))
        }
        completionHandler(nil)
    }

    /// Native messaging. In Safari, the extension's companion app answers these messages. Askara answers
    /// Bitwarden commands that are safe to emulate itself; the rest (e.g. Touch ID) get an error.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard applicationIdentifier == "com.bitwarden.desktop",
              let body = message as? [String: Any], let command = body["command"] as? String else {
            return replyHandler(nil, CocoaError(.featureUnsupported))
        }
        let data = body["data"] as? String
        switch command {
        case "sleep":
            // Bitwarden calls this in a loop to check the vault lock timeout.
            // The reply must be delayed; without a pause, this loop burns CPU.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { replyHandler(nil, nil) }
        case "copyToClipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(data ?? "", forType: .string)
            replyHandler(nil, nil)
        case "readFromClipboard":
            replyHandler(NSPasteboard.general.string(forType: .string) ?? "", nil)
        case "showPopover":
            extensionContext.performAction(for: focusedWindow?.currentTab)
            replyHandler(nil, nil)
        case "downloadFile":
            saveDownload(json: data)
            replyHandler(nil, nil)
        default:
            replyHandler(nil, CocoaError(.featureUnsupported))
        }
    }

    /// Bitwarden vault export: the file is sent as JSON {blobData, blobOptions: {type}, fileName}.
    private func saveDownload(json: String?) {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blob = object["blobData"] as? String else { return }
        let type = (object["blobOptions"] as? [String: Any])?["type"] as? String
        let bytes = type == "text/plain" ? Data(blob.utf8) : Data(base64Encoded: blob)
        guard let bytes else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = object["fileName"] as? String ?? "bitwarden-export"
        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do { try bytes.write(to: url, options: .atomic) } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = focusedWindow?.window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(CocoaError(.featureUnsupported))
    }
}
