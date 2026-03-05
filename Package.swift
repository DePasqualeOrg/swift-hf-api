// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-hf-api",
    platforms: [
        .macOS(.v13),
        .macCatalyst(.v16),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "HFAPI",
            targets: ["HFAPI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/EventSource", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", "1.0.0" ..< "5.0.0"),
        .package(url: "https://github.com/mattt/swift-xet.git", from: "0.2.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-filelock", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "HFAPI",
            dependencies: [
                .product(name: "EventSource", package: "EventSource"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Xet", package: "swift-xet"),
                .product(name: "FileLock", package: "swift-filelock"),
            ],
            path: "Sources/HFAPI"
        ),
        .testTarget(
            name: "HuggingFaceTests",
            dependencies: ["HFAPI"]
        ),
        .testTarget(
            name: "Benchmarks",
            dependencies: ["HFAPI"]
        ),
    ]
)
