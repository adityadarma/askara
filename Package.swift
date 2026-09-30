// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Askara",
    // 15.4: minimum for WKWebExtension (Safari extension support).
    platforms: [.macOS("15.4")],
    targets: [
        // Pure logic (no AppKit) so it can be tested.
        .target(name: "AskaraCore"),
        // AppKit + WKWebView browser app.
        .executableTarget(name: "Askara", dependencies: ["AskaraCore"]),
        .testTarget(name: "AskaraCoreTests", dependencies: ["AskaraCore"]),
    ]
)
