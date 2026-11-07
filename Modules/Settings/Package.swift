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
        // Test-only snapshot testing, as in Design, FileExplorer and Dashboard; the library
        // product does not depend on it. All four are pinned `exact:`: the three transitives are
        // named only so they are pinned too, because SnapshotTesting floats its own. Floating,
        // the graph can resolve two packages that both vend `IssueReporting`, and the build fails
        // before any test runs ("The build failed before any test ran" in docs/flaky-tests.md).
        // Bump the four together.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.4"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.6.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.11.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2")
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: ["Sync", "Events", "Design"]),
        .testTarget(
            name: "SettingsTests",
            dependencies: [
                "Settings", "Design", "Sync",
                .product(name: "TestProcessTextChecking", package: "Design"),
                .product(name: "DesignTestSupport", package: "Design"),
                .product(name: "EventsTestSupport", package: "Events"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/Settings")
    ]
)
