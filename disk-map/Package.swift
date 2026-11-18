// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "disk-map",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "disk-map", path: "Sources/disk-map", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
