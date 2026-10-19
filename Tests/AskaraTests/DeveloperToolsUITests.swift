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

@Suite("Full-page capture", .serialized)
@MainActor
struct PageCaptureTests {
    /// Dashboard layout: sidebar and content each scroll on their own inside a 100vh shell.
    private static let html = """
    <html><body style="margin:0;height:100vh;overflow:hidden;display:flex">
    <div id="side" style="width:100px;height:100vh;overflow-y:auto;background:#123"><div style="height:1500px"></div></div>
    <div id="main" style="flex:1;height:100vh;overflow-y:auto"><div style="height:2400px;background:linear-gradient(red,blue)"></div></div>
    </body></html>
    """

    @Test("Two inner scrollers are both shown in full, in one image")
    func capturesInnerScrollers() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        web.loadHTMLString(Self.html, baseURL: nil)
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))

        let result = try #require(await PageCapture.fullPage(of: web))
        #expect(result.image.size.width == 400)
        #expect(result.image.size.height >= 2300)
        #expect(!result.truncated)
        // The view is restored afterwards.
        #expect(web.frame.height == 300)
    }
}
