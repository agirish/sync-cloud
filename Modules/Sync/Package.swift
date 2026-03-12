// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        .package(path: "../Events"),
        .package(path: "../Design")
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: ["Events", "Design"]
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: ["Sync"],
            path: "Tests/Sync"
        )
    ]
)
