import AppKit
import AskaraCore
import UniformTypeIdentifiers
import WebKit

/// File > Save Page as PDF…: the whole page as one PDF. Use Print… for a paginated PDF.
extension BrowserWindowController {
    @objc func savePageAsPDFAction(_ sender: Any?) {
        guard let web = currentTab?.webView, let window, web.url != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PageFileName.suggested(title: currentTab?.title ?? "", host: web.url?.host,
                                                            pathExtension: "pdf")
        panel.beginSheetModal(for: window) { [weak self, weak web] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self, let web else { return }
                self.showToast(String(localized: "Saving PDF…"), duration: nil)
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web else { return }
                    if await self.isPDFPage(web) {
                        // A PDF tab: save the original document, not a re-render of the viewer.
                        guard let data = await self.fetchPDFData(from: web) else {
                            return self.pdfFailed(URLError(.cannotLoadFromNetwork))
                        }
                        return self.writePDF(data, to: url)
                    }
                    web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
                        MainActor.assumeIsolated {
                            switch result {
                            case .success(let data): self?.writePDF(data, to: url)
                            case .failure(let error): self?.pdfFailed(error)
                            }
                        }
                    }
                }
            }
        }
    }

    private func writePDF(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            showToast(String(localized: "PDF saved: \(url.lastPathComponent)"), duration: 3)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            pdfFailed(error)
        }
    }

    func pdfFailed(_ error: Error) {
        Log.error("Askara: PDF export failed: \(error)")
        showToast(String(localized: "Couldn't save the PDF."), duration: 3)
    }
}
