import AppKit
import WebKit

extension Notification.Name {
    static let askaraExtensionsChanged = Notification.Name("AskaraExtensionsChanged")
}

/// A Safari extension (Web Extension) found inside an installed app.
struct InstalledExtension: Equatable {
    let bundleID: String
    let name: String
    let bundleURL: URL
}

/// Loads installed Safari extensions (e.g. Bitwarden) via the WKWebExtension API.
///
/// Extensions load only after the user enables them and approves their permissions. That choice is saved,
/// and approved permissions are re-granted every time the app launches.
@MainActor
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    private enum Keys {
        static let enabled = "AskaraEnabledExtensions"
        static let identifiers = "AskaraExtensionIdentifiers"
    }

    let controller: WKWebExtensionController
    private(set) var installed: [InstalledExtension] = []
    /// Stable order (matching the installed list) so toolbar buttons don't move around.
    private(set) var loaded: [(item: InstalledExtension, context: WKWebExtensionContext)] = []
    private var enabledIDs: Set<String>
    private var services: BrowserServices { .shared }

    override init() {
        // Default configuration = persistent storage, so extension logins/vaults survive a restart.
        let configuration = WKWebExtensionController.Configuration.default()
        // Extension pages (background, popup) also need the Safari user agent; Bitwarden uses it
        // to identify the browser.
        let webConfig = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webConfig.applicationNameForUserAgent = UserAgent.applicationName
        configuration.webViewConfiguration = webConfig
        controller = WKWebExtensionController(configuration: configuration)
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.enabled) ?? [])
        super.init()
        controller.delegate = self
    }

    // MARK: - Discovery & loading

    func start() {
        Task { @MainActor in
            // The app folder scan runs off the main thread.
            self.installed = await Task.detached(priority: .utility) { Self.discover() }.value
            for item in self.installed where self.enabledIDs.contains(item.bundleID) {
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

    func isEnabled(_ item: InstalledExtension) -> Bool { enabledIDs.contains(item.bundleID) }

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
        let context = WKWebExtensionContext(for: ext)
        // Stable ID per extension: extension storage (vault, settings) is tied to this ID.
        context.uniqueIdentifier = stableIdentifier(for: item.bundleID)
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
        NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification,
                                               object: context, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let context = note.object as? WKWebExtensionContext else { return }
                for error in context.errors { Log.error("Askara extension \(item.name): \(error.localizedDescription)") }
            }
        }
        context.errors.forEach { Log.error("Askara extension \(item.name): \($0.localizedDescription)") }
        // Load the background page now so the popup doesn't lag on the first click.
        context.loadBackgroundContent { error in
            if let error { Log.error("Askara extension \(item.name): background failed: \(error)") }
        }
        loaded.sort { a, b in
            (installed.firstIndex(of: a.item) ?? 0) < (installed.firstIndex(of: b.item) ?? 0)
        }
    }

    private func stableIdentifier(for bundleID: String) -> String {
        var map = UserDefaults.standard.dictionary(forKey: Keys.identifiers) as? [String: String] ?? [:]
        if let existing = map[bundleID] { return existing }
        let id = UUID().uuidString
        map[bundleID] = id
        UserDefaults.standard.set(map, forKey: Keys.identifiers)
        return id
    }

    private func saveEnabled() {
        UserDefaults.standard.set(enabledIDs.sorted(), forKey: Keys.enabled)
    }

    private func changed() {
        NotificationCenter.default.post(name: .askaraExtensionsChanged, object: nil)
    }

    /// Extension internal page URLs (popup, settings) must not be blocked by the navigation policy.
    func isExtensionURL(_ url: URL) -> Bool { controller.extensionContext(for: url) != nil }

    /// Extension pages (e.g. Bitwarden's passkey confirmation window) only load with that extension's
    /// WebView configuration; with a normal tab configuration the page is blank.
    func webViewConfiguration(for url: URL?) -> WKWebViewConfiguration? {
        guard let url, url.scheme == "webkit-extension" else { return nil }
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
        services.windows
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        services.keyBrowserWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindowController)
            ?? services.windows.last { !$0.isPrivate }
            ?? services.makeWindow(isPrivate: false)
        let tab = window.insertTab(url: configuration.url, at: configuration.index,
                                   activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = services.makeWindow(isPrivate: false)
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
        services.open(url, newTab: true, nonPrivate: true)
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
        guard let window = services.keyBrowserWindow?.window else {
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
        let window = (action.associatedTab as? Tab)?.owner ?? services.keyBrowserWindow
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
            let window = services.keyBrowserWindow
            extensionContext.performAction(for: window?.currentTab)
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
        if let window = services.keyBrowserWindow?.window {
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

// MARK: - Tab as WKWebExtensionTab

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
