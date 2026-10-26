// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "autocorrect",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "autocorrect", path: "Sources/autocorrect", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
