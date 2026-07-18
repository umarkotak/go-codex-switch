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
    ],
    swiftLanguageModes: [.v5])
