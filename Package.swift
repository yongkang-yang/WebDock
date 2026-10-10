// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebDock",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WebDockPolicies", path: "Sources/WebDockPolicies"),
        .executableTarget(name: "WebDock", dependencies: ["WebDockPolicies"], path: "Sources/WebDock",
                          linkerSettings: [.linkedLibrary("proc")]),
        .testTarget(name: "WebDockPoliciesTests", dependencies: ["WebDockPolicies"],
                    path: "Tests/WebDockPoliciesTests")
    ],
    swiftLanguageModes: [.v5]
)
