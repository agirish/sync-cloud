// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dashboard",
    platforms: [.macOS(.v15)],
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
            dependencies: ["Sync", "Events", "FileExplorer", "Settings"]),
        .testTarget(
            name: "DashboardTests",
            dependencies: ["Dashboard", "Sync"],
            path: "Tests/Dashboard")
    ]
)
