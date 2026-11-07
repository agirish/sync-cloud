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
        // Test-only: the visual snapshot net, linked by the test target alone. All four pinned
        // `exact:`; the three transitives are named only so they are pinned too, since only a
        // root requirement constrains a transitive. Left floating, two of them can both vend an
        // `IssueReporting` product, a duplicate PIF GUID that kills the build before any test
        // runs (docs/flaky-tests.md, "The build failed before any test ran"). Bump the four
        // together.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.4"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.6.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.11.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", exact: "603.0.2"),

        // Shipped, unlike everything above: Edit's Markdown preview parses real GFM (tables and
        // task lists included), which a hand-rolled parser would keep getting wrong.
        //
        // Four pins for one dependency: `swift-markdown` names `swift-cmark` and
        // `swift-docc-plugin`, which names `swift-docc-symbolkit`, all as floating ranges. Pinned
        // at the root, they can't change under a build nobody touched. Bump all four together.
        // `Markdown` and `swift-cmark` link into the app; the other two are documentation
        // tooling, resolved but never linked.
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.8.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", exact: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-symbolkit", exact: "1.0.0"),

        // Shipped: the PDF tools' engine (Rotate, Delete, Reorder and Extract pages, Compress,
        // Clean Metadata, the password tools), shared with PDF Utils so both apps run the same
        // code. It owns no queue and works on the calling thread, so every call here can go
        // through `PDFKitSerialAccess` like any other parse.
        //
        // Pinned `exact`, and it has no dependencies of its own. This code rewrites people's
        // documents, and a new engine version changes what a tool writes (keeping or dropping
        // bookmarks, say), so it should arrive in a reviewed commit. pdf-utils pins the same tag.
        .package(url: "https://github.com/agirish/pdf-toolkit", exact: "0.6.1")
    ],
    targets: [
        .target(
            name: "FileExplorer",
            dependencies: [
                "Sync", "Events", "Design",
                .product(name: "Markdown", package: "swift-markdown"),
                // The same parser, named directly; `Markdown` already links both, so nothing new
                // ships. `MarkdownSourceContext` asks cmark itself where a line sits, on every
                // keystroke: swift-markdown's conversion to Swift values is most of its parse
                // (41ms against 3ms for a 100 KB note, debug build).
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
                .product(name: "DesignTestSupport", package: "Design"),
                .product(name: "TestProcessFindPasteboard", package: "Design"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "PDFToolkitCore", package: "pdf-toolkit")
            ],
            path: "Tests/FileExplorer",
            resources: [
                // pdf-toolkit's corpus form (as of 0.2.0): every field kind form filling handles,
                // with appearance streams. PDFKit can't write one, since its writer emits no
                // catalog /AcroForm. `EditorPDFFormFieldsTests` reads and fills it.
                .copy("Fixtures")
            ])
    ]
)
