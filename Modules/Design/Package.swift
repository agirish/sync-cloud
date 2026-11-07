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
                .product(name: "EventsTestSupport", package: "Events")
            ])
    ]
)
