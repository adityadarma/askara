// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hemat",
    // 15.4: minimum for WKWebExtension (Safari extension support such as Bitwarden).
    platforms: [.macOS("15.4")],
    targets: [
        // Pure logic (no AppKit) so it can be tested.
        .target(name: "HematCore"),
        // AppKit + WKWebView browser app.
        .executableTarget(name: "Hemat", dependencies: ["HematCore"]),
        .testTarget(name: "HematCoreTests", dependencies: ["HematCore"]),
    ]
)
