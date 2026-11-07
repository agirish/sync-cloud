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
                .product(name: "EventsTestSupport", package: "Events")
            ],
            path: "Tests/Settings")
    ]
)
