// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FileExplorer", targets: ["FileExplorer"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events"),
        .package(path: "../Design")
    ],
    targets: [
        .target(
            name: "FileExplorer",
            dependencies: ["Sync", "Events", "Design"]),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: ["FileExplorer", "Sync", "Design"],
            path: "Tests/FileExplorer")
    ]
)
