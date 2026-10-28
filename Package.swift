// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "loopstudio",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LoopStudioCore", targets: ["LoopStudioCore"]),
        .library(name: "LoopStudioProject", targets: ["LoopStudioProject"]),
        .library(name: "LoopStudioEngine", targets: ["LoopStudioEngine"]),
        .executable(name: "loopstudio", targets: ["loopstudio"]),
    ],
    targets: [
        // Time, project model, commands, undo. No audio frameworks.
        .target(name: "LoopStudioCore"),
        // Package format, migrations, command journal.
        .target(name: "LoopStudioProject", dependencies: ["LoopStudioCore"]),
        .target(name: "LoopStudioEngine"),
        .executableTarget(name: "loopstudio", dependencies: ["LoopStudioEngine", "LoopStudioProject", "LoopStudioCore"]),
        .testTarget(name: "LoopStudioCoreTests", dependencies: ["LoopStudioCore"]),
        .testTarget(name: "LoopStudioProjectTests", dependencies: ["LoopStudioProject", "LoopStudioCore"]),
        .testTarget(name: "LoopStudioEngineTests", dependencies: ["LoopStudioEngine"]),
    ]
)
