// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Events",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Events", targets: ["Events"]),
    ],
    dependencies: [
        .package(path: "../Design")
    ],
    targets: [
        .target(
            name: "Events",
            dependencies: [
                .product(name: "Design", package: "Design")
            ]
        ),
        .testTarget(
            name: "EventsTests",
            dependencies: ["Events"],
            path: "Tests/Events")
    ]
)
