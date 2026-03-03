// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Sync",
            targets: ["Sync"]),
    ],
    dependencies: [
        .package(path: "../Events")
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: ["Events"]),
    ]
)
