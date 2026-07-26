// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Publisher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Publisher",
            path: "Sources/Publisher"
        ),
        .testTarget(
            name: "PublisherTests",
            dependencies: ["Publisher"],
            path: "Tests/PublisherTests"
        )
    ]
)
