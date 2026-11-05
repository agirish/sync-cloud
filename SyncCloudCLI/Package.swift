// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SyncCloudCLI",
    platforms: [
        .macOS("26.0")
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
        // Pinned `exact:`, like the module manifests, so nothing in the dependency graph floats.
        // This package is not in project.yml, so this is its only resolution.
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
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
        ),
        // Tests the shell: argument parsing, the default subcommand and ArgumentParser error
        // translation. It imports the executable, which works because the entry point is `@main`
        // (top-level code in a main.swift would make the module unimportable).
        .testTarget(
            name: "SyncCloudCLITests",
            dependencies: ["SyncCloudCLI"]
        )
    ]
)
