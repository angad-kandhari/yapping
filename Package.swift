// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yap",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "yap",
            path: "Sources/Yap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
