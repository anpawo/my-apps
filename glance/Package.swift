// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "glance",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "glance", path: "Sources/glance", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
