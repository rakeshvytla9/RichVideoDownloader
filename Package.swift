// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RichVideoDownloader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "RichVideoDownloader",
            targets: ["RichVideoDownloader"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "RichVideoDownloader"
        ),
        .testTarget(
            name: "RichVideoDownloaderTests",
            dependencies: [
                "RichVideoDownloader",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
