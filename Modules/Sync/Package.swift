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
            path: "Tests/Sync",
            resources: [
                // Folder names and counts lifted from the live profile and the 6 Aug reorg log —
                // no file names, no content (ROADMAP_V5 §5.8). In-repo so CI pins the detector
                // counts; the machine-pinned ground-truth suite is the wrong place for a release
                // gate.
                .copy("Fixtures")
            ]
        )
    ]
)
