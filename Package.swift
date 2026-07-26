// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dictate",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "dictate",
            path: "Sources/Dictate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
