// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ADBLXShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "ADBLXShared",
            targets: ["ADBLXShared"]
        ),
    ],
    targets: [
        .target(
            name: "ADBLXShared",
            dependencies: [],
            path: "Sources/ADBLXShared"
        ),
        .testTarget(
            name: "ADBLXSharedTests",
            dependencies: ["ADBLXShared"],
            path: "Tests/ADBLXSharedTests"
        ),
    ]
)
