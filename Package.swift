// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "loopstudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LoopStudioEngine", targets: ["LoopStudioEngine"]),
        .executable(name: "loopstudio", targets: ["loopstudio"]),
    ],
    targets: [
        .target(name: "LoopStudioEngine"),
        .executableTarget(name: "loopstudio", dependencies: ["LoopStudioEngine"]),
        .testTarget(name: "LoopStudioEngineTests", dependencies: ["LoopStudioEngine"]),
    ]
)
