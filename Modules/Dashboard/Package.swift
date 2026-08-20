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
        // All four pinned `exact:` — the three transitives are named only so that they are
        // pinned too, since a root requirement is the one thing that constrains a transitive
        // and SnapshotTesting floats every one of its own. Left floating, the graph took
        // xctest-dynamic-overlay 1.12.0 *and* swift-issue-reporting 2.1.0, which both vend
        // an `IssueReporting` product: duplicate PIF GUID, app target dead before a single
        // test ran. See "The build failed before any test ran" in docs/flaky-tests.md
        // (the mechanisms are numbered per line, so it is referenced by name). Bump the
        // four together.
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
                "Dashboard", "Sync", "Events", "Design",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/Dashboard")
    ]
)
