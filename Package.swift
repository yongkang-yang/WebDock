// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebDock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "WebDock", path: "Sources/WebDock")
    ],
    swiftLanguageModes: [.v5]
)
