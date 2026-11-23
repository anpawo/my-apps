// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "viewer",
    platforms: [.macOS(.v15)],
    targets: [
        // Speed steps, the list, GIF timing, file kinds: no AppKit, so `check` runs it headless.
        .target(name: "ViewerCore", path: "Sources/ViewerCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "viewer", dependencies: ["ViewerCore"], path: "Sources/Viewer",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` runs nothing without Xcode (no XCTest runner in the CLT): `swift run check`.
        .executableTarget(name: "check", dependencies: ["ViewerCore"], path: "Sources/check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
