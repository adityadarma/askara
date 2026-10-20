// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Askara",
    // macOS 14 is the minimum. WKWebExtension (Safari extension support) needs 15.4, so extension
    // features are availability-guarded and hidden on older systems.
    platforms: [.macOS("14.0")],
    dependencies: [
        // In-app updates (EdDSA-signed appcast served from GitHub Releases).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic (no AppKit) so it can be tested.
        .target(name: "AskaraCore"),
        // AppKit + WebKit browser application.
        .executableTarget(name: "Askara", dependencies: [
            "AskaraCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "AskaraCoreTests", dependencies: ["AskaraCore"]),
        // AppKit component tests exercise UI behavior without launching against user data.
        .testTarget(name: "AskaraTests", dependencies: ["Askara"]),
    ]
)
