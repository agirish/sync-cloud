// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Events",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Events", targets: ["Events"]),
        // Test-only: `LogCapture`, for every test target that asserts on a log line. The app never
        // links it; the app target's tests compile the file in instead — see `project.yml`.
        .library(name: "EventsTestSupport", targets: ["EventsTestSupport"]),
    ],
    targets: [
        .target(
            name: "Events"
        ),
        .target(
            name: "EventsTestSupport",
            dependencies: ["Events"]),
        .testTarget(
            name: "EventsTests",
            dependencies: ["Events", "EventsTestSupport"],
            path: "Tests/Events")
    ]
)
