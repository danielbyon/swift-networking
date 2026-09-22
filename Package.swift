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
    ],
    targets: [
        .target(
            name: "Networking",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
        ),
        .target(
            name: "NetworkingTestSupport",
            dependencies: [
                "Networking",
            ],
        ),
        .testTarget(
            name: "NetworkingTests",
            dependencies: [
                "Networking",
            ],
        ),
        .testTarget(
            name: "NetworkingTestSupportTests",
            dependencies: [
                "NetworkingTestSupport",
            ],
        ),
    ],
    swiftLanguageModes: [.v6],
)
