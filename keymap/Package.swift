// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "keymap",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "keymap", path: "Sources/keymap", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
