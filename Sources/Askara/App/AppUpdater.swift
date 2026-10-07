import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed (`SUFeedURL`) and EdDSA public key (`SUPublicEDKey`)
/// are written into Info.plist by `scripts/bundle.sh`. Development builds without a public key
/// leave the updater off, so "Check for Updates…" stays disabled instead of failing.
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?
    private var started = false

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasKey = !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        let hasFeed = !((info["SUFeedURL"] as? String) ?? "").isEmpty
        // Started manually in start() so a configuration error is logged instead of only
        // surfacing as Sparkle's generic "updater failed to start" alert.
        controller = (hasKey && hasFeed)
            ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        super.init()
    }

    /// Starts the updater and checks for updates on every launch, not only when Sparkle's 24 h
    /// schedule is due. The background check shows UI only when a newer version is available.
    func start() {
        guard let controller, !started else { return }
        do {
            try controller.updater.start()
            started = true
            // Respect a user who turned automatic checks off in Sparkle's prompt or settings.
            if controller.updater.automaticallyChecksForUpdates {
                controller.updater.checkForUpdatesInBackground()
            }
        } catch {
            Log.error("Updater failed to start: \(error.localizedDescription)")
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        started && (controller?.updater.canCheckForUpdates ?? false)
    }
}
