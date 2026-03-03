# 0.4.0 – Rust-backed Hub client

This release replaces the pure-Swift Hub client with a Rust-backed wrapper around `hf-hub`. The Swift API is rebuilt from the ground up around typed repository handles, native concurrency, and atomic snapshot installs. The maintainer-facing release flow is described in [`docs/release-process.md`](release-process.md); upstream-patch tracking lives in [`docs/upstream-patches.md`](upstream-patches.md).

## Breaking changes

This is a breaking release for every consumer of `0.3.x`. Migrating requires meaningful code changes – there is no compatibility shim.

### API redesign

The `HubClient` type and the `Repo` / `Repo.ID` model have been removed. Code that constructed a `HubClient` and dispatched through `Repo.ID(...)` now uses `HFClient` plus a typed handle:

```swift
// 0.3.x
let client = HubClient(host: URL(string: "https://huggingface.co")!)
let info = try await client.info(for: Repo.ID(rawValue: "openai-community/gpt2")!)

// 0.4.0
let client = try HFClient()
let info = try await client.model(owner: "openai-community", name: "gpt2").info()
```

`HFClient.model(owner:name:)` and `HFClient.dataset(owner:name:)` return kind-specific handles (`ModelRepository`, `DatasetRepository`). The handles share a universal protocol (`info`, `exists`, `listTree`, `pathsInfo`, `fileMetadata`, `listCommits`, `listRefs`, `commitDiff`, `downloadFile`, `uploadFile`, `createCommit`, …). The shape mirrors `hf-hub`'s Rust types.

### `listTree` default recursion flipped to `false`

The pre-migration `HubClient.listFiles` defaulted to `recursive: true`. The new `listTree` defaults to `recursive: false` to match `hf-hub`'s `list_tree` builder. Call sites that depended on the old default need to pass `recursive: true` explicitly:

```swift
// 0.3.x – returned the full tree by default
let files = try await client.listFiles(in: id, kind: .model)

// 0.4.0 – pass recursive: true to match the old behavior
let files = try await client.model(owner: owner, name: name).listTree(recursive: true)
```

### Dropped Hub feature areas

The following 0.3.x APIs have no equivalent in `hf-hub` and have been removed with no replacement:

- **Discussions and pull requests**: every `HubClient.*Discussion*` method.
- **Collections**: `HubClient.listCollections`, `getCollection`, etc.
- **Papers**: `HubClient.papers*`.
- **Billing**: `HubClient.billing*`.
- **Resource groups**: `HubClient.resourceGroup*`.
- **Access requests**: `HubClient.accessRequest*`.

### Scope reduction: Spaces, Kernels, social-graph endpoints

`0.4.0` is scoped to model and dataset workflows. The following surface from 0.3.x is intentionally not re-exposed, even though `hf-hub` would support it:

- **Spaces**: every Space endpoint – `SpaceRepository`, `SpaceInfo`, `listSpaces`, plus `SpaceRuntime`/`SpaceHotReloading`/`Volume`/`SpaceSDK` types.
- **Kernels**: every Kernel endpoint – `KernelRepository`, `KernelInfo`. The Hub's `/api/kernels/{repo_id}` endpoint returns a slim shape that only ever exposed `info()`, so this is not a meaningful loss for the consumer set.
- **Social graph and profiles**: `userOverview`, `organizationOverview`, `listUserFollowers`, `listUserFollowing`, `listOrganizationMembers`, `listOrganizations`. `currentUser()` (calling `/api/whoami-v2`) is kept because it's required for token verification and user-context display.

### Dropped 0.3.x endpoints with no Rust replacement

These existed in 0.3.x but have no equivalent in `hf-hub`. File an upstream issue if your workflow depends on them:

- **OAuth user info**: `getOAuthUserInfo()` (`/oauth/userinfo`).
- **`User.auth` substructure on `whoami-v2`**: the entire `auth` field is dropped – `auth.type` (`"Bearer"` / `"App"` / `"OAuth"`) and `auth.accessToken.{displayName,role}` alike. `hf-hub`'s `User` struct does not surface them.
- **`createBranch` parameters `emptyBranch` and `overwrite`**: `hf-hub`'s commit builder takes only `(branch, revision)`. The 0.3.x `overwrite: true` idempotent-reset primitive is no longer available – delete the branch first if you need that shape.
- **`createRepository` no longer returns the canonical `repoId`**: 0.3.x returned `(url, repoId)` so callers using `existOk: true` could pull the canonical id from the 409 path. `hf-hub`'s `RepoUrl` exposes only `url` today; parse the owner/name back out of the URL if you need it.
- **Hub tag enumeration**: `getModelTags()`, `getDatasetTags()`.
- **Dataset parquet listings**: `listParquetFiles(_:subset:split:)`.
- **Squash and security scans**: `superSquashModel/Dataset`, `scanModel/Dataset`.
- **Tree-size endpoints**: `modelTreeSize`/`datasetTreeSize`/`spaceTreeSize`.
- **Subdirectory listing**: `listTree(path:)` (upstream `list_tree` builder takes no path argument).
- **`Settings.xetEnabled`** flag on `updateSettings`.
- **`resourceGroupId`** on `createRepository` and `updateSettings`: 0.3.x accepted a `resourceGroupId:` argument on both. `hf-hub`'s builders for create-repo and update-settings do not – the field still surfaces on the read side (`ModelInfo.resourceGroup`, `DatasetInfo.resourceGroup`), but cannot be set or changed through this client. File an upstream issue if you need the write side.
- **`info()` parameters**: `securityStatus:` and `filesMetadata:` (upstream's `info()` builder only takes `(revision, expand)`).
- **Listing-builder filter expressivity**: `gated`, `inference`, `language`, `task`, multi-tag, per-field `expand` – upstream's listing builders take a single tag in `?filter=` plus a small fixed parameter set.
- **`/raw/` endpoint for file downloads**: 0.3.x took a `FileDownloadEndpoint` parameter so callers could fetch raw git text via `/raw/` instead of the LFS-resolved `/resolve/` URL. `hf-hub`'s download builder only targets `/resolve/`. File an upstream issue if you need raw-text fetches.
- **`isLFS` flag on file metadata**: 0.3.x returned an `isLFS` boolean on the HEAD-derived file metadata. `hf-hub`'s `FileMetadataInfo` does not expose this directly. The LFS-tracked status is still inferable from an expanded `listTree(expand: true)` (`RepoTreeEntry.file.lfs != nil`).
- **`expectedSize` cache validation parameter**: 0.3.x took an `expectedSize:` argument on `downloadFile` that re-downloaded when the cached blob's size disagreed. The Rust crate validates via ETag/Content-Length internally; there is no caller-side override.
- **`transport: .xet | .lfs | .automatic` selection**: 0.3.x let callers force a transport per download as a workaround for xet outages. `hf-hub` picks the transport internally with no override hook.

### Dropped inference surface

- **Inference providers**: the `ChatCompletion`, `TextToImage`, `TextToVideo`, `FeatureExtraction`, and `SpeechToText` types – the `InferenceProviders` area of the `HFAPI` library in 0.3.x – are removed entirely. Consumers building inference flows should use a dedicated client pointing at the Hub's OpenAI-compatible endpoints (e.g., `swift-openai`-style libraries).

### Dropped Buckets surface

The `HFBucket` type with `create_bucket` / `delete_bucket` / batch-ops is not wrapped in `0.4.0`. It is listed under "Not wrapped" in the README – file an issue or PR if you need it.

### Platform contraction

`Package.swift` declares `[.macOS(.v14), .iOS(.v17)]` only. Mac Catalyst, watchOS, tvOS, and visionOS targets are dropped. The contraction is driven by the Rust artifactbundle's slice list – adding the others requires Rust cross-compile work that no current consumer needs. Mac Catalyst can be reintroduced via `aarch64-apple-ios-macabi` slices on request.

### HTTP stack is owned by Rust `reqwest`

0.3.x took an injectable `URLSession` so callers could plug in their own session for mocking, proxies, or retry adapters. 0.4.0 has no equivalent – every Hub request flows through `reqwest` inside the Rust crate. Test mocking strategies that wrapped `URLSession` need to move to either a mock server (`http-mock`-style) or to fakes one level higher than the transport.

The `cachePolicy: URLRequest.CachePolicy` parameter on 0.3.x's `downloadFile` is also gone – `reqwest` owns the HTTP cache layer entirely. The closest equivalent is `forceDownload: true` (skip the on-disk Hub cache) combined with `networkAccess: .use` (mandate a network request).

### Direct cache-mutation primitives removed

0.3.x exposed `HubCache.storeFile`/`storeData`/`updateRef`/`createSnapshotSymlink` for sideband cache population (corporate mirrors, P2P seeders, custom prefetch jobs). 0.4.0 keeps only the read-side surface: `scanCache()`, `resolveCachedFilePath(_:revision:)`, and `resolveCachedSnapshot(revision:allowPatterns:ignorePatterns:)`. Sideband writers should pre-populate the on-disk layout directly under the configured `cacheDirectory` so a subsequent `snapshotDownload(networkAccess: .bypass)` resolves them.

### Token resolution: single canonical chain

0.3.x took the position that the Swift layer should match the HF CLI / Python `huggingface_hub` library's six-source lookup. 0.4.0 keeps that contract: `Auth.env` (the default when no `auth:` argument is passed) resolves a token from the environment by checking, in priority order:

1. `HF_TOKEN` env var
2. `HUGGING_FACE_HUB_TOKEN` env var
3. File at the path in `HF_TOKEN_PATH`
4. `$HF_HOME/token`
5. `~/.cache/huggingface/token`
6. `~/.huggingface/token`

Resolution runs once synchronously at `HFClient.init` time; the resolved token (or `nil`) is then handed to the Rust crate as a static value, so subsequent Hub calls don't re-stat the filesystem.

Pass `auth: .unauthenticated` to skip env detection entirely. The narrow three-source resolution that `hf-hub`'s own defaults run (`HF_TOKEN`/`HF_TOKEN_PATH`/`$HF_HOME/token`) is no longer a first-class option – it was an implementation detail of the upstream crate rather than a user-facing contract.

### `swift-xet` and `swift-filelock` removed

The package no longer depends on `swift-xet` or `swift-filelock` – the Rust crate handles xet downloads and on-disk locking directly. Consumers depending on those libraries through the package graph need to depend on them explicitly.

### Benchmarks temporarily removed

`Tests/Benchmarks/` is gone. The `mlx-swift-lm` dependency is dropped along with it. Benchmarks may be reintroduced post-`0.4.0` against the new `HFClient` API.

## New features

### OAuth: `signIn` accepts `prefersEphemeralWebBrowserSession`

`OAuthManager.signIn(prefersEphemeralWebBrowserSession:)` now takes a Bool (default `false` to match the previous hardcoded behavior). Pass `true` to force `ASWebAuthenticationSession` into a private mode that doesn't share cookies with the user's regular browser – useful when you want to force a fresh login rather than reuse an existing Hub session.

### `OAuthManager.Scope.displayName` (rename)

The prose accessor for a scope's human-readable label is now `displayName` instead of `description`. The wire value remains on `rawValue`. The previous `description` accessor was conformance-free (`Scope` does not adopt `CustomStringConvertible`), so this is a straight rename.

### OAuth↔HFClient bridge

`HFAPIHubAuth.OAuthClientFactory` wires `OAuthManager` (from `HFAPIOAuth`) into `HFClient`'s dynamic-token provider so OAuth refresh propagates into the Hub client transparently:

```swift
let client = try OAuthClientFactory.client(authManager: manager)
let user = try await client.currentUser()  // refreshes token automatically when needed
```

The bridge propagates OAuth errors precisely. When `validToken()` throws (refresh-token expired, keychain inaccessible, etc.), the next Hub call surfaces `HFError.tokenProviderFailed(message:)` carrying the original `OAuthError`'s `localizedDescription` – distinguishing "OAuth session is dead, prompt user to sign in again" from a generic Hub-side 401. Consumers preferring best-effort semantics (silent fall-through to unauthenticated) bypass `OAuthClientFactory` and pass their own `auth: .provider { try? await ... }` closure to `HFClient`.

### `Auth.provider`

For non-OAuth dynamic-token flows, pass the closure as the `auth` argument:

```swift
let client = try HFClient(auth: .provider {
    try await myStore.fetchCurrent()
})
```

The closure is `@Sendable () async throws -> String?`. Returning `nil` runs the request unauthenticated; throwing aborts the Hub call with `HFError.tokenProviderFailed(message:)`.

The `TokenProvider` enum from `HFAPIShared` is accepted as a first-class alternative to the closure form (`Auth.provider(_:)` has an overload that takes a `TokenProvider`), so composite chains compose value-typed and reusable:

```swift
import HFAPIShared

let client = try HFClient(auth: .provider(.composite([
    .oauth(manager: authManager),
    .environment,
    .fixed(token: "hf_fallback_token"),
])))
```

`TokenProvider.environment` runs the same six-source lookup as the bare `Auth.env` case – useful inside a composite chain where env detection is one fallback among several.

The four `Auth` cases (`.env`, `.unauthenticated`, `.token(_:)`, `.provider(_:)`) are mutually exclusive by construction – the type system prevents combining them, replacing the runtime check the builder used to enforce.

### Streaming progress with cancellation

`downloadFileStream`, `uploadFileStream`, `uploadFolderStream`, `createCommitStream`, etc. return an `AsyncThrowingStream` of progress events plus a `Task<Result, Error>` for the final value. Call `stream.cancel()` to abort the underlying Rust operation via the `OperationHandle` token; the result `Task` then surfaces `HFError.cancelled`.

Non-streaming variants (`uploadFile`, `uploadFolder`, `createCommit`, `downloadFile`, `snapshotDownload`) also propagate cancellation: cancelling the parent Swift `Task` fires the same `OperationHandle.cancel()` via `withTaskCancellationHandler` so the Rust future drops at its next `tokio::select!` poll. There is no manual cancellation handle to hold; `Task.cancel()` is the contract.

### Resumable cached downloads

A cached `downloadFile` (no `localDir` set) that is interrupted by a network drop, process kill, or task cancellation preserves the partial bytes in the cache's `.incomplete` file. The next attempt sends `Range: bytes=N-` and appends only the remaining bytes – the download picks up where it left off rather than restarting from byte 0. This is the v0.3.x behavior, preserved through the migration via a fork patch on `hf-hub` (see `docs/upstream-patches.md`).

Mid-stream transient errors (connection drop, read timeout, 5xx body close) trigger an internal retry that re-issues the GET with an updated Range header. Up to 5 retries; the budget resets each time a call wrote any bytes, so a connection that drops every few MB still completes.

`forceDownload: true` clears any existing partial before retrying, matching `huggingface_hub` (Python) semantics – use it when you want a guaranteed-fresh download.

Xet-backed files (large `.safetensors` weights, etc.) follow a different path. Their `.incomplete` file is an atomicity marker only; xet-core truncates and reassembles it on every attempt. Cross-attempt "resume" comes from the chunk cache at `<HF_HOME>/xet/chunk-cache/`: chunks fetched during the interrupted attempt are durably cached and reused on retry, so the network cost on resume is typically near-zero in the common case (same machine, chunk cache intact).

Resume on a different machine or after the chunk cache has been evicted falls back to a full re-fetch for the Xet path. The LFS path's `.incomplete`-driven resume is independent of any chunk cache and survives both scenarios.

### Progress callback / closure-only

0.3.x took a `Foundation.Progress` instance on `downloadFile`/`snapshotDownload`. 0.4.0 replaces this with either:

- a `(@Sendable (DownloadEvent) -> Void)?` closure passed directly to the async method; or
- the matching streaming variant (`downloadFileStream`, …) that yields typed events via an `AsyncSequence`.

The closure/stream model is strictly more expressive than `Progress` (chunk-level events, error context, transport-level signals), but consumers wired into AppKit/UIKit `Progress` trees have to build their own `Progress` instance and update it from the event closure.

### Downloads work on every wrapped repository kind

`downloadFile`, `downloadFileStream`, `downloadFileToBytes`, `downloadFileBytesStream`, and `snapshotDownload` are declared on `RepositoryProtocol` – both kind handles (`ModelRepository`, `DatasetRepository`) expose the full download surface. The `0.3.x` `HubClient.downloadFile(kind:)` parameter is replaced by dispatching through the kind-typed handle.

### `snapshotDownload` surfaces `localDir` and `networkAccess`

```swift
try await client
    .model(owner: "openai-community", name: "gpt2")
    .snapshotDownload(
        localDir: URL(fileURLWithPath: "/data/models/gpt2"),  // optional
        networkAccess: .bypass                               // optional
    )
```

The download API takes a `networkAccess: NetworkAccess` (default `.default`, which resolves to `.useIfAvailable` on Apple platforms and `.use` on Linux). `.useIfAvailable` consults `NetworkMonitor.shared.state.shouldUseOfflineMode()` and falls back to the cache automatically when offline. `.use` permits network access on cache miss; `.bypass` forces cache-only (throws `localEntryNotFound` on miss). The `.useIfAvailable` case is Apple-only; on Linux there is no `NWPathMonitor`, so detection isn't meaningful and the default collapses to `.use`.

### Typed sort values for listing endpoints

`HFClient.listModels(...)` and `HFClient.listDatasets(...)` take `RepoSort` values on the `sort:` parameter. `RepoSort` is a `RawRepresentable` struct with canonical values (`.downloads`, `.likes`, `.createdAt`, `.lastModified`, `.trendingScore`) plus a raw-string escape hatch for Hub fields this library does not yet expose:

```swift
let trending = try await client.listModels(sort: .trendingScore, limit: 20)
let custom = try await client.listModels(sort: RepoSort(rawValue: "newField"), limit: 20)
```

### Per-repo convenience methods

- ``fileExists(_:revision:)`` – Bool-returning per-file existence check, on every repo handle. Collapses `entryNotFound` to `false`; other errors propagate as `HFError`.
- ``resolveCachedFilePath(_:revision:)`` – returns the on-disk URL of an already-cached file at a revision, or `nil` if not cached. Single-file counterpart to ``resolveCachedSnapshot(revision:allowPatterns:ignorePatterns:)``.
- ``uploadFiles(files:revision:commitMessage:commitDescription:createPR:parentCommit:progress:)`` – upload a `[pathInRepo: URL]` mapping in one commit. Convenience over ``createCommit(operations:…)``.
- ``deleteFiles(pathsInRepo:revision:commitMessage:createPR:)`` – delete N arbitrary paths in one commit. Convenience over ``createCommit(operations:…)``.

### JSON-typed fields surface as raw `String`

Free-form-JSON fields like `ModelInfo.cardData` and `DatasetInfo.cardData` (which existed in 0.3.x as `Data?`) are now `String?` carrying the raw JSON text. New types in 0.4.0 that hold Hub-supplied JSON fragments (`BlobSecurityInfo.avScan` / `.pickleImportScan`, several `ModelInfo` fields like `gguf` / `config` / `evalResults`) follow the same convention. Feed `cardData?.data(using: .utf8)` into `JSONDecoder` / `JSONSerialization` to decode the payload your caller cares about. The String shape avoids a wasteful UTF-8 round-trip and makes the payload directly debuggable.

The `info(...)` builder also no longer accepts a typed `expand:` parameter – it takes `[String]?` instead. Pass Hub-side field names directly (e.g., `expand: ["author", "downloads", "cardData"]`). The pre-migration `ExtensibleCommaSeparatedList<ModelExpandField>` shape is gone; a typed enum may return in a future release if a consumer asks for it.

### `NetworkMonitor` is public

Apple platforms can read `await NetworkMonitor.shared.state.shouldUseOfflineMode()` directly. Most consumers don't need to – `snapshotDownload(...)` consults it automatically when `networkAccess` is left at its `.default` (which is `.useIfAvailable` on Apple).

### Atomic snapshot installs and xet-aware downloads

Inherited from `hf-hub`. Snapshot directories install atomically – partial downloads no longer leave the cache in a half-applied state. Xet-deduplicated content downloads through the upstream's xet-cas integration.

## Coordination notes

Downstream consumers (`swift-tokenizers`, `mlx-swift-lm`) need branches that compile against `0.4.0`. The legacy `HubClient` / `Repo.ID` references those projects rely on are gone. Coordinate the downstream branches and tag `0.4.0` near-simultaneously – there is no compat target.

## Verifying the migration

```
HFAPI_RUST_LOCAL_ARTIFACTBUNDLE_PATH=rust/target/artifactbundle/HFAPIRust.artifactbundle \
  HFAPI_ENABLE_INTEGRATION_TESTS=1 HFAPI_RUN_HUB_MUTATION_TESTS=1 swift test
```

The live-Hub integration suites (named `… – live Hub`) are gated behind `HFAPI_ENABLE_INTEGRATION_TESTS=1`, so CI and tokenless runs skip them; the local-only suites always run. Within the integration suites, authenticated and Hub-mutating tests further require `HF_TOKEN` and `HFAPI_RUN_HUB_MUTATION_TESTS=1`. The full suite passes on macOS 14 with the Apple-only artifactbundle.
