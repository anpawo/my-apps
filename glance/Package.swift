// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "glance",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "glance", path: "Sources/glance", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
