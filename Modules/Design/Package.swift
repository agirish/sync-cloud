// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Design",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Design", targets: ["Design"]),
    ],
    dependencies: [
        // Test-only: visual snapshot regression net. The library product below does NOT
        // depend on it — only the test target links SnapshotTesting.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.0")
    ],
    targets: [
        .target(name: "Design"),
        .testTarget(
            name: "DesignTests",
            dependencies: [
                "Design",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ])
    ]
)
