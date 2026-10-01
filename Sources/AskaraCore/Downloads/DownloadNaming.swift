import Foundation

/// Safe download file naming that never overwrites existing files.
public enum DownloadNaming {
    /// Strips dangerous characters/path separators from the server-suggested name.
    public static func sanitize(_ suggested: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        var name = suggested.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Prevent hidden files and ".." names.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }
        // Limit length to stay safe for the file system (255 bytes).
        while name.utf8.count > 200 { name.removeFirst() }
        return name
    }

    /// "a.pdf" becomes "a (1).pdf", "a (2).pdf", etc. if it already exists.
    public static func uniqueURL(in directory: URL, suggested: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = sanitize(suggested)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 1
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}
