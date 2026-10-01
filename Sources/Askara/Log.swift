import os

/// App logging. NSLog text is redacted as "<private>" in the unified log on recent macOS,
/// so messages go through os.Logger marked public instead.
/// View with: log stream --predicate 'subsystem == "dev.adityadarma.askara"'
enum Log {
    private static let logger = Logger(subsystem: "dev.adityadarma.askara", category: "app")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Task { @MainActor in CrashReporter.shared.record("error: \(redacted(message))") }
    }

    /// Why tabs slept or reloaded. Not persisted by default; visible in `log stream`.
    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        Task { @MainActor in CrashReporter.shared.record("notice: \(redacted(message))") }
    }

    private static func redacted(_ message: String) -> String {
        String(message.prefix(500)).replacingOccurrences(of: #"https?://[^\s]+"#,
                                                          with: "<url>", options: .regularExpression)
    }
}
