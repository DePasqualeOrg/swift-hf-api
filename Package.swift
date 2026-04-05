// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let benchmarksEnabled = Context.environment["HFAPI_ENABLE_BENCHMARKS"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto", "1.0.0" ..< "5.0.0"),
    .package(url: "https://github.com/DePasqualeOrg/swift-xet", from: "0.1.0"),
    .package(url: "https://github.com/DePasqualeOrg/swift-filelock", from: "0.1.1"),
    .package(url: "https://github.com/DePasqualeOrg/swift-sse", .upToNextMinor(from: "0.1.0")),
]

if benchmarksEnabled {
    packageDependencies.append(
        .package(
            // TODO: Switch to a major version pin once mlx-swift-lm publishes a new major release that includes these APIs.
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "8c9dd6391139242261bcf27d253c326f9cf2d567"
        )
    )
}

var packageTargets: [Target] = [
    .target(
        name: "HFAPI",
        dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Xet", package: "swift-xet"),
            .product(name: "FileLock", package: "swift-filelock"),
            .product(name: "SSE", package: "swift-sse"),
        ],
        path: "Sources/HFAPI"
    ),
    .testTarget(
        name: "HuggingFaceTests",
        dependencies: ["HFAPI"]
    ),
]

if benchmarksEnabled {
    packageTargets.append(
        .testTarget(
            name: "Benchmarks",
            dependencies: [
                "HFAPI",
                .product(
                    name: "BenchmarkHelpers",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        )
    )
}

let package = Package(
    name: "swift-hf-api",
    platforms: [
        .macOS(.v14),
        .macCatalyst(.v17),
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "HFAPI",
            targets: ["HFAPI"]
        )
    ],
    dependencies: packageDependencies,
    targets: packageTargets
)
