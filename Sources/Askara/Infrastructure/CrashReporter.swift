import AppKit
import AskaraCore

private struct CrashIncident: Codable {
    var detectedAt: Date
    var previousLaunch: Date
    var appVersion: String
    var osVersion: String
    var events: [String]
}

/// Detects an unclean prior session. It intentionally does not install unsafe signal handlers.
@MainActor
final class CrashReporter {
    static let shared = CrashReporter()

    private struct Marker: Codable {
        var launchedAt: Date
        var events: [String]
    }

    private let markerFile = JSONFile<Marker>.inAppSupport("Diagnostics/running-session.json")
    private let incidentFile = JSONFile<CrashIncident>.inAppSupport("Diagnostics/previous-session.json")
    private var marker: Marker?

    private init() {}

    var hasReport: Bool { incidentFile.load() != nil }

    func start() {
        if let previous = markerFile.load() {
            let incident = CrashIncident(
                detectedAt: Date(), previousLaunch: previous.launchedAt,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                events: previous.events
            )
            try? incidentFile.save(incident)
        }
        marker = Marker(launchedAt: Date(), events: [])
        saveMarker()
    }

    func record(_ category: String) {
        guard var marker else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        marker.events.append("\(timestamp) \(category)")
        if marker.events.count > 100 { marker.events.removeFirst(marker.events.count - 100) }
        self.marker = marker
        saveMarker()
    }

    func finishCleanly() {
        marker = nil
        try? FileManager.default.removeItem(at: markerFile.url)
    }

    func exportReport(relativeTo window: NSWindow?) {
        guard let incident = incidentFile.load(),
              let data = try? formattedEncoder.encode(incident) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Askara Diagnostic Report.json"
        panel.allowedContentTypes = [.json]
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: [.atomic]) }
            catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) }
        else { save(panel.runModal()) }
    }

    func deleteReport() {
        try? FileManager.default.removeItem(at: incidentFile.url)
    }

    private var formattedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func saveMarker() {
        guard let marker else { return }
        try? markerFile.save(marker)
    }
}
