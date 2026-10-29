import Foundation

/// Result of scanning a downloaded folder (a multi-file torrent).
public struct DownloadFolderScan: Equatable, Sendable {
    public var size: Int64 = 0
    public var fileCount = 0
    public var risks: [DownloadRisk] = []
    /// The folder held more entries than the scan looks at; the rest were not checked.
    public var truncated = false
}

public enum DownloadFolderScanner {
    /// Classifies every file in `root` like a single download: by name and by the first bytes.
    /// Packages (`.app`, `.pkg`, ...) are judged by name and not entered. Symbolic links are skipped.
    public static func scan(_ root: URL, maxEntries: Int = 200_000) -> DownloadFolderScan {
        var result = DownloadFolderScan()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return result }
        var seen = Set<DownloadRisk>()
        func add(_ found: [DownloadRisk]) {
            for risk in found where seen.insert(risk).inserted { result.risks.append(risk) }
        }
        var entries = 0
        for case let url as URL in walker {
            entries += 1
            if entries > maxEntries { result.truncated = true; break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isPackage == true {
                add(DownloadRiskClassifier.risks(filename: url.lastPathComponent))
                continue
            }
            guard values.isRegularFile == true else { continue }
            result.fileCount += 1
            result.size += Int64(values.fileSize ?? 0)
            var prefix = Data()
            if let handle = try? FileHandle(forReadingFrom: url) {
                prefix = (try? handle.read(upToCount: 4)) ?? Data()
                try? handle.close()
            }
            add(DownloadRiskClassifier.risks(filename: url.lastPathComponent, prefix: prefix))
        }
        return result
    }
}

/// Marks downloaded files with `com.apple.quarantine`, so Gatekeeper and XProtect check them on first
/// open. WebKit does this for normal downloads; files written by another process need it explicitly.
public enum DownloadQuarantine {
    /// Quarantines `root`, and everything inside it if it is a folder. Symbolic links are left alone,
    /// because setting the flag would follow them to their target.
    public static func apply(to root: URL, agentName: String, sourceURL: URL? = nil) {
        var properties: [String: Any] = [
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
            "LSQuarantineAgentName": agentName,
            "LSQuarantineTimeStamp": Date(),
        ]
        if let sourceURL, ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") {
            properties["LSQuarantineDataURL"] = sourceURL.absoluteString
        }
        func mark(_ url: URL) {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return }
            var values = URLResourceValues()
            values.quarantineProperties = properties
            var target = url
            try? target.setResourceValues(values)
        }
        mark(root)
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in walker { mark(url) }
        }
    }

    /// Whether `url` carries the quarantine flag.
    public static func isQuarantined(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties) != nil
    }
}
