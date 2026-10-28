// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Design",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Design", targets: ["Design"]),
        // Test-only: every UI package's test target links it, and the app never does. Linking it
        // quiets the spell checker for the whole test process — see its header.
        .library(name: "TestProcessTextChecking", targets: ["TestProcessTextChecking"]),
        // Test-only, the same way: linking it draws every hosting view's animations on the main
        // thread for the whole test process — see its header.
        .library(name: "TestProcessRendering", targets: ["TestProcessRendering"]),
        // Test-only, the same way: linking it gives the whole test process a Find pasteboard of its
        // own — see its header.
        .library(name: "TestProcessFindPasteboard", targets: ["TestProcessFindPasteboard"]),
    ],
    dependencies: [
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
        .target(name: "Design"),
        .target(name: "TestProcessTextChecking", linkerSettings: [.linkedFramework("AppKit")]),
        .target(name: "TestProcessRendering"),
        .target(name: "TestProcessFindPasteboard", linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(
            name: "DesignTests",
            dependencies: [
                "Design", "TestProcessTextChecking",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ])
    ]
)
