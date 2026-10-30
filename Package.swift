// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentCenter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentCenter", path: "Sources/AgentCenter"),
        .testTarget(name: "AgentCenterTests", dependencies: ["AgentCenter"], path: "Tests"),
    ]
)
