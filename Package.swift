// swift-tools-version:5.9
import PackageDescription
import Foundation

let cefRoot = "Vendor/cef"
let cefEnabled = ProcessInfo.processInfo.environment["ASKARA_ENABLE_CEF"] == "1"
    && FileManager.default.fileExists(atPath: cefRoot + "/.version")

var askaraDependencies: [Target.Dependency] = ["AskaraCore"]
var targets: [Target] = [
    // Pure logic (no AppKit) so it can be tested.
    .target(name: "AskaraCore"),
]

if cefEnabled {
    targets.append(.target(
        name: "CEFBridge",
        path: "Sources/CEFBridge",
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("../../Vendor/cef"),
            .define("ASKARA_CEF_ENABLED", to: "1"),
            .unsafeFlags(["-std=c++20"]),
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .unsafeFlags([
                "-L", cefRoot + "/build/libcef_dll_wrapper/Release",
                "-lcef_dll_wrapper",
                "-lc++",
            ]),
        ]
    ))
    askaraDependencies.append("CEFBridge")
}

targets.append(contentsOf: [
    // AppKit + browser runtime application.
    .executableTarget(
        name: "Askara",
        dependencies: askaraDependencies,
        swiftSettings: cefEnabled ? [.define("ASKARA_CEF")] : []
    ),
    .testTarget(name: "AskaraCoreTests", dependencies: ["AskaraCore"]),
    // AppKit component tests exercise UI behavior without launching against user data.
    .testTarget(name: "AskaraTests", dependencies: ["Askara"]),
])

let package = Package(
    name: "Askara",
    // 15.4: minimum for WKWebExtension (Safari extension support).
    platforms: [.macOS("15.4")],
    targets: targets
)
