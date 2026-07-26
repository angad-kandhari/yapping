// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yapping",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "yapping",
            path: "Sources/Yapping",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
