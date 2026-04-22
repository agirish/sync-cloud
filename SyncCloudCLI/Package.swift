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
        .executableTarget(
            name: "SyncCloudCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sync", package: "Sync"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "Events", package: "Events")
            ],
            path: "Sources"
        )
    ]
)

