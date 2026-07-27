// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Publisher",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Publisher",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/Publisher"
        ),
        .testTarget(
            name: "PublisherTests",
            dependencies: ["Publisher"],
            path: "Tests/PublisherTests"
        )
    ]
)
