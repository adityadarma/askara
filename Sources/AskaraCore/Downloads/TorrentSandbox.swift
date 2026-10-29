import Foundation

/// Runs the torrent engine inside a macOS sandbox profile (`sandbox-exec`), so a bug in the engine,
/// which parses data from strangers, cannot be turned into access to the user's files or programs.
///
/// The profile limits the engine to:
/// - reading and writing only the download folder and its own state folder inside the home folder;
/// - starting no other programs (no shell), so an exploit cannot open a remote shell;
/// - no connections to the Mac itself (localhost), so it cannot reach local services.
///
/// It does not block inbound peer connections: BitTorrent needs to listen, and every sandbox rule that
/// refuses connections also stops the engine from binding its port.
public enum TorrentSandbox {
    public static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// False when the system tool is missing. Torrents then do not start at all instead of running unprotected.
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    public static let profile = """
    (version 1)
    (allow default)
    ; Files: nothing in the home folder is readable except the download and state folders.
    (deny file-read* (subpath (param "HOME")))
    (allow file-read-metadata)
    (allow file-read* (subpath (param "DOWNLOADS")) (subpath (param "SUPPORT")))
    (deny file-write*)
    (allow file-write* (subpath (param "DOWNLOADS")) (subpath (param "SUPPORT")) (literal "/dev/null") (subpath "/dev/fd"))
    ; Programs: the engine never needs to start anything else.
    (deny process-fork)
    (deny process-exec*)
    (allow process-exec (literal (param "ENGINE")))
    ; Network: remote peers, trackers and DNS work; the Mac's own services are out of reach.
    (deny network-outbound (remote ip "localhost:*"))
    """

    /// The path with every symbolic link resolved, like `realpath(3)`. The sandbox compares real paths.
    /// Foundation's `resolvingSymlinksInPath()` is not enough: it drops the `/private` prefix, so
    /// `/var/folders/...` would never match the sandbox's `/private/var/folders/...`.
    public static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.path }
        return String(cString: buffer)
    }

    /// Arguments for `sandbox-exec` that run `engine` with `engineArguments` under `profile`.
    /// The folders and the engine must exist, so their real paths can be resolved.
    public static func arguments(home: URL, downloads: URL, support: URL, engine: URL,
                                 engineArguments: [String]) -> [String] {
        func real(_ url: URL) -> String { realPath(url) }
        return ["-p", profile,
                "-D", "HOME=\(real(home))",
                "-D", "DOWNLOADS=\(real(downloads))",
                "-D", "SUPPORT=\(real(support))",
                "-D", "ENGINE=\(real(engine))",
                real(engine)] + engineArguments
    }
}
