// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShotDock",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ShotDock", targets: ["ShotDock"]),
        // Installed as ShotDock.app/Contents/Helpers/shotdock ("shotdock" and
        // "ShotDock" clash on a case-insensitive disk).
        .executable(name: "shotdock-cli", targets: ["ShotDockCLI"]),
        .library(name: "ShotDockCore", targets: ["ShotDockCore"]),
    ],
    targets: [
        .target(name: "ShotDockCore"),
        .executableTarget(
            name: "ShotDock",
            dependencies: ["ShotDockCore"]
        ),
        .executableTarget(
            name: "ShotDockCLI",
            dependencies: ["ShotDockCore"]
        ),
        .testTarget(
            name: "ShotDockCoreTests",
            dependencies: ["ShotDockCore"]
        ),
    ]
)
