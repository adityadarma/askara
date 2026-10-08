import Foundation

/// Other browsers for Develop > Open Page With. Only the installed ones are shown.
public struct ExternalBrowser: Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public static let known: [ExternalBrowser] = [
        ExternalBrowser(bundleID: "com.apple.Safari", name: "Safari"),
        ExternalBrowser(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview"),
        ExternalBrowser(bundleID: "com.google.Chrome", name: "Google Chrome"),
        ExternalBrowser(bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary"),
        ExternalBrowser(bundleID: "org.chromium.Chromium", name: "Chromium"),
        ExternalBrowser(bundleID: "org.mozilla.firefox", name: "Firefox"),
        ExternalBrowser(bundleID: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition"),
        ExternalBrowser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        ExternalBrowser(bundleID: "com.brave.Browser", name: "Brave"),
        ExternalBrowser(bundleID: "company.thebrowser.Browser", name: "Arc"),
        ExternalBrowser(bundleID: "com.operasoftware.Opera", name: "Opera"),
        ExternalBrowser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        ExternalBrowser(bundleID: "com.kagi.kagimacOS", name: "Orion"),
        ExternalBrowser(bundleID: "app.zen-browser.zen", name: "Zen"),
    ]
}
