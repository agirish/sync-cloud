// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dashboard",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Dashboard", targets: ["Dashboard"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
        .package(path: "../FileExplorer"),
        .package(path: "../Settings"),
        .package(path: "../Design"),
        // Test-only: visual snapshot regression net. The library product below does NOT
        // depend on it — only the test target links SnapshotTesting.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0")
    ],
    targets: [
        .target(
            name: "Dashboard",
            dependencies: ["Sync", "Events", "FileExplorer", "Settings", "Design"]),
        .testTarget(
            name: "DashboardTests",
            dependencies: [
                "Dashboard", "Sync", "Events", "Design",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/Dashboard")
    ]
)
