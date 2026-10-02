import Foundation
import Testing
@testable import AskaraCore

@Suite struct PasswordCredentialTests {
    @Test func acceptsOnlyExactHTTPSOrigins() throws {
        let defaultPort = try #require(PasswordOrigin(url: URL(string: "https://Example.COM:443/login")!))
        let customPort = try #require(PasswordOrigin(url: URL(string: "https://example.com:8443/login")!))

        #expect(defaultPort.host == "example.com")
        #expect(defaultPort.port == nil)
        #expect(defaultPort.displayName == "https://example.com")
        #expect(customPort.port == 8443)
        #expect(customPort != defaultPort)
        #expect(PasswordOrigin(url: URL(string: "http://example.com")!) == nil)
        #expect(PasswordOrigin(url: URL(string: "https://accounts.example.com")!) != defaultPort)
    }

    @Test func metadataContainsNoPassword() throws {
        let origin = try #require(PasswordOrigin(url: URL(string: "https://example.com")!))
        let credential = PasswordCredential(origin: origin, username: "alice@example.com")
        let json = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)

        #expect(json.contains("alice@example.com"))
        #expect(!json.localizedCaseInsensitiveContains("password"))
    }
}
