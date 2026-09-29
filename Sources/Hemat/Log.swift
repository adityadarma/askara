import os

/// App logging. NSLog text is redacted as "<private>" in the unified log on recent macOS,
/// so messages go through os.Logger marked public instead.
/// View with: log stream --predicate 'subsystem == "local.hemat.browser"'
enum Log {
    private static let logger = Logger(subsystem: "local.hemat.browser", category: "app")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
