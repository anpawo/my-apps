// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-guard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "mac-guard", path: "Sources/mac-guard", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
