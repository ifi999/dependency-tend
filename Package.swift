// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "dependency-tend",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Engine"),
        .target(name: "AppCore", dependencies: ["Engine"]),
        .executableTarget(name: "DependencyTend", dependencies: ["Engine", "AppCore"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore"]),
    ]
)
