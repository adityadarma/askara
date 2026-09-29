import Foundation

/// Screen size and user agent for Device Mode (Develop menu), like Chrome's device toolbar.
public struct DevicePreset: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// CSS pixels, portrait.
    public let width: Int
    public let height: Int
    public let userAgent: String

    public init(id: String, name: String, width: Int, height: Int, userAgent: String) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.userAgent = userAgent
    }

    public func size(landscape: Bool) -> (width: Int, height: Int) {
        landscape ? (height, width) : (width, height)
    }

    // iOS 26 Safari keeps reporting "18_6" as the OS version; Chrome for Android uses the reduced
    // "Android 10; K" form. These are the strings real devices send.
    static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    static let iPadUA = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    static let androidUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

    public static let all: [DevicePreset] = [
        DevicePreset(id: "iphone-se", name: "iPhone SE", width: 375, height: 667, userAgent: iPhoneUA),
        DevicePreset(id: "iphone-15-pro", name: "iPhone 15 Pro", width: 393, height: 852, userAgent: iPhoneUA),
        DevicePreset(id: "iphone-15-pro-max", name: "iPhone 15 Pro Max", width: 430, height: 932, userAgent: iPhoneUA),
        DevicePreset(id: "pixel-8", name: "Pixel 8", width: 412, height: 915, userAgent: androidUA),
        DevicePreset(id: "galaxy-s24", name: "Galaxy S24", width: 360, height: 780, userAgent: androidUA),
        DevicePreset(id: "ipad-air", name: "iPad Air", width: 820, height: 1180, userAgent: iPadUA),
        DevicePreset(id: "ipad-pro-13", name: "iPad Pro 13\"", width: 1024, height: 1366, userAgent: iPadUA),
    ]
}
