// swift-tools-version:5.9
// CommandEngine: turns typed or spoken words into slider changes (control list, parser,
// name matcher, slider state). No Apple-only imports, so it builds and tests on Linux too.
import PackageDescription

let package = Package(
    name: "CommandEngine",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CommandEngine", targets: ["CommandEngine"]),
    ],
    targets: [
        .target(
            name: "CommandEngine",
            resources: [.process("Resources")]
        ),
        // Scores the parser against test-data/phrases/commands.jsonl. Laptop-only; not in the app.
        .executableTarget(
            name: "command-scorer",
            dependencies: ["CommandEngine"]
        ),
        .testTarget(
            name: "CommandEngineTests",
            dependencies: ["CommandEngine"]
        ),
    ]
)
