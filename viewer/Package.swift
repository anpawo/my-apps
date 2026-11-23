// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "viewer",
    platforms: [.macOS(.v15)],
    targets: [
        // Speed steps, the list, GIF timing, file kinds: no AppKit, so `check` runs it headless.
        .target(name: "ViewerCore", path: "Sources/ViewerCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Highlighter, language detection and file encoding, headless too.
        .target(name: "TextCore", path: "Sources/TextCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "viewer", dependencies: ["ViewerCore", "TextCore"], path: "Sources/Viewer",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` runs nothing without Xcode (no XCTest runner in the CLT): `swift run check`.
        .executableTarget(name: "check", dependencies: ["ViewerCore", "TextCore"], path: "Sources/check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
