import AppKit
import PDFKit
import WebKit

/// PDF tabs: WebKit shows the PDF in its built-in viewer, which scrolls internally, so page
/// snapshots only see the visible part. These helpers read the original bytes instead.
extension BrowserWindowController {
    /// Longest side of a rendered PDF image, in pixels. Longer documents are scaled down to fit.
    private static let maxPDFImageHeight: CGFloat = 30_000
    private static let pageGap: CGFloat = 8

    /// True when the page is a PDF: navigation MIME type, `.pdf` URL, or the document's own content type.
    func isPDFPage(_ web: WKWebView) async -> Bool {
        if currentTab?.isPDFDocument == true { return true }
        if web.url?.pathExtension.lowercased() == "pdf" { return true }
        let type = try? await web.evaluateJavaScript("document.contentType") as? String
        return type?.lowercased().contains("pdf") == true
    }

    /// Original PDF bytes of the page in `web`: local file, or the URL fetched with the tab's cookies.
    func fetchPDFData(from web: WKWebView) async -> Data? {
        guard let url = web.url else { return nil }
        if url.isFileURL { return try? Data(contentsOf: url) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url)
        if let agent = web.customUserAgent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        let host = url.host?.lowercased() ?? ""
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased().drop { $0 == "." }
            return host == domain || host.hasSuffix("." + domain)
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return data
    }

    /// Every page of the PDF stacked from top to bottom in one bitmap.
    static func renderStacked(_ document: PDFDocument) -> NSBitmapImageRep? {
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        guard !pages.isEmpty else { return nil }
        let boxes = pages.map { $0.bounds(for: .mediaBox) }
        let width = boxes.map(\.width).max() ?? 0
        let height = boxes.map(\.height).reduce(0, +) + pageGap * CGFloat(pages.count - 1)
        guard width > 0, height > 0 else { return nil }
        let scale = min(2, maxPDFImageHeight / height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: max(1, Int(width * scale)), pixelsHigh: max(1, Int(height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        cg.scaleBy(x: scale, y: scale)
        // The bitmap origin is bottom-left: draw the first page at the top.
        var top = height
        for (page, box) in zip(pages, boxes) {
            top -= box.height
            cg.saveGState()
            cg.translateBy(x: (width - box.width) / 2 - box.minX, y: top - box.minY)
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(box)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
            top -= pageGap
        }
        return rep
    }
}
