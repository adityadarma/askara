import AppKit
import WebKit
import AskaraCore

/// Manages WebKit downloads. Files are saved to ~/Downloads with unique names.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    final class Item {
        enum State: Equatable {
            case running, finished, cancelled
            case failed(String)
        }

        let id = UUID()
        var filename = String(localized: "Waiting…")
        var destination: URL?
        var sourceURL: URL?
        var fraction: Double = 0
        var state: State = .running
        weak var download: WKDownload?
        var observation: NSKeyValueObservation?

        var statusText: String {
            switch state {
            case .running: return fraction > 0 ? "\(Int(fraction * 100))%" : String(localized: "Downloading…")
            case .finished: return String(localized: "Finished")
            case .cancelled: return String(localized: "Cancelled")
            case .failed(let message): return String(localized: "Failed: \(message)")
            }
        }
    }

    private(set) var items: [Item] = []   // newest first

    var running: [Item] { items.filter { $0.state == .running } }

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
        item.state = .cancelled
        item.observation = nil
        changed()
    }

    func removeFromList(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && $0.state != .running }
        changed()
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    private func changed() {
        NotificationCenter.default.post(name: .askaraDownloadsChanged, object: nil)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Avoid clashing with existing files and other running downloads.
        let reserved = Set(items.compactMap { $0.state == .running ? $0.destination?.path : nil })
        let destination = DownloadNaming.uniqueURL(in: directory, suggested: suggestedFilename) {
            reserved.contains($0.path) || FileManager.default.fileExists(atPath: $0.path)
        }
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
        item.state = .finished
        item.fraction = 1
        item.observation = nil
        if let path = item.destination?.path {
            // Makes the Downloads stack in the Dock bounce, like Safari.
            DistributedNotificationCenter.default()
                .post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        announce(String(localized: "Download finished: \(item.filename)"))
        changed()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state == .running else { return }
        item.state = .failed(error.localizedDescription)
        item.observation = nil
        announce(String(localized: "Download failed: \(item.filename)"))
        changed()
    }
}
