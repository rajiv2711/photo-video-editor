// swift-tools-version:5.9
// EditorCore: the platform-independent brain of the editor (control list, command parsing,
// name matching, slider state). It has no Apple-only imports, so it builds and tests on Linux.
import PackageDescription

let package = Package(
    name: "EditorCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "EditorCore", targets: ["EditorCore"]),
    ],
    targets: [
        .target(
            name: "EditorCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"]
        ),
    ]
)
