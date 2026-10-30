// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "firefax",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "firefax", path: "Sources/firefax", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
