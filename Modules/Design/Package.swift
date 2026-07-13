// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Design",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Design", targets: ["Design"]),
    ],
    targets: [
        .target(name: "Design"),
        .testTarget(
            name: "DesignTests",
            dependencies: ["Design"])
    ]
)
