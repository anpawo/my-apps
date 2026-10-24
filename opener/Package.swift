// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "opener",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "opener", path: "Sources/opener", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
