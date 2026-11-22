// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "desks",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DesksCore", path: "Sources/DesksCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "desks", dependencies: ["DesksCore"], path: "Sources/Desks",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` runs nothing without Xcode: the checks are a plain executable.
        .executableTarget(name: "check", dependencies: ["DesksCore"], path: "Sources/check",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
