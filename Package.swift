// swift-tools-version: 6.0
// SwiftPM manifest used to build and test with the Command Line Tools alone.
// project.yml (XcodeGen) describes the same targets for Xcode.
import PackageDescription

let package = Package(
    name: "ClaudePool",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PoolShared",
            path: "Shared"
        ),
        .executableTarget(
            name: "claude-pool-collector",
            dependencies: ["PoolShared"],
            path: "Collector"
        ),
        .executableTarget(
            name: "ClaudePool",
            dependencies: ["PoolShared"],
            path: "Sources"
        ),
        .testTarget(
            name: "ClaudePoolTests",
            dependencies: ["ClaudePool", "PoolShared", "claude-pool-collector"],
            path: "Tests/ClaudePoolTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
