// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Design",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Design", targets: ["Design"]),
        // Test-only: every UI package's test target links it, the app never does. It quiets the
        // spell checker for the whole test process; see its header.
        .library(name: "TestProcessTextChecking", targets: ["TestProcessTextChecking"]),
        // Test-only, the same way: draws every hosting view's animations on the main thread for
        // the whole test process; see its header.
        .library(name: "TestProcessRendering", targets: ["TestProcessRendering"]),
        // Test-only, the same way: gives the whole test process a Find pasteboard of its own; see
        // its header.
        .library(name: "TestProcessFindPasteboard", targets: ["TestProcessFindPasteboard"]),
        // Test-only, the same way: `ProbeRig` and `Pixel`, the render-and-read harness every UI test
        // target shares.
        .library(name: "DesignTestSupport", targets: ["DesignTestSupport"]),
    ],
    dependencies: [
        // Test-only: `EventsTestSupport`, the helpers every test target shares.
        .package(path: "../Events"),
        // Test-only: the visual snapshot net. Only the test target links SnapshotTesting, never
        // the library product. All four are pinned `exact:`; the three transitives are named only
        // to pin them, since SnapshotTesting floats its own. Floating, the graph can pull two
        // packages that both vend `IssueReporting`, a duplicate PIF GUID that kills the build
        // before any test runs ("The build failed before any test ran" in docs/flaky-tests.md).
        // Bump the four together.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.4"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.6.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.11.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2")
    ],
    targets: [
        .target(name: "Design"),
        .target(name: "TestProcessTextChecking", linkerSettings: [.linkedFramework("AppKit")]),
        .target(name: "TestProcessRendering"),
        .target(name: "TestProcessFindPasteboard", linkerSettings: [.linkedFramework("AppKit")]),
        .target(name: "DesignTestSupport", dependencies: ["Design"]),
        .testTarget(
            name: "DesignTests",
            dependencies: [
                "Design", "TestProcessTextChecking", "DesignTestSupport",
                .product(name: "EventsTestSupport", package: "Events"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ])
    ]
)
