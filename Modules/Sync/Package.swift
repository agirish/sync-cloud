// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        .package(path: "../Events")
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: ["Events"]
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: ["Sync"],
            path: "Tests/Sync"
        )
    ]
)
