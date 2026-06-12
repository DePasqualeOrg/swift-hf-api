// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Swift 6.2 / Xcode 26 floor: SE-0482's `staticLibrary` artifact type – the
// shape the `HFAPIRust` artifactbundle uses to ship Apple + Linux slices in
// one zip – landed in Swift 6.2. Older Xcode versions cannot resolve the
// package once the Rust backend is wired in.

import PackageDescription

// Pinned artifactbundle for the Rust backend. These mirror `rust/Pin.json` and are
// kept in sync by scripts/rust/release/cut-release.sh. Inlined here rather than
// read from Pin.json because manifest-eval file I/O is unreliable for URL-based
// dependency consumers (both `Context.packageDirectory` and `#filePath` return
// synthetic paths during dep evaluation).
//
// The marker comments below delimit the rewriteable region for cut-release.sh
// and check-package-swift-pin.sh – do not move or reformat the two `let`
// declarations without updating both scripts.
// pin:start
let hfapiRustArtifactBundleURL =
    "https://github.com/DePasqualeOrg/swift-hf-api/releases/download/hfapi-rust-0.4.2/HFAPIRust-0.4.2.artifactbundle.zip"
let hfapiRustArtifactBundleChecksum = "d1975558aee9fb32cb7242cb2f573427b0081aa3ee5374b0976a91b60a428e04"
// pin:end

// When set, build against a local artifactbundle directory instead of the
// pinned URL — used by the release workflow's smoke test and for local
// development before a release is pinned. See docs/release-process.md.
let localRustArtifactPath: String? =
    Context.environment["HFAPI_RUST_LOCAL_ARTIFACTBUNDLE_PATH"]

// `HFAPI_ENABLE_DOCS=1` activates the swift-docc-plugin dependency so
// `swift package generate-documentation` is available. Gated so end users
// resolving the package don't pull in the plugin unnecessarily.
let docsEnabled = Context.environment["HFAPI_ENABLE_DOCS"] == "1"

let hfapiRustTarget: Target =
    if let localRustArtifactPath {
        // Used by the Rust release workflow to validate a freshly built artifactbundle before publishing.
        // The override must point at an unzipped directory whose name ends in `.artifactbundle`; SwiftPM
        // uses the suffix to discriminate, so a `.zip` path will not work.
        .binaryTarget(name: "HFAPIRust", path: localRustArtifactPath)
    } else {
        .binaryTarget(
            name: "HFAPIRust",
            url: hfapiRustArtifactBundleURL,
            checksum: hfapiRustArtifactBundleChecksum
        )
    }

// `HFAPIFFI` linker settings: the Rust staticlib pulls in symbols from libc
// satellites that SE-0482 artifactbundles do not propagate as transitive link
// dependencies. On Apple, most of these resolve through libSystem without
// explicit settings; on Linux, every libc satellite needs a declaration.
// `gcc_s` is normally auto-linked by gcc but appears in
// `cargo rustc -- --print=native-static-libs` output, so we declare it too.
//
// Apple frameworks needed by hf-hub's `reqwest` + `hyper-util` transitive
// dependencies. `SystemConfiguration` and `CoreFoundation` are the proxy
// and DNS resolvers; `Security` and `IOKit` come in via `ring` and the
// rustls fallback paths. `--print=native-static-libs` on
// `aarch64-apple-darwin` produces this list verbatim.
let appleFrameworks: [String] = ["SystemConfiguration", "CoreFoundation", "Security", "IOKit"]
let appleLibraries: [String] = ["objc", "iconv"]
let linuxLibraries: [String] = ["dl", "pthread", "m", "rt", "util", "gcc_s"]

var hfapiFFILinkerSettings: [LinkerSetting] = []
hfapiFFILinkerSettings.append(
    contentsOf: appleFrameworks.map {
        .linkedFramework($0, .when(platforms: [.macOS, .iOS]))
    }
)
hfapiFFILinkerSettings.append(
    contentsOf: appleLibraries.map {
        .linkedLibrary($0, .when(platforms: [.macOS, .iOS]))
    }
)
hfapiFFILinkerSettings.append(
    contentsOf: linuxLibraries.map {
        .linkedLibrary($0, .when(platforms: [.linux]))
    }
)

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto", "1.0.0" ..< "5.0.0")
]

if docsEnabled {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
    )
}

let package = Package(
    name: "swift-hf-api",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "HFAPI", targets: ["HFAPI"]),
        .library(name: "HFAPIOAuth", targets: ["HFAPIOAuth"]),
        .library(name: "HFAPIHubAuth", targets: ["HFAPIHubAuth"]),
        .library(name: "HFAPIShared", targets: ["HFAPIShared"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "HFAPIShared",
            path: "Sources/HFAPIShared"
        ),
        .target(
            name: "HFAPI",
            dependencies: [
                "HFAPIFFI",
                "HFAPIShared",
            ],
            path: "Sources/HFAPI"
        ),
        .target(
            name: "HFAPIOAuth",
            dependencies: [
                "HFAPIShared",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/HFAPIOAuth"
        ),
        .target(
            name: "HFAPIHubAuth",
            dependencies: [
                "HFAPI",
                "HFAPIOAuth",
            ],
            path: "Sources/HFAPIHubAuth"
        ),
        hfapiRustTarget,
        .target(
            name: "HFAPIFFI",
            dependencies: [
                .target(name: "HFAPIRust")
            ],
            path: "Sources/HFAPIFFI",
            resources: [.process("Resources")],
            // The generated wrapper holds a `static let vtablePtr:
            // UnsafePointer<...>` for each `with_foreign` callback trait —
            // Swift 6's strict-concurrency mode flags `UnsafePointer` as
            // non-`Sendable` global state. The pointer is allocated once
            // and Rust owns its lifetime, so the memory model is sound;
            // UniFFI 0.31's `uniffi.toml` exposes no setting that toggles
            // the concurrency annotation, so we drop strict concurrency on
            // the generated module only. Consumers never see this code
            // (HFAPIFFI is not in `products`).
            //
            // TODO: drop the language-mode override once UniFFI emits
            // `nonisolated(unsafe) static let` for callback vtables (or
            // gives us a `uniffi.toml` flag for it). Track upstream Swift 6
            // support – the swift-tokenizers fork would benefit equally,
            // so a shared bindgen-template fix is the natural follow-up.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: hfapiFFILinkerSettings
        ),
        .testTarget(
            name: "HFAPITests",
            dependencies: ["HFAPI"]
        ),
        .testTarget(
            name: "HFAPIOAuthTests",
            dependencies: ["HFAPIOAuth", "HFAPIShared"]
        ),
        .testTarget(
            name: "HFAPIHubAuthTests",
            dependencies: ["HFAPIHubAuth"]
        ),
    ]
)
