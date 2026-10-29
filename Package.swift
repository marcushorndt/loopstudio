// swift-tools-version: 6.2
import PackageDescription

/// The code on the audio thread is optimized in debug builds too. Unoptimized Swift runs loops over ranges
/// and arrays through generic code that allocates on the heap; the soak test (`SoakTests.swift`) measures
/// about 30,000 allocations per block of 512 frames in a plain debug build, and none with -O.
let audioThreadSettings: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

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
        .target(name: "LoopStudioCore", swiftSettings: audioThreadSettings),
        // Package format, migrations, command journal.
        .target(name: "LoopStudioProject", dependencies: ["LoopStudioCore"]),
        // Ableton Link (GPL v2 or later, see Sources/LinkBridge/README.md): the C API over the header-only library.
        .target(
            name: "LinkBridge",
            path: "Sources/LinkBridge",
            sources: ["link/extensions/abl_link/src/abl_link.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("link/include"),
                .headerSearchPath("link/extensions/abl_link/include"),
                .headerSearchPath("link/modules/asio-standalone/include"),
                .define("LINK_PLATFORM_UNIX", to: "1"),
                .define("LINK_PLATFORM_MACOSX", to: "1"),
                .define("ASIO_STANDALONE", to: "1"),
                .define("ASIO_NO_TYPEID", to: "1"),
                .define("ASIO_VERSION_NAMESPACE", to: "link_asio_1_38_2"),
            ]),
        .target(name: "LoopStudioEngine", dependencies: ["LoopStudioCore", "LinkBridge"], swiftSettings: audioThreadSettings),
        // Tool registry and MCP server: the one way for scripts and agents to drive the app.
        .target(name: "LoopStudioControl", dependencies: ["LoopStudioCore", "LoopStudioProject", "LoopStudioEngine"]),
        .executableTarget(name: "loopstudio", dependencies: ["LoopStudioEngine", "LoopStudioProject", "LoopStudioCore", "LoopStudioControl"]),
        // The window app. Run it with scripts/run-app.sh.
        .executableTarget(name: "LoopStudioApp", dependencies: ["LoopStudioCore", "LoopStudioEngine", "LoopStudioProject"]),
        .testTarget(name: "LoopStudioCoreTests", dependencies: ["LoopStudioCore"]),
        .testTarget(name: "LoopStudioProjectTests", dependencies: ["LoopStudioProject", "LoopStudioCore"]),
        .testTarget(name: "LoopStudioEngineTests", dependencies: ["LoopStudioEngine", "LoopStudioCore"]),
        .testTarget(name: "LoopStudioControlTests", dependencies: ["LoopStudioControl", "LoopStudioCore", "LoopStudioProject"]),
    ],
    cxxLanguageStandard: .cxx17
)
