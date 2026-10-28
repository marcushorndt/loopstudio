// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "loopstudio",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LoopStudioCore", targets: ["LoopStudioCore"]),
        .library(name: "LoopStudioProject", targets: ["LoopStudioProject"]),
        .library(name: "LoopStudioEngine", targets: ["LoopStudioEngine"]),
        .library(name: "LoopStudioControl", targets: ["LoopStudioControl"]),
        .executable(name: "loopstudio", targets: ["loopstudio"]),
        .executable(name: "LoopStudioApp", targets: ["LoopStudioApp"]),
    ],
    targets: [
        // Time, project model, commands, undo. No audio frameworks.
        .target(name: "LoopStudioCore"),
        // Package format, migrations, command journal.
        .target(name: "LoopStudioProject", dependencies: ["LoopStudioCore"]),
        .target(name: "LoopStudioEngine", dependencies: ["LoopStudioCore"]),
        // Tool registry and MCP server: the one way for scripts and agents to drive the app.
        .target(name: "LoopStudioControl", dependencies: ["LoopStudioCore", "LoopStudioProject", "LoopStudioEngine"]),
        .executableTarget(name: "loopstudio", dependencies: ["LoopStudioEngine", "LoopStudioProject", "LoopStudioCore", "LoopStudioControl"]),
        // The window app. Run it with scripts/run-app.sh.
        .executableTarget(name: "LoopStudioApp", dependencies: ["LoopStudioCore", "LoopStudioEngine", "LoopStudioProject"]),
        .testTarget(name: "LoopStudioCoreTests", dependencies: ["LoopStudioCore"]),
        .testTarget(name: "LoopStudioProjectTests", dependencies: ["LoopStudioProject", "LoopStudioCore"]),
        .testTarget(name: "LoopStudioEngineTests", dependencies: ["LoopStudioEngine", "LoopStudioCore"]),
        .testTarget(name: "LoopStudioControlTests", dependencies: ["LoopStudioControl", "LoopStudioCore", "LoopStudioProject"]),
    ]
)
