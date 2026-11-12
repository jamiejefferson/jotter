// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jotter",
    // Core Audio process taps (call audio without a meeting bot) need macOS 14.2.
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Jotter",
            path: "Sources/Jotter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
