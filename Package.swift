// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SchematicEditorMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SchematicCore", targets: ["SchematicCore"]),
        .executable(name: "SchematicApp", targets: ["SchematicApp"]),
    ],
    targets: [
        .target(name: "SchematicCore"),
        .executableTarget(name: "SchematicApp", dependencies: ["SchematicCore"]),
        .testTarget(name: "SchematicCoreTests", dependencies: ["SchematicCore"]),
    ]
)
