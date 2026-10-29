import Foundation

/// Recognises torrent links: `magnet:` URIs and `.torrent` files.
public enum TorrentLink {
    /// A `magnet:` URI with a BitTorrent info hash (`xt=urn:btih:` or `urn:btmh:`).
    public static func isMagnet(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "magnet",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        return items.contains {
            guard $0.name.lowercased() == "xt", let value = $0.value?.lowercased() else { return false }
            return value.hasPrefix("urn:btih:") || value.hasPrefix("urn:btmh:")
        }
    }

    /// An http(s) URL that serves a torrent file, judged by MIME type or file extension.
    public static func isTorrentFile(_ url: URL, mimeType: String? = nil) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if mimeType?.lowercased() == "application/x-bittorrent" { return true }
        return url.pathExtension.lowercased() == "torrent"
    }

    /// True for anything the torrent engine accepts as a source.
    public static func isSupported(_ url: URL, mimeType: String? = nil) -> Bool {
        isMagnet(url) || isTorrentFile(url, mimeType: mimeType)
    }

    /// The `dn=` display name of a magnet link, if present.
    public static func displayName(of url: URL) -> String? {
        guard isMagnet(url) else { return nil }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "dn" }?.value
        let sanitized = name.map(DownloadNaming.sanitize)
        return sanitized == "download" ? nil : sanitized
    }
}

/// One parsed line of `aria2c` console output.
public enum TorrentEvent: Equatable, Sendable {
    /// `total` is 0 until the torrent metadata is known (magnet links).
    case progress(completed: Int64, total: Int64, bytesPerSecond: Int64)
    /// A file the download writes to.
    case file(String)
    case error(String)
}

/// Incremental parser for `aria2c` output (`--summary-interval=1 --human-readable=false`).
public struct TorrentOutputParser: Sendable {
    private var buffer = ""

    public init() {}

    /// Feeds raw output. Lines end in `\n` or `\r`; an incomplete trailing line is kept for the next call.
    public mutating func feed(_ chunk: Data) -> [TorrentEvent] {
        buffer += String(decoding: chunk, as: UTF8.self)
        // Never let a line without terminator grow unbounded.
        if buffer.utf8.count > 65_536 { buffer.removeAll() }
        var events: [TorrentEvent] = []
        while let end = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = String(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
            if let event = Self.parse(line: line) { events.append(event) }
        }
        return events
    }

    private static let progressPattern = try! NSRegularExpression(
        pattern: #"^\[#\w+\s+(\d+)B(?:/(\d+)B)?.*?(?:\bDL:(\d+)B)?"#)
    private static let speedPattern = try! NSRegularExpression(pattern: #"\bDL:(\d+)B"#)

    public static func parse(line: String) -> TorrentEvent? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[#") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = progressPattern.firstMatch(in: line, range: range) else { return nil }
            func number(_ match: NSTextCheckingResult, _ group: Int, in text: String) -> Int64 {
                guard let r = Range(match.range(at: group), in: text) else { return 0 }
                return Int64(text[r]) ?? 0
            }
            let speed = speedPattern.firstMatch(in: line, range: range).map { number($0, 1, in: line) } ?? 0
            return .progress(completed: number(match, 1, in: line), total: number(match, 2, in: line),
                             bytesPerSecond: speed)
        }
        if line.hasPrefix("FILE:") {
            let path = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            // Metadata still being fetched (`[MEMORY]name`) or unknown (`n/a`) is not a real file.
            guard path.hasPrefix("/") else { return nil }
            return .file(path)
        }
        // Fatal causes appear as "... errorCode=N <description>"; the description may end in " URI=...".
        if let range = line.range(of: #"errorCode=\d+ "#, options: .regularExpression) {
            var message = String(line[range.upperBound...])
            if message.hasPrefix("URI=") { return nil }
            if let uri = message.range(of: " URI=") { message = String(message[..<uri.lowerBound]) }
            message = message.trimmingCharacters(in: .whitespaces)
            return message.isEmpty ? nil : .error(message)
        }
        return nil
    }

    /// The top-level item (file or folder) a torrent creates inside `directory`: the file itself for a
    /// single-file torrent, the torrent's folder for a multi-file one. nil if `file` is outside `directory`.
    public static func topLevelItem(of file: String, in directory: URL) -> URL? {
        let base = directory.standardizedFileURL.pathComponents
        let parts = URL(fileURLWithPath: file).standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return directory.standardizedFileURL.appendingPathComponent(parts[base.count])
    }
}
