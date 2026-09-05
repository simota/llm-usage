// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LLMUsage", path: "Sources/LLMUsage"),
        .testTarget(name: "LLMUsageTests", dependencies: ["LLMUsage"])
    ]
)
