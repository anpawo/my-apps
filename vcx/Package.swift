// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VCX",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "VCX", path: "Sources/CX", swiftSettings: [.swiftLanguageMode(.v5)])]
)
