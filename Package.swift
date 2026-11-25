// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShotDock",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ShotDock", targets: ["ShotDock"]),
        .library(name: "ShotDockCore", targets: ["ShotDockCore"]),
    ],
    targets: [
        .target(name: "ShotDockCore"),
        .executableTarget(
            name: "ShotDock",
            dependencies: ["ShotDockCore"]
        ),
        .testTarget(
            name: "ShotDockCoreTests",
            dependencies: ["ShotDockCore"]
        ),
    ]
)
