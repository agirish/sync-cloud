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
            dependencies: ["Sync", .product(name: "EventsTestSupport", package: "Events")],
            path: "Tests/Sync",
            resources: [
                // Folder names and counts from the live profile and a reorg log, with no file names
                // or content. In-repo so CI pins the detector counts; the machine-pinned
                // ground-truth suite is the wrong place for a release gate.
                .copy("Fixtures")
            ]
        )
    ]
)
