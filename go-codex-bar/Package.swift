// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoCodexBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GoCodexBar", targets: ["GoCodexBar"]),
    ],
    targets: [
        .executableTarget(
            name: "GoCodexBar",
            path: "Sources/GoCodexBar"),
        .testTarget(
            name: "GoCodexBarTests",
            dependencies: ["GoCodexBar"]),
    ],
    swiftLanguageModes: [.v5])
