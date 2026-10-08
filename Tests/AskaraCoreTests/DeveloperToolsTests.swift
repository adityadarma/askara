import Foundation
import Testing
@testable import AskaraCore

@Suite struct UserAgentPresetTests {
    @Test func presetsHaveUniqueIDsAndSingleLineAgents() {
        #expect(Set(UserAgentPreset.all.map(\.id)).count == UserAgentPreset.all.count)
        for preset in UserAgentPreset.all {
            #expect(!preset.userAgent.isEmpty)
            #expect(!preset.userAgent.contains("\n"))
        }
    }

    @Test func sanitizedTrimsAndRemovesLineBreaks() {
        #expect(UserAgentPreset.sanitized("  Foo/1.0  ") == "Foo/1.0")
        #expect(UserAgentPreset.sanitized("Foo\r\nX-Injected: 1") == "Foo  X-Injected: 1")
        #expect(UserAgentPreset.sanitized("   \n ") == nil)
    }
}

@Suite struct CustomDeviceTests {
    @Test func customSizeIsValidatedAndKeepsUserAgent() throws {
        let device = try #require(DevicePreset.custom(width: 800, height: 600))
        #expect(device.isCustom)
        #expect(device.userAgent == "")
        #expect(device.size(landscape: false) == (800, 600))
        #expect(DevicePreset.custom(width: 100, height: 600) == nil)
        #expect(DevicePreset.custom(width: 800, height: 5000) == nil)
        #expect(!DevicePreset.all.contains { $0.isCustom })
    }
}

@Suite struct CurlCommandTests {
    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false) -> CurlCommand.Cookie {
        CurlCommand.Cookie(name: name, value: "v", domain: domain, path: path, isSecure: secure)
    }

    @Test func quotesForShell() {
        #expect(CurlCommand.quote("it's") == #"'it'\''s'"#)
        let command = CurlCommand.make(url: URL(string: "https://example.com/a?b=1&c=2")!, userAgent: "UA", cookies: [])
        #expect(command == "curl 'https://example.com/a?b=1&c=2' -H 'User-Agent: UA' --compressed")
    }

    @Test func sendsOnlyMatchingCookies() {
        let url = URL(string: "https://app.example.com/api/items")!
        let cookies = [
            cookie("host", domain: "app.example.com"),
            cookie("parent", domain: ".example.com"),
            cookie("hostOnlyParent", domain: "example.com"),
            cookie("other", domain: "notexample.com"),
            cookie("path", domain: "app.example.com", path: "/api"),
            cookie("wrongPath", domain: "app.example.com", path: "/apix"),
        ]
        let sent = cookies.filter { CurlCommand.matches($0, url: url) }.map(\.name)
        #expect(Set(sent) == ["host", "parent", "path"])
    }

    @Test func secureCookiesNeedHTTPS() {
        let secure = cookie("s", domain: "example.com", secure: true)
        #expect(CurlCommand.matches(secure, url: URL(string: "https://example.com/")!))
        #expect(!CurlCommand.matches(secure, url: URL(string: "http://example.com/")!))
    }
}

@Suite struct LocalDevelopmentHostTests {
    @Test func localHosts() {
        for host in ["localhost", "LOCALHOST.", "app.localhost", "site.test", "printer.local", "api.internal",
                     "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.20", "::1", "[::1]"] {
            #expect(LocalDevelopmentHost.isLocal(host), "\(host)")
        }
    }

    @Test func publicHostsAreNeverLocal() {
        for host in ["example.com", "localhost.example.com", "test.com", "172.32.0.1", "8.8.8.8", "192.169.0.1",
                     "1.2.3", "300.1.1.1", ""] {
            #expect(!LocalDevelopmentHost.isLocal(host), "\(host)")
        }
    }

    @Test func reachableURLReplacesLoopbackOnly() {
        let local = URL(string: "http://localhost:3000/path?q=1")!
        #expect(LocalDevelopmentHost.reachableURL(local, lanAddress: "192.168.1.5").absoluteString
            == "http://192.168.1.5:3000/path?q=1")
        #expect(LocalDevelopmentHost.reachableURL(local, lanAddress: nil) == local)
        let site = URL(string: "https://site.test/")!
        #expect(LocalDevelopmentHost.reachableURL(site, lanAddress: "192.168.1.5") == site)
    }
}

@Suite struct ExternalBrowserTests {
    @Test func uniqueBundleIDs() {
        #expect(Set(ExternalBrowser.known.map(\.bundleID)).count == ExternalBrowser.known.count)
    }
}
