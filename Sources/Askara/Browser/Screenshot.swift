import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// View > Take Full-Page Screenshot (⇧⌘S) and Take Screenshot of Visible Area (⌥⌘S).
/// PNG, JPG, or PDF. PDF keeps text selectable and handles very long pages better.
/// On a PDF tab the full-page capture renders every page, top to bottom.
extension BrowserWindowController {

    fileprivate enum ShotFormat: Int, CaseIterable {
        case png, jpg, pdf
        var ext: String { ["png", "jpg", "pdf"][rawValue] }
        var title: String { ["PNG", "JPG", "PDF"][rawValue] }
        var type: UTType { [UTType.png, .jpeg, .pdf][rawValue] }
    }

    @objc func fullPageScreenshotAction(_ sender: Any?) { capture(fullPage: true) }
    @objc func visibleScreenshotAction(_ sender: Any?) { capture(fullPage: false) }

    private func capture(fullPage: Bool) {
        guard let web = activeWebViewForCapture, let window else { return }
        let panel = NSSavePanel()
        let format = NSPopUpButton()
        format.addItems(withTitles: ShotFormat.allCases.map(\.title))
        format.setAccessibilityLabel(String(localized: "File format"))
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let accessory = NSStackView(views: [label, format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let host = web.url?.host ?? "page"
        let stamp = Self.fileStamp.string(from: Date())
        panel.nameFieldStringValue = "\(host) \(stamp).png"
        format.target = FormatSwitch.shared
        format.action = #selector(FormatSwitch.changed(_:))
        FormatSwitch.shared.panel = panel

        panel.beginSheetModal(for: window) { [weak self, weak web] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self, let web,
                      let kind = ShotFormat(rawValue: format.indexOfSelectedItem) else { return }
                self.showToast(String(localized: "Capturing page…"), duration: nil)
                guard fullPage else { return self.saveVisible(of: web, kind, to: url) }
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web else { return }
                    if await self.isPDFPage(web) { return self.savePDFTab(web, as: kind, to: url) }
                    if kind == .pdf { self.savePDF(of: web, to: url) } else { self.saveImage(of: web, kind, to: url) }
                }
            }
        }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private func savePDF(of web: WKWebView, to url: URL) {
        web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let data): self?.write(data, to: url)
                case .failure(let error): self?.captureFailed(error)
                }
            }
        }
    }

    /// PDF tab: PDF output is the original file; PNG/JPG stack every page top to bottom.
    private func savePDFTab(_ web: WKWebView, as kind: ShotFormat, to url: URL) {
        Task { @MainActor [weak self, weak web] in
            guard let self, let web else { return }
            guard let data = await self.fetchPDFData(from: web) else { return self.captureFailed(nil) }
            if kind == .pdf { return self.write(data, to: url) }
            guard let document = PDFDocument(data: data), let rep = Self.renderStacked(document),
                  let out = Self.encode(rep, kind) else { return self.captureFailed(nil) }
            self.write(out, to: url)
        }
    }

    /// Full page like Chrome's: the page view is made tall enough for every large scroll area (page,
    /// sidebar, content panel) to show all its content, then captured in one snapshot.
    private func saveImage(of web: WKWebView, _ kind: ShotFormat, to url: URL) {
        Task { @MainActor [weak self, weak web] in
            guard let self, let web else { return }
            guard let result = await PageCapture.fullPage(of: web), let data = Self.encode(result.image, kind) else {
                return self.captureFailed(nil)
            }
            self.write(data, to: url)
            if result.truncated {
                self.showToast(String(localized: "Page is very long: the image was cut. Use PDF for the whole page."), duration: 5)
            }
        }
    }

    private func saveVisible(of web: WKWebView, _ kind: ShotFormat, to url: URL) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let image, let data = Self.encode(image, kind) else { return self.captureFailed(error) }
                self.write(data, to: url)
            }
        }
    }

    private static func encode(_ image: NSImage, _ kind: ShotFormat) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        if kind == .pdf {
            let document = PDFDocument()
            guard let page = PDFPage(image: image) else { return nil }
            document.insert(page, at: 0)
            return document.dataRepresentation()
        }
        return encode(rep, kind)
    }

    private static func encode(_ rep: NSBitmapImageRep, _ kind: ShotFormat) -> Data? {
        switch kind {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .pdf:
            let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            image.addRepresentation(rep)
            return encode(image, .pdf)
        }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            showToast(String(localized: "Screenshot saved: \(url.lastPathComponent)"), duration: 3)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            captureFailed(error)
        }
    }

    private func captureFailed(_ error: Error?) {
        Log.error("Askara: screenshot failed: \(String(describing: error))")
        showToast(String(localized: "Couldn't take the screenshot."), duration: 3)
    }
}

/// Keeps the save panel's file extension in sync with the format popup.
@MainActor
private final class FormatSwitch: NSObject {
    static let shared = FormatSwitch()
    weak var panel: NSSavePanel?

    @objc func changed(_ sender: NSPopUpButton) {
        guard let panel else { return }
        let ext = ["png", "jpg", "pdf"][max(0, min(2, sender.indexOfSelectedItem))]
        panel.allowedContentTypes = [[UTType.png, .jpeg, .pdf][max(0, min(2, sender.indexOfSelectedItem))]]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + ext
    }
}
