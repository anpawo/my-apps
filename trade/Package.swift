// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "trade",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "trade", path: "Sources/trade", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
