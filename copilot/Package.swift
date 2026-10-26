// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "copilot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "copilot", path: "Sources/copilot", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
