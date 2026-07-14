// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "andross",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AndrossCore", targets: ["AndrossCore"]),
        .executable(name: "AndrossApp", targets: ["AndrossApp"]),
    ],
    dependencies: [
        // Signet — CVER's shared design system. andross supplies AndrossTheme;
        // the palette/Color(hex:) now single-source from here. Pinned to main.
        .package(url: "https://github.com/CVERInc/signet", branch: "main"),
    ],
    targets: [
        // Core business logic: handles Android SDK, AVD lifecycle, and ADB communication.
        .target(name: "AndrossCore", resources: [
            // Vendored scrcpy-server (Apache-2.0) — pushed to the emulated
            // device and run there via app_process; see Third-Party/scrcpy.
            .copy("Resources/scrcpy-server"),
        ]),
        // Native macOS SwiftUI app interface.
        .executableTarget(name: "AndrossApp", dependencies: [
            "AndrossCore",
            .product(name: "Signet", package: "signet"),
        ]),
        // Test harnesses (./scripts/test.sh) — not product CLIs. Plain
        // executables because Command Line Tools ship no XCTest/Testing.
        .executableTarget(name: "AndrossUnitTests", dependencies: ["AndrossCore"]),
        .executableTarget(name: "AndrossIntegration", dependencies: ["AndrossCore"]),
    ]
)
