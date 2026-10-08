import Foundation

/// User agents for Develop > User Agent, like Safari's menu of the same name.
public struct UserAgentPreset: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let userAgent: String

    public init(id: String, name: String, userAgent: String) {
        self.id = id
        self.name = name
        self.userAgent = userAgent
    }

    // Chrome and Edge send the reduced form (major version, "0.0.0", fixed macOS 10_15_7);
    // Firefox freezes macOS at 10.15. These match what the real browsers send.
    public static let all: [UserAgentPreset] = [
        UserAgentPreset(id: "chrome-mac", name: "Google Chrome — macOS",
                        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                            + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"),
        UserAgentPreset(id: "edge-mac", name: "Microsoft Edge — macOS",
                        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                            + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0"),
        UserAgentPreset(id: "firefox-mac", name: "Firefox — macOS",
                        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:143.0) Gecko/20100101 Firefox/143.0"),
        UserAgentPreset(id: "chrome-windows", name: "Google Chrome — Windows",
                        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                            + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"),
        UserAgentPreset(id: "safari-iphone", name: "Safari — iPhone", userAgent: DevicePreset.iPhoneUA),
        UserAgentPreset(id: "safari-ipad", name: "Safari — iPad", userAgent: DevicePreset.iPadUA),
        UserAgentPreset(id: "chrome-android", name: "Google Chrome — Android", userAgent: DevicePreset.androidUA),
        UserAgentPreset(id: "googlebot", name: "Googlebot",
                        userAgent: "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"),
    ]

    /// A user-typed agent: trimmed, single line, nil when empty. Header values can't contain line breaks.
    public static func sanitized(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}
