// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "andross",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AndrossCore", targets: ["AndrossCore"]),
        .executable(name: "AndrossApp", targets: ["AndrossApp"]),
    ],
    targets: [
        // Core business logic: handles Android SDK, AVD lifecycle, and ADB communication.
        .target(name: "AndrossCore"),
        // Native macOS SwiftUI app interface.
        .executableTarget(name: "AndrossApp", dependencies: ["AndrossCore"]),
    ]
)
