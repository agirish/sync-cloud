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
        // Test-only: the snapshot regression net. Only the test target links SnapshotTesting.
        // All four are pinned `exact:`; the three transitives are named only so they are pinned
        // too, since SnapshotTesting floats its own. Left floating, the graph can take two
        // packages that both vend `IssueReporting`, and the build dies before any test runs
        // (see "The build failed before any test ran" in docs/flaky-tests.md). Bump the four
        // together.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.4"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.6.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.11.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2")
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
                .product(name: "DesignTestSupport", package: "Design"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/Dashboard")
    ]
)
