// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Dashboard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Dashboard", targets: ["Dashboard"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
        .package(path: "../FileExplorer"),
        .package(path: "../Settings")
    ],
    targets: [
        .target(
            name: "Dashboard",
            dependencies: ["Sync", "Events", "FileExplorer", "Settings"])
    ]
)
