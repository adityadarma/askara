import Foundation
import AskaraCore

/// Runs one bundled `aria2c` process for a magnet link or `.torrent` file and reports its progress.
/// aria2c is a separate executable (GPL-2.0-or-later), never linked into Askara.
@MainActor
final class TorrentProcess {
    enum Source {
        case magnet(URL)
        case file(URL)

        var argument: String {
            switch self {
            case .magnet(let url): url.absoluteString
            // A .torrent link is fetched by aria2 itself over http(s); a local file is passed by path.
            case .file(let url): url.isFileURL ? url.path : url.absoluteString
            }
        }
    }

    /// Location of the bundled engine; nil when running outside an app bundle (`swift run`, tests).
    nonisolated static var executableURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "aria2c") }

    /// Parser state touched only from the pipe's read queue.
    private final class ParserBox: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = TorrentOutputParser()

        func feed(_ data: Data) -> [TorrentEvent] {
            lock.lock(); defer { lock.unlock() }
            return parser.feed(data)
        }
    }

    private let process = Process()
    private let pipe = Pipe()
    private(set) var isCancelled = false
    private(set) var lastError: String?

    var onEvent: ((TorrentEvent) -> Void)?
    /// Called once with the exit status, unless the job was cancelled.
    var onExit: ((Int32) -> Void)?

    /// True when the engine and the sandbox tool are both present. Without the sandbox nothing starts.
    nonisolated static var isAvailable: Bool { executableURL != nil && TorrentSandbox.isAvailable }

    /// `stateDirectory` holds the DHT state and is the only folder besides `directory` the engine may touch.
    init?(source: Source, directory: URL, stateDirectory: URL, usesDHT: Bool = true,
          executable: URL? = TorrentProcess.executableURL) {
        guard let executable, TorrentSandbox.isAvailable else { return nil }
        let dhtFile = stateDirectory.appendingPathComponent("dht.dat")
        var arguments = [
            "--no-conf=true",
            "--enable-color=false",
            "--console-log-level=warn",
            "--summary-interval=1",
            "--download-result=hide",
            "--human-readable=false",
            "--file-allocation=none",
            "--allow-overwrite=false",
            "--auto-file-renaming=true",
            // Stop once complete instead of seeding indefinitely.
            "--seed-time=0",
        ]
        if usesDHT {
            arguments += ["--enable-dht=true", "--enable-dht6=true",
                          "--dht-file-path=\(dhtFile.path)", "--dht-file-path6=\(dhtFile.path)6"]
        } else {
            arguments += ["--enable-dht=false", "--enable-dht6=false"]
        }
        arguments += [
            "--bt-save-metadata=false",
            // Never outlive Askara, even after a crash or force quit.
            "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)",
            "--dir=\(TorrentSandbox.realPath(directory))",
            "--", source.argument,
        ]
        process.executableURL = TorrentSandbox.executable
        process.arguments = TorrentSandbox.arguments(
            home: URL(fileURLWithPath: NSHomeDirectory()), downloads: directory, support: stateDirectory,
            engine: executable, engineArguments: arguments)
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        try process.run()
        let box = ParserBox()
        let handle = pipe.fileHandleForReading
        let process = self.process
        // One reader drains the pipe until EOF, so every output line is delivered before the exit
        // callback. A termination handler could fire first and lose the error text.
        Thread.detachNewThread { [weak self] in
            while case let data = handle.availableData, !data.isEmpty {
                let events = box.feed(data)
                guard !events.isEmpty else { continue }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for event in events {
                            if case .error(let message) = event { self.lastError = message }
                            self.onEvent?(event)
                        }
                    }
                }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isCancelled else { return }
                    self.onExit?(status)
                }
            }
        }
    }

    /// Text for a failed run. Known exit codes win: `lastError` can come from a dead tracker, which
    /// aria2 survives, so it only explains the failure when the exit code says nothing specific.
    func failureMessage(status: Int32) -> String {
        if let known = Self.knownDescription(exitStatus: status) { return known }
        return lastError ?? Self.describe(exitStatus: status)
    }

    /// aria2c exit codes (https://aria2.github.io/manual/en/html/aria2c.html#exit-status).
    nonisolated static func describe(exitStatus status: Int32) -> String {
        knownDescription(exitStatus: status) ?? String(localized: "Torrent engine stopped (code \(status)).")
    }

    nonisolated static func knownDescription(exitStatus status: Int32) -> String? {
        switch status {
        case 2: String(localized: "Torrent download timed out.")
        case 3: String(localized: "Torrent file not found.")
        case 6: String(localized: "Network problem while downloading the torrent.")
        case 9: String(localized: "Not enough disk space for the torrent.")
        case 13: String(localized: "A file with this name already exists.")
        case 16, 17, 18: String(localized: "Could not write the torrent files to the Downloads folder.")
        case 19: String(localized: "Could not resolve the torrent host.")
        case 22, 23, 24, 29: String(localized: "The server refused the torrent download.")
        case 25, 26, 27: String(localized: "The torrent file or magnet link is invalid.")
        default: nil
        }
    }

    func cancel() {
        isCancelled = true
        if process.isRunning { process.terminate() }
    }
}
