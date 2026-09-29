import AppKit

/// Site favicons for tabs. Stored per host in memory and on disk (32×32 PNG, a few KB),
/// so sleeping or session-restored tabs still show their icon without loading the page.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    /// List of icons declared by the page (`<link rel="icon">`, `apple-touch-icon`).
    static let script = """
    (() => {
      const out = [];
      for (const link of document.querySelectorAll('link[rel][href]')) {
        const rel = link.rel.toLowerCase().split(/\\s+/);
        const touch = rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed');
        if (!rel.includes('icon') && !touch) continue;
        out.push({ href: link.href, sizes: link.getAttribute('sizes') || '', touch });
      }
      return out;
    })();
    """

    private var memory: [String: NSImage] = [:]
    /// Hosts with no file on disk, so the disk isn't read repeatedly.
    private var missingOnDisk: Set<String> = []
    private var inFlight: Set<String> = []
    /// Hosts whose icon was refreshed since the app launched (once per session is enough).
    private var refreshed: Set<String> = []
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hemat/Favicons", isDirectory: true)

    /// No cookies: icon requests carry no login data.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) \(UserAgent.applicationName)"]
        return URLSession(configuration: config)
    }()

    func icon(for url: URL?) -> NSImage? {
        guard let host = Self.host(of: url) else { return nil }
        if let image = memory[host] { return image }
        guard !missingOnDisk.contains(host) else { return nil }
        if let data = try? Data(contentsOf: file(for: host)), let image = Self.image(fromPNG: data) {
            memory[host] = image
            return image
        }
        missingOnDisk.insert(host)
        return nil
    }

    /// Downloads the best icon from the page candidates, then `/favicon.ico` as a fallback.
    /// `persist: false` for private windows: the icon is kept in memory only.
    func update(pageURL: URL, candidates: [[String: Any]], persist: Bool,
                onChange: @escaping @MainActor () -> Void) {
        guard let host = Self.host(of: pageURL), !inFlight.contains(host), !refreshed.contains(host) else { return }
        inFlight.insert(host)
        var urls = Self.rank(candidates)
        if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL, !urls.contains(fallback) {
            urls.append(fallback)
        }
        Task { @MainActor in
            let png = await Self.download(Array(urls.prefix(4)))
            inFlight.remove(host)
            refreshed.insert(host)
            guard let png, let image = Self.image(fromPNG: png) else { return }
            memory[host] = image
            missingOnDisk.remove(host)
            if persist {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? png.write(to: file(for: host), options: .atomic)
            }
            onChange()
        }
    }

    func removeAll() {
        memory.removeAll()
        refreshed.removeAll()
        missingOnDisk.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    private func file(for host: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent(safe + ".png")
    }

    /// Regular icons first (size closest to 32 px), apple-touch-icon as a fallback.
    private static func rank(_ candidates: [[String: Any]]) -> [URL] {
        func size(_ text: String) -> Int {
            if text.lowercased() == "any" { return 64 } // usually SVG
            return Int(text.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 16
        }
        return candidates
            .compactMap { item -> (url: URL, touch: Bool, distance: Int)? in
                guard let href = item["href"] as? String, let url = URL(string: href),
                      ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return (url, item["touch"] as? Bool ?? false, abs(size(item["sizes"] as? String ?? "") - 32))
            }
            .sorted { ($0.touch ? 1 : 0, $0.distance) < ($1.touch ? 1 : 0, $1.distance) }
            .map(\.url)
    }

    /// Download candidates one by one; the first valid result is converted to a 32×32 PNG.
    private nonisolated static func download(_ urls: [URL]) async -> Data? {
        for url in urls {
            guard let (data, response) = try? await session.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
            guard data.count < 1_000_000, let png = resizedPNG(data) else { continue }
            return png
        }
        return nil
    }

    private nonisolated static func resizedPNG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// 32 px shown as 16 pt (sharp on Retina displays).
    private static func image(fromPNG data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
