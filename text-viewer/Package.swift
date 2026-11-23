// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "text",
    platforms: [.macOS(.v15)],
    targets: [
        // Highlighter, language detection and file encoding: no AppKit, so `check` runs it headless.
        .target(name: "TextCore", path: "Sources/TextCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "text", dependencies: ["TextCore"], path: "Sources/Text",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` runs nothing without Xcode (no XCTest runner in the CLT): `swift run check`.
        .executableTarget(name: "check", dependencies: ["TextCore"], path: "Sources/check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
