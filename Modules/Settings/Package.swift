// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Settings",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Settings", targets: ["Settings"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
        .package(path: "../Design")
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: ["Sync", "Events", "Design"]),
        .testTarget(
            name: "SettingsTests",
            dependencies: ["Design", "Sync"],
            path: "Tests/Settings")
    ]
)
