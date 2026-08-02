// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Settings",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Settings", targets: ["Settings"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
        .package(path: "../Design"),
        // Test-only: visual snapshot regression net, same as Design/FileExplorer/Dashboard.
        // The library product below does NOT depend on it.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0")
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: ["Sync", "Events", "Design"]),
        .testTarget(
            name: "SettingsTests",
            dependencies: [
                "Settings", "Design", "Sync",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/Settings")
    ]
)
