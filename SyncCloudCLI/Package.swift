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
        // Pinned `exact:` for the same reason as the four module manifests: nothing in the
        // dependency graph should float. ArgumentParser has no transitives of its own, and
        // this package is not in project.yml, so it has only the one resolution — but a
        // floating requirement is the hazard whether or not a second resolver exists.
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
        // The shell had no tests at all: argument parsing, the default subcommand, and the
        // ArgumentParser error translation were invisible to every suite. The target imports the
        // executable, which works because the entry point is `@main` (top-level code in a
        // main.swift would make the module unimportable).
        .testTarget(
            name: "SyncCloudCLITests",
            dependencies: ["SyncCloudCLI"]
        )
    ]
)
