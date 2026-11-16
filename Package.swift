// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAttentionRouter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "aar", targets: ["AttentionCLI"]),
        .executable(name: "AgentAttentionRouter", targets: ["AttentionApp"])
    ],
    targets: [
        .target(name: "AttentionCore"),
        .executableTarget(name: "AttentionCLI", dependencies: ["AttentionCore"]),
        .executableTarget(name: "AttentionApp", dependencies: ["AttentionCore"]),
        .testTarget(name: "AttentionCoreTests", dependencies: ["AttentionCore"])
    ]
)
