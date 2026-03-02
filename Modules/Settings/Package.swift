// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Settings",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Settings", targets: ["Settings"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events")
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: ["Sync", "Events"])
    ]
)
