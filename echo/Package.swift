// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "echo",
    // 15: `Color.mix`.
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "echo", path: "Sources/echo", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
