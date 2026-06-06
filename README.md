# Swift HF API

A Swift client for the Hugging Face Hub, backed by the Rust [`hf-hub`](https://github.com/huggingface/hf-hub) crate. This package is intentionally limited the models and datasets used for local inference and training.

Swift HF API is independently maintained and is not associated with Hugging Face.

## Status

The library is pre-1.0. Expect breaking changes.

## What's covered

- **Repositories**: `model(owner:name:)` and `dataset(owner:name:)` handles. Each handle exposes the universal protocol methods (`info`, `exists`, `listTree`, `pathsInfo`, `fileMetadata`, `listCommits`, `listRefs`, `commitDiff`, …).
- **Listing**: `listModels` and `listDatasets` with `hf-hub`'s filter / sort / search builders.
- **Downloads**: `downloadFile`, `downloadFileToBytes`, `downloadFileBytesStream`, `snapshotDownload`. Progress events stream through `AsyncThrowingStream`; cancellation flows from the consumer back to the Rust side via the `OperationHandle` token.
- **Uploads**: `uploadFile`, `uploadFileBytes`, `uploadFolder`, `createCommit`, `deleteFile`, `deleteFolder`. Streaming variants emit `UploadEvent`s and resolve to a `CommitInfo`.
- **Repo lifecycle**: `createRepository`, `deleteRepository`, `moveRepository`, `updateSettings`.
- **Branches and tags**: `createBranch`, `deleteBranch`, `createTag`, `deleteTag`.
- **Cache scan**: `scanCache()` returns a `CacheInfo` that mirrors the shape `huggingface-cli scan-cache` reports.
- **Auth**: `currentUser()` for verifying the current token; OAuth refresh is glued into `HFClient` via `HFAPIHubAuth` so the inner client rotates tokens transparently.

## Modules

- **`HFAPI`**: the main client. `HFClient`, `ModelRepository`, `DatasetRepository`, `CacheInfo`, error types. Apple platforms also expose `NetworkMonitor` for explicit offline-mode checks; Linux omits it (no `NWPathMonitor` equivalent – provide your own detection or pass `.use` / `.bypass` to `NetworkAccess`).
- **`HFAPIOAuth`**: Apple-platform OAuth flow. `OAuthManager`, `OAuthClient`, keychain token storage. Linux compiles to an empty target.
- **`HFAPIHubAuth`**: the OAuth↔HFClient bridge. `OAuthClientFactory.client(authManager:)` returns a fully wired `HFClient` whose token rotates with the manager.
- **`HFAPIShared`**: shared types. `TokenProvider` (used by `HFAPI` and `HFAPIOAuth`).

## Usage

### Basic client

```swift
import HFAPI

// Reads token + endpoint from environment (HF_TOKEN, HF_ENDPOINT, etc.).
let client = try HFClient()

let info = try await client.model(owner: "openai-community", name: "gpt2").info()
print(info.id, info.tags ?? [])
```

Configure explicitly with named parameters:

```swift
let client = try HFClient(
    endpoint: "https://huggingface.co",
    auth: .token("hf_…"),
    userAgent: "MyApp/1.0"
)
```

### Snapshot download

```swift
let url = try await client
    .model(owner: "openai-community", name: "gpt2")
    .snapshotDownload(allowPatterns: ["*.json", "*.txt"])
print("Snapshot at:", url.path)
```

### Streaming progress

`downloadFileStream` returns a ``DownloadStream`` – an `AsyncSequence` of ``DownloadEvent``. Iterate for progress, then `await stream.value` for the on-disk URL. Call `stream.cancel()` (or break out of the loop) to abort.

```swift
let stream = client
    .model(owner: "owner", name: "name")
    .downloadFileStream("model.safetensors")

for try await event in stream {
    if case let .aggregateProgress(bytesCompleted, totalBytes, _) = event {
        print("\(bytesCompleted) / \(totalBytes)")
    }
}
let url = try await stream.value
```

### Authentication

`HFClient` accepts a token in three shapes; pick whichever fits the use case.

#### Static token

For a single fixed token (CLI scripts, environment-driven flows):

```swift
let client = try HFClient(auth: .token("hf_…"))
```

When `auth` is omitted (or set to `.env`), `HFClient` resolves a token from the environment at construction time, checking in priority order: `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, the file at `HF_TOKEN_PATH`, `$HF_HOME/token`, `~/.cache/huggingface/token`, then `~/.huggingface/token`. The order matches the HF CLI and Python `huggingface_hub` library. Pass `auth: .unauthenticated` to skip env detection entirely.

#### OAuth via `OAuthClientFactory` (recommended for OAuth flows)

`OAuthManager` is `@MainActor`-isolated, so construct it from a main-actor context (e.g., a SwiftUI `App` initializer or a `@MainActor` setup function):

```swift
import HFAPI
import HFAPIOAuth
import HFAPIHubAuth

@MainActor
func makeAuthenticatedClient() async throws -> HFClient {
    let manager = try OAuthManager(
        clientID: "your-client-id",
        redirectURL: URL(string: "myapp://oauth")!,
        scope: .basic,
        keychainService: "com.example.app",
        keychainAccount: "huggingface"
    )
    return try OAuthClientFactory.client(authManager: manager)
}

// Hub calls transparently consult the manager for a fresh token.
// When the OAuth token rotates, the inner Rust client is rebuilt.
let client = try await makeAuthenticatedClient()
let user = try await client.currentUser()
```

The bridge propagates OAuth errors precisely. When `validToken()` throws (refresh-token expired, keychain inaccessible), the next Hub call surfaces `HFError.tokenProviderFailed(message:)` carrying the original `OAuthError`'s `localizedDescription`. Pattern-match on `tokenProviderFailed` to drive a re-sign-in prompt.

#### Composable provider (`TokenProvider`)

Pass a `TokenProvider` from `HFAPIShared` for multi-source chains. The cases are `.fixed(token:)`, `.environment`, `.oauth(manager:)`, `.composite([…])`, and `.custom { … }`. `.environment` uses the same six-source lookup list as `Auth.env`.

```swift
import HFAPIShared

let client = try HFClient(auth: .provider(.composite([
    .oauth(manager: authManager),
    .environment,
    .fixed(token: "hf_fallback_token"),
])))
```

Note: `TokenProvider.composite([…])` short-circuits when a sub-provider throws – it does **not** advance to the next on error, only on `nil`. To skip an OAuth provider that's failing rather than abort the chain, wrap it in a `.custom` that catches: `.custom { try? await manager.validToken() }`.

#### Custom closure

For one-off custom token logic where a `TokenProvider` would be overkill:

```swift
let client = try HFClient(auth: .provider {
    try await myCustomTokenStore.fetchCurrent()
})
```

The closure is `@Sendable () async throws -> String?`. Returning `nil` runs the request unauthenticated; throwing aborts the Hub call with `HFError.tokenProviderFailed(message:)`. Wrap with `try?` for best-effort semantics where transient failures fall through to unauthenticated requests.

The four `Auth` cases (`.env`, `.unauthenticated`, `.token(_:)`, `.provider(_:)`) are mutually exclusive by construction – the type system prevents combining them, so there is no runtime "mutual exclusion" failure to handle.

### Offline mode

Download calls take a `networkAccess: NetworkAccess` parameter (default `.default`) that controls whether the network is consulted on a cache miss:

- `.use` – always hit the network on cache miss.
- `.bypass` – cache-only; throws `localEntryNotFound` if the file isn't cached.
- `.useIfAvailable` *(Apple-only)* – consults `NetworkMonitor.shared.state.shouldUseOfflineMode()` and falls back to `.bypass` when offline, `.use` otherwise.

`.default` resolves to `.useIfAvailable` on Apple platforms and `.use` on Linux (no `NWPathMonitor` equivalent).

```swift
// Auto-detect (Apple default): online → fetch; offline → cache.
let url = try await client
    .model(owner: "openai-community", name: "gpt2")
    .snapshotDownload()

// Force cache-only resolution.
let url = try await client
    .model(owner: "openai-community", name: "gpt2")
    .snapshotDownload(networkAccess: .bypass)

// Force network resolution (skip the offline check).
let url = try await client
    .model(owner: "openai-community", name: "gpt2")
    .snapshotDownload(networkAccess: .use)
```

`HFAPI.NetworkMonitor` wraps `NWPathMonitor` and is Apple-only – the symbol does not exist in the Linux build. Linux consumers who need offline-aware behavior should pass `.use` or `.bypass` explicitly based on their own detection. Set `CI_DISABLE_NETWORK_MONITOR=1` to disable the offline-mode signal in CI environments where the path monitor can produce false negatives.

## Testing

- `swift test` runs read-only tests against the live Hub; the mutation tests skip cleanly without an opt-in env var.
- `HFAPI_RUN_HUB_MUTATION_TESTS=1 swift test` opts into the mutation tests (create / upload / delete / branch / tag / commit). Each test creates an isolated `swift-hf-api-test-…-{uuid}` repo under the authenticated user's namespace and tears it down afterward.
- The Rust crate is built and shipped as a SwiftPM artifactbundle. Set `HFAPI_RUST_LOCAL_ARTIFACTBUNDLE_PATH=rust/target/artifactbundle/HFAPIRust.artifactbundle` to point the package at a locally built bundle (see `scripts/rust/` for the assembly pipeline).

## Platform support

macOS 14+, iOS 17+, Linux (excluding OAuth and HubAuth modules)
