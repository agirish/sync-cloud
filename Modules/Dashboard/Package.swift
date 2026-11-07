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
    ],
    targets: [
        .target(
            name: "Dashboard",
            dependencies: ["Sync", "Events", "FileExplorer", "Settings", "Design"]),
        .testTarget(
            name: "DashboardTests",
            dependencies: [
                // FileExplorer for `EditHeaderMatchesPaneHeaderTests`, which lays Edit's document
                // header out beside the real `PaneHeader`.
                "Dashboard", "Sync", "Events", "Design", "FileExplorer", "Settings",
                .product(name: "FileExplorerTestSupport", package: "FileExplorer"),
                .product(name: "EventsTestSupport", package: "Events"),
                .product(name: "TestProcessTextChecking", package: "Design"),
                .product(name: "DesignTestSupport", package: "Design")
            ],
            path: "Tests/Dashboard")
    ]
)
