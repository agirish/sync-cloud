// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Events",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Events", targets: ["Events"]),
    ],
    targets: [
        .target(
            name: "Events"
        ),
        .testTarget(
            name: "EventsTests",
            dependencies: ["Events"],
            path: "Tests/Events")
    ]
)
