// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileExplorer", targets: ["FileExplorer"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
        .package(path: "../Design"),
        // Test-only: visual snapshot regression net. The library product below does NOT
        // depend on it — only the test target links SnapshotTesting.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0")
    ],
    targets: [
        .target(
            name: "FileExplorer",
            dependencies: ["Sync", "Events", "Design"]),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: [
                "FileExplorer", "Sync", "Design",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/FileExplorer")
    ]
)
