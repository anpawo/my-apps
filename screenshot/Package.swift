// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screenshot",
    platforms: [.macOS(.v15)],
    targets: [
        // Geometry, naming and the bar's state machine: no AppKit, so `check` can run it headless.
        .target(name: "ScreenshotCore", path: "Sources/ScreenshotCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "screenshot", dependencies: ["ScreenshotCore"], path: "Sources/Screenshot",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` runs nothing without Xcode (no XCTest runner in the CLT): `swift run check`.
        .executableTarget(name: "check", dependencies: ["ScreenshotCore"], path: "Sources/check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
