import AppKit
import UniformTypeIdentifiers
import WebKit

/// View > Take Full-Page Screenshot (⇧⌘S): the whole page, not just the visible part.
/// PNG by default; PDF keeps text selectable and handles very long pages better.
extension BrowserWindowController {
    /// Longest PNG side. Very long pages (endless feeds) are cut here; PDF has no such limit.
    private static let maxShotHeight: CGFloat = 20_000

    @objc func fullPageScreenshotAction(_ sender: Any?) {
        guard let web = activeWebViewForCapture, let window else { return }
        let panel = NSSavePanel()
        let format = NSPopUpButton()
        format.addItems(withTitles: ["PNG", "PDF"])
        format.setAccessibilityLabel(String(localized: "File format"))
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let accessory = NSStackView(views: [label, format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.png]
        let host = web.url?.host ?? "page"
        let stamp = Self.fileStamp.string(from: Date())
        panel.nameFieldStringValue = "\(host) \(stamp).png"
        format.target = FormatSwitch.shared
        format.action = #selector(FormatSwitch.changed(_:))
        FormatSwitch.shared.panel = panel

        panel.beginSheetModal(for: window) { [weak self, weak web] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self, let web else { return }
                let pdf = format.indexOfSelectedItem == 1
                self.showToast(String(localized: "Capturing page…"), duration: nil)
                if pdf { self.savePDF(of: web, to: url) } else { self.savePNG(of: web, to: url) }
            }
        }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    private func savePDF(of web: WKWebView, to url: URL) {
        // nil rect = the whole page.
        web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let data): self?.write(data, to: url)
                case .failure(let error): self?.captureFailed(error)
                }
            }
        }
    }

    private func savePNG(of web: WKWebView, to url: URL) {
        let script = "[document.documentElement.scrollWidth, Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
        web.evaluateJavaScript(script) { [weak self, weak web] value, _ in
            MainActor.assumeIsolated {
                guard let self, let web else { return }
                let size = (value as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
                let width = max(web.bounds.width, size.first ?? 0) > 0 ? web.bounds.width : 1
                let height = min(max(web.bounds.height, size.count > 1 ? size[1] * web.pageZoom : 0), Self.maxShotHeight)
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: width, height: height)
                config.afterScreenUpdates = true
                web.takeSnapshot(with: config) { image, error in
                    MainActor.assumeIsolated {
                        guard let image, let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                            return self.captureFailed(error)
                        }
                        self.write(png, to: url)
                        if size.count > 1, size[1] * web.pageZoom > Self.maxShotHeight {
                            self.showToast(String(localized: "Page is very long: the PNG was cut. Use PDF for the whole page."), duration: 5)
                        }
                    }
                }
            }
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
        let pdf = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (pdf ? ".pdf" : ".png")
    }
}
