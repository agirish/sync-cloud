// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SyncCloudCLI",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "synccloud",
            targets: ["SyncCloudCLI"]
        )
    ],
    dependencies: [
        .package(path: "../Modules/Sync"),
        .package(path: "../Modules/Settings"),
        .package(path: "../Modules/Events"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // The command orchestration logic (filtering, verify partitioning, collision
        // resolution, tallying, provider resolution), kept free of ArgumentParser,
        // readLine and print so it is unit-testable.
        .target(
            name: "SyncCloudCLICore",
            dependencies: [
                .product(name: "Sync", package: "Sync")
            ]
        ),
        // Thin shell: argument parsing -> core calls -> printed output.
        .executableTarget(
            name: "SyncCloudCLI",
            dependencies: [
                "SyncCloudCLICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sync", package: "Sync"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "Events", package: "Events")
            ]
        ),
        .testTarget(
            name: "SyncCloudCLICoreTests",
            dependencies: ["SyncCloudCLICore"]
        )
    ]
)
