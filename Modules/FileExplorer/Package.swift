// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FileExplorer", targets: ["FileExplorer"]),
        // Test-only: fixtures shared by this package's tests and Dashboard's (which lays Edit's
        // header out beside the pane's). The app never links it.
        .library(name: "FileExplorerTestSupport", targets: ["FileExplorerTestSupport"]),
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
        // `Markdown` and its C parser `swift-cmark` link into the app — the parser also named
        // directly by the FileExplorer target below; the other two are documentation tooling,
        // resolved because they are declared and never linked.
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.8.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", exact: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-symbolkit", exact: "1.0.0"),

        // **The second SHIPPED dependency: the PDF tools' engine.** Edit's Rotate, Delete, Reorder
        // and Extract pages, Compress, Clean Metadata and the two password tools call
        // `PDFToolkitCore` — PDF Utils' engine, cut out as its own package so both apps run the
        // same code. It owns no queue and does its PDFKit work on the calling thread, which is what
        // lets every call here go through `PDFKitSerialAccess` like any other parse.
        //
        // **Pinned `exact`, and one pin is the whole graph** — it names no dependencies of its own.
        // Exact because this code rewrites people's documents: a new engine version changes what a
        // tool's copy contains (0.1.0 → 0.1.1 was the difference between keeping a file's
        // bookmarks on macOS 27 and dropping them), and that should arrive as a commit someone
        // reviewed, not as whatever a resolve happened to fetch. pdf-utils pins the same tag.
        .package(url: "https://github.com/agirish/pdf-toolkit", exact: "0.6.1")
    ],
    targets: [
        .target(
            name: "FileExplorer",
            dependencies: [
                "Sync", "Events", "Design",
                .product(name: "Markdown", package: "swift-markdown"),
                // **The same parser, named directly — no new code shipped.** `Markdown` already
                // links both; `MarkdownSourceContext` asks cmark itself where a line sits, because
                // that question is asked on a keystroke and swift-markdown's conversion of the whole
                // tree into Swift values is nine tenths of its parse (measured 2026-10-04: 41ms
                // against 3ms for a 100 KB note, debug build).
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "PDFToolkitCore", package: "pdf-toolkit")
            ]),
        .target(
            name: "FileExplorerTestSupport",
            dependencies: ["FileExplorer", "Sync"]),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: [
                "FileExplorer", "FileExplorerTestSupport", "Sync", "Design",
                .product(name: "EventsTestSupport", package: "Events"),
                .product(name: "TestProcessTextChecking", package: "Design"),
                .product(name: "TestProcessRendering", package: "Design"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "PDFToolkitCore", package: "pdf-toolkit")
            ],
            path: "Tests/FileExplorer",
            resources: [
                // pdf-toolkit's corpus form, copied as it is at 0.2.0: every field kind form filling
                // handles, with appearance streams — a form no fixture written by PDFKit can be,
                // since PDFKit's writer emits no catalog /AcroForm of its own. Fill & Sign's Form
                // Fields tests (`EditorPDFFormFieldsTests`) read and fill it.
                .copy("Fixtures")
            ])
    ]
)
