import AppKit
import Testing
import WebKit
@testable import Askara

@MainActor
private func loadJSON(_ body: String, mimeType: String = "application/json") async throws -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.addUserScript(JSONViewer.userScript)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    web.load(Data(body.utf8), mimeType: mimeType, characterEncodingName: "utf-8",
             baseURL: URL(string: "https://example.com/api")!)
    for _ in 0..<100 where web.isLoading || web.url == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(100))
    return web
}

@Suite("Developer tools", .serialized)
@MainActor
struct DeveloperToolsUITests {
    @Test("JSON responses become a tree; values are text, never HTML")
    func jsonViewerRendersTree() async throws {
        let web = try await loadJSON(#"{"name":"<img src=x onerror=alert(1)>","items":[1,true,null]}"#)
        let active = try await web.evaluateJavaScript("document.documentElement.dataset.askaraJsonViewer || ''") as? String
        #expect(active == "1")
        let images = try await web.evaluateJavaScript("document.querySelectorAll('img').length") as? Int
        #expect(images == 0)
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
        #expect(text.contains("<img src=x onerror=alert(1)>"))
        #expect(text.contains("3 items"))
    }

    @Test("Invalid JSON and other types are left alone")
    func jsonViewerIgnoresOtherContent() async throws {
        let broken = try await loadJSON("{not json")
        #expect(try await broken.evaluateJavaScript("document.documentElement.dataset.askaraJsonViewer || ''") as? String == "")
        let plain = try await loadJSON(#"{"a":1}"#, mimeType: "text/plain")
        #expect(try await plain.evaluateJavaScript("document.documentElement.dataset.askaraJsonViewer || ''") as? String == "")
    }

    @Test("QR code is square and sharp")
    func qrCodeImage() throws {
        let image = try #require(QRCode.image(for: "http://192.168.1.5:3000/", side: 220))
        #expect(image.size.width == image.size.height)
        #expect(image.size.width <= 220 && image.size.width >= 100)
    }
}
