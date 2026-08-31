// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FileExplorer", targets: ["FileExplorer"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
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
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2"),

        // **The first external dependency this app SHIPS.** Every one above it is test-only — the
        // library product does not link them — and this one is linked into `FileExplorer` itself,
        // deliberately: the Editor's Markdown preview parses real GFM (tables and task lists
        // included), and a hand-rolled parser is a thing to be wrong about forever rather than a
        // thing to depend on.
        //
        // **Four pins for one dependency, and the count is the finding.** Adding
        // `swift-markdown` was described as itself plus a `swift-cmark` transitive; resolving it
        // actually fetched FOUR checkouts, because `swift-markdown` names `swift-cmark`
        // (`from: "0.8.0"`) and `swift-docc-plugin` (`from: "1.1.0"`), and that plugin in turn
        // names `swift-docc-symbolkit`. Every one of those is a floating range, and a root
        // requirement is the only thing that constrains a transitive — left alone they are three
        // packages that can change under a build nobody touched, which is exactly how the
        // duplicate-PIF-GUID incident above happened. Bump all four together.
        //
        // Only `Markdown` links into the app. `swift-cmark` is its C parser; the other two are
        // documentation tooling, resolved because they are declared and never linked.
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.8.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", exact: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-symbolkit", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "FileExplorer",
            dependencies: [
                "Sync", "Events", "Design",
                .product(name: "Markdown", package: "swift-markdown")
            ]),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: [
                "FileExplorer", "Sync", "Design",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/FileExplorer")
    ]
)
