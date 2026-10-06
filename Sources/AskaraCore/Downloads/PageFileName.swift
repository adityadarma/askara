import Foundation

/// Suggested file names for things saved from a page (PDF, screenshots).
public enum PageFileName {
    /// "Page title.pdf", falling back to the host and then "page". Never contains path separators.
    public static func suggested(title: String, host: String?, pathExtension: String) -> String {
        var base = DownloadNaming.sanitize(title.trimmingCharacters(in: .whitespacesAndNewlines))
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { base = "" }
        if base.isEmpty || base == "download" {
            base = host.map(DownloadNaming.sanitize) ?? ""
        }
        if base.isEmpty || base == "download" { base = "page" }
        // Keep names readable: the file system limit is far higher than any useful title.
        if base.count > 100 { base = String(base.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return pathExtension.isEmpty ? base : "\(base).\(pathExtension)"
    }
}
