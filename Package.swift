// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-networking",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
        .tvOS(.v27),
        .watchOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "NetworkingTestSupport", targets: ["NetworkingTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "Networking",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ],
        ),
        .target(
            name: "NetworkingTestSupport",
            dependencies: [
                "Networking",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
        ),
        .testTarget(
            name: "NetworkingTests",
            dependencies: [
                "Networking",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"],
        ),
        .testTarget(
            name: "NetworkingTestSupportTests",
            dependencies: [
                "NetworkingTestSupport",
                "Networking",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
        ),
    ],
    swiftLanguageModes: [.v6],
)
