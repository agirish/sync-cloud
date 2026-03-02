// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Events",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Events", targets: ["Events"]),
    ],
    targets: [
        .target(name: "Events")
    ]
)
