// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileExplorer", targets: ["FileExplorer"]),
    ],
    dependencies: [
        .package(path: "../Sync"),
        .package(path: "../Events")
    ],
    targets: [
        .target(
            name: "FileExplorer",
            dependencies: ["Sync", "Events"])
    ]
)
