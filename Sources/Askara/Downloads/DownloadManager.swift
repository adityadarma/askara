import AppKit
import CryptoKit
import UserNotifications
import WebKit
import AskaraCore

/// Manages browser downloads. Files are saved with unique names.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    final class Item {
        enum State: Equatable {
            case running, finished, cancelled
            case failed(String)
        }

        enum ScanState: Equatable {
            case waiting, scanning, complete, failed(String)
        }

        let id: UUID
        var filename = String(localized: "Waiting…")
        var destination: URL?
        var sourceURL: URL?
        var fraction: Double = 0
        var state: State = .running
        var scanState: ScanState = .waiting
        var sha256: String?
        var risks: [DownloadRisk] = []
        var fileSize: Int64?
        var endedAt: Date?
        weak var download: WKDownload?
        var observation: NSKeyValueObservation?

        init(id: UUID = UUID()) { self.id = id }

        var statusText: String {
            switch state {
            case .running: return fraction > 0 ? "\(Int(fraction * 100))%" : String(localized: "Downloading…")
            case .finished:
                switch scanState {
                case .waiting, .scanning: return String(localized: "Scanning download…")
                case .complete:
                    return risks.isEmpty ? String(localized: "Scanned · no local warning")
                        : String(localized: "Warning: \(riskText)")
                case .failed(let message): return String(localized: "Scan failed: \(message)")
                }
            case .cancelled: return String(localized: "Cancelled")
            case .failed(let message): return String(localized: "Failed: \(message)")
            }
        }


        var requiresOpenConfirmation: Bool {
            guard state == .finished else { return false }
            if case .complete = scanState { return risks.contains(where: \.isHighRisk) }
            return true
        }

        var riskText: String {
            risks.map {
                switch $0 {
                case .executable: String(localized: "executable file")
                case .script: String(localized: "script file")
                case .installer: String(localized: "installer package")
                case .diskImage: String(localized: "disk image")
                case .archive: String(localized: "archive")
                case .disguisedExecutable: String(localized: "executable content with a misleading extension")
                }
            }.joined(separator: ", ")
        }
    }

    private(set) var items: [Item] = []   // newest first
    private let downloadDirectory: URL
    private let historyFile: JSONFile<DownloadHistory>

    init(directory: URL? = nil, historyFile: JSONFile<DownloadHistory>? = nil) {
        downloadDirectory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        self.historyFile = historyFile ?? .inAppSupport("downloads.json")
        super.init()
        items = (self.historyFile.load()?.records ?? []).map(Self.item)
        for item in items where item.state == .finished && item.scanState == .waiting
            && item.destination.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            scan(item)
        }
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        // Without a delegate, macOS hides notifications while Askara is the active app.
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var running: [Item] { items.filter { $0.state == .running } }

    /// Progress for the toolbar ring: nil when nothing runs, 0 while no download has reported
    /// progress yet (size unknown, ring spins), otherwise the average fraction of running downloads.
    var toolbarProgress: Double? { Self.toolbarProgress(fractions: running.map(\.fraction)) }

    nonisolated static func toolbarProgress(fractions: [Double]) -> Double? {
        guard !fractions.isEmpty else { return nil }
        guard fractions.contains(where: { $0 > 0 }) else { return 0 }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    /// Summary for the status bar; nil when no downloads are running.
    var summary: String? {
        let active = running
        guard !active.isEmpty else { return nil }
        let avg = active.map(\.fraction).reduce(0, +) / Double(active.count)
        return String(localized: "Downloading \(active.count) files (\(Int(avg * 100))%)")
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = Item()
        item.download = download
        item.sourceURL = download.originalRequest?.url
        let itemID = item.id
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let item = self.items.first(where: { $0.id == itemID }) else { return }
                    // Throttle notifications: only post when progress rises ≥1%.
                    if fraction - item.fraction >= 0.01 || fraction >= 1 {
                        item.fraction = fraction
                        self.changed()
                    }
                }
            }
        }
        items.insert(item, at: 0)
        changed()
    }

    /// Short message shown as a toast in the active window.
    private func announce(_ text: String) {
        NotificationCenter.default.post(name: .askaraDownloadEvent, object: nil, userInfo: ["text": text])
    }

    func cancel(_ item: Item) {
        guard item.state == .running else { return }
        item.download?.cancel { _ in }
        markCancelled(item)
    }

    func removeFromList(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && $0.state != .running }
        saveHistory()
        changed()
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    private func changed() {
        NotificationCenter.default.post(name: .askaraDownloadsChanged, object: nil)
    }

    private func destination(for suggestedFilename: String) -> URL {
        let reserved = Set(items.compactMap {
            $0.state == .running ? $0.destination?.standardizedFileURL.path : nil
        })
        return DownloadNaming.uniqueURL(in: downloadDirectory, suggested: suggestedFilename) {
            let path = $0.standardizedFileURL.path
            return reserved.contains(path) || FileManager.default.fileExists(atPath: path)
        }
    }

    private func finish(_ item: Item) {
        guard item.state == .running else { return }
        item.state = .finished
        item.endedAt = Date()
        item.fraction = 1
        item.observation = nil
        if let path = item.destination?.path {
            DistributedNotificationCenter.default()
                .post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        announce(String(localized: "Download finished: \(item.filename)"))
        notify(title: String(localized: "Download Complete"), body: item.filename, id: item.id,
               file: item.destination)
        saveHistory()
        changed()
        scan(item)
    }

    private func markCancelled(_ item: Item) {
        guard item.state == .running else { return }
        item.state = .cancelled
        item.endedAt = Date()
        item.observation = nil
        saveHistory(); changed()
    }

    private func fail(_ item: Item, message: String) {
        guard item.state == .running else { return }
        item.state = .failed(message)
        item.endedAt = Date()
        item.observation = nil
        announce(String(localized: "Download failed: \(item.filename)"))
        notify(title: String(localized: "Download Failed"), body: item.filename, id: item.id)
        saveHistory(); changed()
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let destination = destination(for: suggestedFilename)
        if let item = item(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
        }
        announce(String(localized: "Downloading \(destination.lastPathComponent). See Window › Downloads (⌥⌘L)."))
        changed()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        finish(item)
    }

    private func scan(_ item: Item) {
        guard let url = item.destination else { return }
        item.scanState = .scanning
        changed()
        let id = item.id
        Task.detached(priority: .utility) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                var prefix = Data()
                var size: Int64 = 0
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    if prefix.isEmpty { prefix = Data(chunk.prefix(4)) }
                    hash.update(data: chunk)
                    size += Int64(chunk.count)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                let risks = DownloadRiskClassifier.risks(filename: url.lastPathComponent, prefix: prefix)
                let fileSize = size
                await MainActor.run { [weak self] in
                    guard let self, let item = self.items.first(where: { $0.id == id }) else { return }
                    item.sha256 = digest
                    item.fileSize = fileSize
                    item.risks = risks
                    item.scanState = .complete
                    self.saveHistory()
                    self.changed()
                    if risks.contains(where: \.isHighRisk) {
                        self.announce(String(localized: "Download warning: \(item.riskText)"))
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, let item = self.items.first(where: { $0.id == id }) else { return }
                    item.scanState = .failed(error.localizedDescription)
                    self.saveHistory()
                    self.changed()
                }
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        fail(item, message: error.localizedDescription)
    }

    /// Key in a notification's userInfo: the downloaded file's path, revealed in Finder on click.
    nonisolated static let notificationPathKey = "askaraDownloadPath"

    private func notify(title: String, body: String, id: UUID, file: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let file { content.userInfo = [Self.notificationPathKey: file.path] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "download-\(id.uuidString)", content: content, trigger: nil))
    }

    private func saveHistory() {
        let records = items.compactMap(Self.record)
        do { try historyFile.save(DownloadHistory(records: records)) }
        catch { Log.error("Askara: failed to save download history: \(error)") }
    }

    private static func record(_ item: Item) -> DownloadHistory.Record? {
        guard let endedAt = item.endedAt else { return nil }
        let outcome: DownloadHistory.Outcome
        let failure: String?
        switch item.state {
        case .running: return nil
        case .finished: outcome = .finished; failure = nil
        case .cancelled: outcome = .cancelled; failure = nil
        case .failed(let message): outcome = .failed; failure = message
        }
        let scan: DownloadHistory.ScanOutcome
        let scanFailure: String?
        switch item.scanState {
        case .waiting, .scanning: scan = .waiting; scanFailure = nil
        case .complete: scan = .complete; scanFailure = nil
        case .failed(let message): scan = .failed; scanFailure = message
        }
        return .init(id: item.id, filename: item.filename, destination: item.destination,
                     sourceURL: item.sourceURL, endedAt: endedAt, outcome: outcome,
                     failureMessage: failure, scanOutcome: scan, scanFailureMessage: scanFailure,
                     sha256: item.sha256, risks: item.risks, fileSize: item.fileSize)
    }

    private static func item(_ record: DownloadHistory.Record) -> Item {
        let item = Item(id: record.id)
        item.filename = record.filename
        item.destination = record.destination
        item.sourceURL = record.sourceURL
        item.endedAt = record.endedAt
        item.fraction = record.outcome == .finished ? 1 : 0
        switch record.outcome {
        case .finished: item.state = .finished
        case .cancelled: item.state = .cancelled
        case .failed: item.state = .failed(record.failureMessage ?? String(localized: "Unknown error"))
        }
        switch record.scanOutcome {
        case .waiting: item.scanState = .waiting
        case .complete: item.scanState = .complete
        case .failed: item.scanState = .failed(record.scanFailureMessage ?? String(localized: "Unknown error"))
        }
        item.sha256 = record.sha256
        item.risks = record.risks
        item.fileSize = record.fileSize
        return item
    }
}

// MARK: - Notifications

extension DownloadManager: UNUserNotificationCenterDelegate {
    /// Show the banner even while Askara is the active app (macOS hides it by default).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking "Download Complete" reveals the file in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo[Self.notificationPathKey] as? String
        await MainActor.run {
            if let path, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                DownloadsWindowController.shared.show()
            }
        }
    }
}
