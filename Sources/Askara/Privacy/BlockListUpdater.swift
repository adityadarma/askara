import AppKit
import WebKit
import AskaraCore

/// Automatically updates the ad blocklist from the internet, once a day.
///
/// Source: Peter Lowe's list (pgl.yoyo.org), about 3,500 ad/tracker domains, updated regularly.
/// The request is a plain GET over HTTPS; no user data is sent.
/// If the download fails, the last saved list (or the built-in list) stays in use.
@MainActor
final class BlockListUpdater {
    static let sourceURL = URL(string:
        "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext")!
    private static let ruleListID = "askara-blocklist"
    nonisolated private static let maxDownloadBytes = 5 * 1_048_576
    /// A list that is too small is most likely broken or an error page; don't use it.
    private static let minimumDomains = 500

    private let domainsFile: JSONFile<[String]>
    private let metadataFile: JSONFile<BlockListMetadata>
    private let customFile: JSONFile<[String]>
    private let hideFile: JSONFile<[ElementHideRule]>
    private weak var services: BrowserServices?
    private(set) var metadata: BlockListMetadata
    private(set) var isUpdating = false
    /// Everything that is blocked: automatic and manual domains together.
    private(set) var currentDomains: [String] { didSet { blockedSet = Set(currentDomains) } }
    private var blockedSet: Set<String> = []
    /// Built-in plus downloaded domains. Read-only for the user.
    private(set) var automaticDomains: [String]
    /// Domains the user blocked by hand (Askara > Blocked Domains…).
    private(set) var customDomains: [String]
    /// Element-hiding rules the user wrote by hand (`site##selector`).
    private(set) var hideRules: [ElementHideRule]
    private var timer: Timer?

    /// Called each time a new list finishes compiling.
    var onCompiled: ((WKContentRuleList) -> Void)?
    var onDomainsChanged: (([String]) -> Void)?

    init(storageDirectory: URL? = nil, services: BrowserServices) {
        self.services = services
        if let storageDirectory {
            domainsFile = JSONFile(url: storageDirectory.appendingPathComponent("blocklist-domains.json"))
            metadataFile = JSONFile(url: storageDirectory.appendingPathComponent("blocklist-meta.json"))
            customFile = JSONFile(url: storageDirectory.appendingPathComponent("blocklist-custom.json"))
            hideFile = JSONFile(url: storageDirectory.appendingPathComponent("blocklist-hide.json"))
        } else {
            domainsFile = .inAppSupport("blocklist-domains.json")
            metadataFile = .inAppSupport("blocklist-meta.json")
            customFile = .inAppSupport("blocklist-custom.json")
            hideFile = .inAppSupport("blocklist-hide.json")
        }
        hideRules = hideFile.load() ?? []
        metadata = metadataFile.load() ?? BlockListMetadata()
        // First launch: no file yet, so seed it. Later edits (even an empty list) are kept as saved.
        let custom: [String]
        if let saved = customFile.load() {
            custom = saved
        } else {
            custom = BlockList.initialCustomDomains
            try? customFile.save(custom)
        }
        customDomains = custom
        automaticDomains = BlockList.merged(with: domainsFile.load() ?? [])
        let merged = BlockList.merged(with: automaticDomains + custom)
        currentDomains = merged
        blockedSet = Set(merged)
    }

    /// True if `host` or one of its parent domains is on the block list.
    func isBlocked(host: String) -> Bool {
        SiteSettings.candidates(for: host).contains(where: blockedSet.contains)
    }

    /// Compiles the saved (or built-in) list, then checks for updates in the background.
    func start() {
        compile(downloaded: domainsFile.load() ?? [])
        checkIfNeeded()
        // Check hourly whether it's time (once a day). Large tolerance to save CPU.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfNeeded() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfNeeded() {
        if metadata.needsCheck() { update(force: false, completion: nil) }
    }

    /// Rebuilds the current list after a per-site exception changes.
    func recompile() { compile(downloaded: domainsFile.load() ?? []) }

    /// Replaces the manual block list, saves it and rebuilds the rules.
    func setCustomDomains(_ domains: [String]) {
        customDomains = domains
        do { try customFile.save(domains) } catch { Log.error("Askara: failed to save custom blocklist: \(error)") }
        recompile()
    }

    /// Replaces the element-hiding rules, saves them and rebuilds the rules.
    func setHideRules(_ rules: [ElementHideRule]) {
        hideRules = Array(rules.prefix(ElementHideRule.maxRules))
        do { try hideFile.save(hideRules) } catch { Log.error("Askara: failed to save hide rules: \(error)") }
        recompile()
    }

    /// `force` ignores ETag/Last-Modified and the daily schedule (for the "Update Now" menu).
    func update(force: Bool, completion: ((String) -> Void)?) {
        guard !isUpdating else {
            completion?(String(localized: "Update already in progress"))
            return
        }
        isUpdating = true

        var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        if !force {
            if let etag = metadata.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = metadata.lastModified {
                request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            // Parse on a background thread so the UI doesn't stutter.
            let http = response as? HTTPURLResponse
            var domains: [String]?
            if error == nil, http?.statusCode == 200, let data, data.count <= Self.maxDownloadBytes {
                domains = BlockListParser.parseDomains(String(decoding: data, as: UTF8.self))
            }
            let status = http?.statusCode
            let etag = http?.value(forHTTPHeaderField: "ETag")
            let modified = http?.value(forHTTPHeaderField: "Last-Modified")
            let errorText = error?.localizedDescription

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let message = self.finish(status: status, domains: domains, etag: etag,
                                              lastModified: modified, error: errorText)
                    completion?(message)
                }
            }
        }.resume()
    }

    private func finish(status: Int?, domains: [String]?, etag: String?, lastModified: String?,
                        error: String?) -> String {
        isUpdating = false
        let now = Date()

        if status == 304 {
            metadata.lastChecked = now
            saveMetadata()
            return String(localized: "Blocklist is up to date (\(metadata.domainCount) domains)")
        }
        guard let domains, domains.count >= Self.minimumDomains else {
            // Don't mark as checked, so it retries next hour.
            let reason = error ?? (status.map { "HTTP \($0)" } ?? String(localized: "no response"))
            Log.error("Askara: failed to update blocklist: \(reason)")
            return String(localized: "Couldn’t update blocklist: \(reason). The previous list is still in use.")
        }

        do { try domainsFile.save(domains) } catch { Log.error("Askara: failed to save blocklist: \(error)") }
        metadata = BlockListMetadata(lastChecked: now, lastUpdated: now, etag: etag,
                                     lastModified: lastModified, domainCount: domains.count)
        saveMetadata()
        compile(downloaded: domains)
        return String(localized: "Blocklist updated: \(domains.count) domains")
    }

    private func saveMetadata() {
        do { try metadataFile.save(metadata) } catch { Log.error("Askara: failed to save blocklist metadata: \(error)") }
    }

    private func compile(downloaded: [String]) {
        automaticDomains = BlockList.merged(with: downloaded)
        let domains = BlockList.merged(with: automaticDomains + customDomains)
        currentDomains = domains
        onDomainsChanged?(domains)
        let json = BlockList.contentRuleListJSON(
            domains: domains,
            excludingSites: services?.siteSettings.adBlockExceptions ?? [],
            hiding: hideRules
        )
        // The same identifier overwrites the old version; WebKit stores the compiled result on disk.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleListID, encodedContentRuleList: json
        ) { list, error in
            MainActor.assumeIsolated {
                if let error { Log.error("Askara: failed to compile blocklist: \(error)") }
                if let list { self.onCompiled?(list) }
            }
        }
    }

    /// Summary for the menu.
    var statusText: String {
        let count = currentDomains.count
        guard let updated = metadata.lastUpdated else { return String(localized: "Blocking \(count) domains (built-in list)") }
        let formatter = RelativeDateTimeFormatter()
        return String(localized: "Blocking \(count) domains · updated \(formatter.localizedString(for: updated, relativeTo: Date()))")
    }
}
