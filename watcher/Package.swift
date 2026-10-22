// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "watcher",
    // 15: `Color.mix`.
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "watcher", path: "Sources/watcher", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
