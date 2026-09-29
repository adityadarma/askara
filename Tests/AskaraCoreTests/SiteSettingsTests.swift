import Foundation
import JavaScriptCore
import Testing
@testable import AskaraCore

@Suite struct SiteSettingsTests {
    @Test func keyNormalizesHost() {
        #expect(SiteSettings.key(for: "WWW.Example.COM.") == "example.com")
        #expect(SiteSettings.key(for: "docs.example.com") == "docs.example.com")
    }

    @Test func blockCoversSubdomainsButNotSiblings() {
        var s = SiteSettings()
        s.setJavaScriptBlocked(true, host: "www.example.com")
        #expect(s.isJavaScriptBlocked(host: "example.com"))
        #expect(s.isJavaScriptBlocked(host: "docs.example.com"))
        #expect(!s.isJavaScriptBlocked(host: "example.org"))
        #expect(!s.isJavaScriptBlocked(host: "notexample.com"))
    }

    @Test func unblockClearsParentDomainBlock() {
        var s = SiteSettings()
        s.setJavaScriptBlocked(true, host: "example.com")
        s.setJavaScriptBlocked(false, host: "docs.example.com")
        #expect(!s.isJavaScriptBlocked(host: "docs.example.com"))
        #expect(s.javaScriptBlocked.isEmpty)
    }

    @Test func relatedHosts() {
        #expect(SiteSettings.isRelated("docs.example.com", "example.com"))
        // A setting saved from www.example.com is stored as example.com, which covers docs.
        #expect(SiteSettings.isRelated("www.example.com", "docs.example.com"))
        #expect(!SiteSettings.isRelated("docs.example.com", "api.example.com"))
        #expect(SiteSettings.isRelated("example.com", "www.example.com"))
        #expect(!SiteSettings.isRelated("example.com", "example.org"))
    }

    @Test func localhostWorks() {
        var s = SiteSettings()
        s.setJavaScriptBlocked(true, host: "localhost")
        #expect(s.isJavaScriptBlocked(host: "localhost"))
    }

    @Test func customizationsOrderedGeneralToSpecificAndFiltered() {
        var s = SiteSettings()
        s.setCustomization(SiteCustomization(css: "a{}"), host: "example.com")
        s.setCustomization(SiteCustomization(css: "b{}"), host: "docs.example.com")
        s.setCustomization(SiteCustomization(css: "c{}", isEnabled: false), host: "api.example.com")
        #expect(s.customizations(matching: "docs.example.com").map(\.css) == ["a{}", "b{}"])
        #expect(s.customizations(matching: "api.example.com").map(\.css) == ["a{}"])
    }

    @Test func emptyCustomizationIsRemoved() {
        var s = SiteSettings()
        s.setCustomization(SiteCustomization(css: "a{}"), host: "example.com")
        s.setCustomization(SiteCustomization(css: "  \n", javaScript: ""), host: "www.example.com")
        #expect(s.customizations.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        var s = SiteSettings()
        s.setJavaScriptBlocked(true, host: "example.com")
        s.setCustomization(SiteCustomization(css: "body{}", javaScript: "1"), host: "example.org")
        let decoded = try JSONDecoder().decode(SiteSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }
}

@Suite struct SiteCodeScriptTests {
    /// Minimal `document` so the generated scripts can run in JavaScriptCore.
    func context(readyState: String) -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var appended = [];
        var document = {
          readyState: '\(readyState)', adoptedStyleSheets: [], head: null,
          listeners: {},
          addEventListener(name, fn) { this.listeners[name] = fn; },
          getElementById() { return null; },
          createElement(tag) { return { tag }; },
          documentElement: { appendChild(el) { appended.push(el); } },
        };
        """)
        return context
    }

    @Test func blankCSSGivesNoScript() {
        #expect(SiteCodeScript.css(" \n ") == nil)
    }

    @Test func cssFallsBackToStyleElementAndKeepsTextExact() throws {
        let css = "body::after { content: \"</style>\\n'x'\"; }\n"
        let source = try #require(SiteCodeScript.css(css))
        let ctx = context(readyState: "complete") // no CSSStyleSheet here, so the fallback runs
        #expect(ctx.evaluateScript(source)?.toBool() == true)
        #expect(ctx.exception == nil)
        #expect(ctx.evaluateScript("appended[0].textContent")?.toString() == css)
    }

    @Test func javaScriptRunsWhenDocumentReady() {
        let ctx = context(readyState: "complete")
        #expect(ctx.evaluateScript(SiteCodeScript.javaScript("globalThis.ran = 42 // comment on last line"))?.toBool() == true)
        #expect(ctx.evaluateScript("ran")?.toInt32() == 42)
    }

    @Test func javaScriptWaitsForDOMContentLoaded() {
        let ctx = context(readyState: "loading")
        ctx.evaluateScript(SiteCodeScript.javaScript("globalThis.ran = true"))
        #expect(ctx.evaluateScript("typeof ran")?.toString() == "undefined")
        ctx.evaluateScript("document.listeners.DOMContentLoaded()")
        #expect(ctx.evaluateScript("ran")?.toBool() == true)
    }

    @Test func runtimeErrorIsCaughtSyntaxErrorIsReported() {
        let ctx = context(readyState: "complete")
        ctx.evaluateScript("var console = { error() { globalThis.logged = true; } };")
        ctx.evaluateScript(SiteCodeScript.javaScript("null.x"))
        #expect(ctx.exception == nil)
        #expect(ctx.evaluateScript("logged")?.toBool() == true)
        ctx.evaluateScript(SiteCodeScript.javaScript("function ("))
        #expect(ctx.exception != nil)
    }
}

@Suite struct DevicePresetTests {
    @Test func presetsAreMobileWithUniqueIDs() {
        #expect(Set(DevicePreset.all.map(\.id)).count == DevicePreset.all.count)
        for preset in DevicePreset.all {
            #expect(preset.userAgent.contains("Mobile"))
            #expect(preset.width < preset.height)
        }
    }

    @Test func landscapeSwapsSize() {
        let phone = DevicePreset.all[1]
        #expect(phone.size(landscape: false) == (393, 852))
        #expect(phone.size(landscape: true) == (852, 393))
    }
}
