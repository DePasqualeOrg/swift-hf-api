# Naming conventions

This document records the type-naming convention for the public Swift API after the migration from the pure-Swift library to the Rust-backed wrapper (the `rust-migration` branch), and the reasoning behind it. It exists so the naming is settled and consistent before the branch merges into `main`.

## Decision

The public API keeps the `HF` prefix introduced on this branch. It does **not** revert to the old `Hub` prefix, and it does **not** apply `HF` to every type. The rule is **prefix the entry points, leave the value types bare**:

- Apply the `HF` prefix to two categories only:
  1. The primary client entry point: `HFClient`.
  2. Public error types: `HFError`, `HFCacheDeletionError`.
- Leave everything else bare and let the module (`HFAPI`, `HFAPIOAuth`, `HFAPIShared`) provide the namespace. This covers value and info types, repository handles, streams, events, progress types, and the enums mirrored from Rust.
- Use the word "Hub" only when it names the Hugging Face Hub *service*, never as a Swift type-name prefix. Internal helpers such as `parseHubTimestamp` are fine because they describe data the Hub returns.

## Why `HF` and not `Hub`

The `HF` prefix mirrors the Rust crate this library wraps, and that naming is upstream-canonical rather than a local invention.

- The wrapped crate, `huggingface/hf-hub`, uses the `HF` prefix as its own public convention on `main` (heading to `v1.0.0-rc.0`): `HFClient`, `HFClientBuilder`, `HFError`, `HFCacheInfo`, `HFRepository`, `HFBucket`, `HFFileDiff`, `HFDiffParseError`.
- That convention entered the crate through Hugging Face's own work (the "Port `huggingface_hub_rust` into hf-hub" change), not through our fork. Our fork only carries the PR-shaped patches listed in `rust/Cargo.toml`; it does not introduce the prefix.
- The old `Hub*` names (`HubClient`, `HubCache`) were the previous pure-Swift library's coinage. Reverting to them would diverge from the crate we wrap and from Hugging Face's own direction, so `HF` is the better-grounded choice.

## Why "entry points only" and not "mirror Rust exactly"

Mirroring Rust one-for-one would mean adding `HF` to `CacheInfo`, `FileDiff`, and the repository handles. We chose not to, for three reasons:

- Rust itself does not prefix its value types. `RepoType`, `RepoTreeEntry`, `RepoSibling`, `RepoUrl`, `Cache`, `ModelInfo`, `DatasetInfo`, `CommitInfo`, and `User` are all bare in the crate. The crate's real rule is the same one we adopt here: prefix the facades, leave the values bare. "Mirror Rust exactly" would therefore still leave most value types bare, so it does not actually buy uniform prefixing.
- Swift modules already provide a namespace. A consumer writes `import HFAPI` and refers to `ModelInfo` or `CacheInfo` unambiguously, so the prefix carries no information the module does not already carry. Rust leans on the prefix more heavily because its public surface is a flat re-export where `hf_hub::HFClient` is the disambiguator at the call site.
- The two prefixed categories have concrete justifications that the value types lack. A bare `Client` is uninformatively generic and is the primary symbol consumers import, and a bare `Error` collides with the `Swift.Error` protocol. Keeping `HF` on the client and the error types resolves both, and prefixing every error type (rather than only the colliding one) keeps the sub-rule crisp.

## The rule applied to the current public API

The hand-written public API already conforms, with the stragglers noted in the next section. Generated UniFFI bindings are out of scope (see below).

### Prefixed (keep `HF`)

| Swift type | Rust counterpart | Category |
| --- | --- | --- |
| `HFClient` | `HFClient` | Client entry point |
| `HFError` | `HFError` | Error |
| `HFCacheDeletionError` | (surfaced via `HFError` in Rust) | Error |

### Bare (keep unprefixed, module-namespaced)

| Swift type | Rust counterpart | Note |
| --- | --- | --- |
| `CacheInfo` | `HFCacheInfo` | Value type; Swift drops the prefix deliberately. |
| `FileDiff` | `HFFileDiff` | Value type; Swift drops the prefix deliberately. |
| `ModelRepository`, `DatasetRepository` | `HFRepository<T>` | Swift splits the one generic handle into two concrete, module-namespaced types and leaves them bare. |
| `ModelInfo`, `DatasetInfo`, `CommitInfo`, `CommitOperation`, `CommitAuthor` | same names, bare | Already matches Rust. |
| `User`, `OrgMembership`, `RepoSibling`, `RepoTreeEntry`, `RepoType` | same names, bare | Already matches Rust. |
| `GlobMatcher`, `FileMetadata`, `FileProgress`, `FileStatus` | same names, bare | Already matches Rust. |
| `DownloadEvent`, `UploadEvent`, `GitRefs`, `GitStatus`, `XetOperation`, `SegmentRole`, `PathKind` | same names, bare | Already matches Rust. |
| `HTTPErrorContext` | `HttpErrorContext` | Bare; Swift capitalizes the `HTTP` initialism per Swift convention. |

The two deliberate Swift deviations from Rust are worth calling out: `CacheInfo`/`FileDiff` stay bare where Rust prefixes them, and the repository handles stay bare and concrete where Rust has a single generic `HFRepository<T>`. Both are consistent with the "entry points only" rule and read clearly once the module is imported. If we later decide repository handles read better as facades and want them prefixed, that is the one place the rule could reasonably bend; the recommendation here is to keep them bare.

## Stragglers to fix

These are the `Hub`-prefixed type names left over from the old library. They are the only public type names that violate the convention.

### `HubClientManager` (in module `HFAPIHubAuth`) — renamed to `OAuthClientFactory`

This is an enum used as a namespace for a single static factory, `client(authManager:)`, which builds an `HFClient` wired to OAuth token refresh. Because it produces an `HFClient` and is neither the client nor an error, the `Hub` here was a leftover type-prefix rather than a reference to the service, so it was renamed to `OAuthClientFactory`, giving `OAuthClientFactory.client(authManager:)` at the call site.

### Module and product `HFAPIHubAuth` — kept

The module name is kept as is. Read as "authentication for the Hub," it falls under the service carve-out: `Hub` names the Hugging Face Hub the module authenticates against, not a Swift type, which is the same justification that lets `parseHubTimestamp` keep its name. With `OAuthClientFactory` as the type inside it, no `Hub` token is used as a type-name prefix anywhere in the public surface. Keeping the name also avoids a breaking product rename for consumers.

## Out of scope

- **Generated UniFFI bindings** (`Sources/HFAPIFFI/Generated/`, and the `*Dto`/`*DTO`/`*Ffi`/`Uniffi*`/`FfiConverter*` types): these are emitted mechanically by UniFFI from the Rust crate. Their names follow the Rust side and the bindgen, and we do not hand-edit them.
- **Internal and `package` types** (for example `HFLog`, which is `package`, not `public`): outside the public-API convention. `HFLog` may keep its prefix as an internal logging facade where a bare `Log` would be too generic.
- **Test-internal helpers** (for example `HubMutationGate`): "Hub" here names the service (the gate guards mutation tests run against the Hub). These are not public API and were left as is.

Test naming follows the same spirit (see "Test naming" below): suites are internal, so they carry no decorative prefix.

## File names

Each file is named after the primary type it declares, so the file-name prefix follows the type-name convention above: `HFClient.swift`, `HFClient+*.swift`, and `HFError.swift` keep `HF` because they hold those prefixed types; files holding bare value types drop it. Feature-grouping files that declare several related bare types take the bare feature name (`CacheDeletion.swift`, `RepoLifecycle.swift`, `RepositoryDownload.swift`, `CommitsAndDiffs.swift`). Extension files mirror the extended type (`RepositoryProtocol+Defaults.swift`, `CacheInfo+Conveniences.swift`).

Files renamed to match their type: `HFCacheInfo.swift` to `CacheInfo.swift`, `HFCacheInfo+Conveniences.swift` to `CacheInfo+Conveniences.swift`, `HFCacheDeletion.swift` to `CacheDeletion.swift`, `HFAuth.swift` to `Auth.swift`, `HFOperationHandle.swift` to `OperationHandle.swift`, `HFCommitInfo.swift` to `CommitInfo.swift`, `HFCommitOperation.swift` to `CommitOperation.swift`, `HFModelRepository.swift` to `ModelRepository.swift`, `HFDatasetRepository.swift` to `DatasetRepository.swift`, `HFRepoLifecycle.swift` to `RepoLifecycle.swift`, `HFRepositoryDownload.swift` to `RepositoryDownload.swift`, `HFRepositoryProtocol.swift` (and its `+Conveniences`/`+Defaults`/`+Internal`/`+PolymorphicDefaults` extensions) to `RepositoryProtocol.swift`, `HFUser.swift` to `User.swift`, `HFAPIHubAuth/HFAPIHubAuth.swift` to `HFAPIHubAuth/OAuthClientFactory.swift`, and the test file `HFAPIHubAuthTests/HFAPIHubAuthTests.swift` to `OAuthClientFactoryTests.swift`.

Deliberately kept: `HFClient*.swift`, `HFError.swift`, and `HFLog.swift` (their types keep the prefix); `HubTimestamp.swift` (its `parseHubTimestamp` helper names the Hub service, not a type); the generated `HFAPIFFI.swift`; the test helper `HubMutationGate.swift`; and the target directories `Sources/HFAPIHubAuth/` and `Tests/HFAPIHubAuthTests/`, since those carry the kept module name. Renaming files within a SwiftPM target needs no `Package.swift` change, because the targets are declared by directory `path:` and the manifest lists no per-file sources.

## Test naming

A test suite is internal, not a public type, so its struct name carries no decorative `HF` prefix — the `HFAPITests` target already namespaces it. Suite structs and their files use bare names (`ClientConstructionTests` in `ClientTests.swift`, `UploadTests` in `UploadTests.swift`, `ErrorMappingTests` in `ErrorMappingTests.swift`). Files that group several related suites take the bare area name (`DownloadTests.swift`, `RepositoryTests.swift`).

The `@Suite("…")` display strings are left untouched where they name the real API under test — `@Suite("HFClient construction")`, `@Suite("HFError mapping – live Hub")`, `@Suite("ModelRepository.downloadFileToBytes – live Hub")` — because there `HFClient` and `HFError` are the actual public type names, not decoration. The one stale label that named a removed `HFCacheDeletion` type was updated to `@Suite("Cache deletion – local")`. The test-helper error `HFTestTimeoutError` was renamed to `TestTimeoutError`. The shared helper `HubMutationGate` was kept (service reference).

## Implementation checklist

- [x] Confirm the replacement name for `HubClientManager`: `OAuthClientFactory`.
- [x] Keep the `HFAPIHubAuth` module/product name (service carve-out; no breaking product rename).
- [x] Rename `HubClientManager` to `OAuthClientFactory` across `Sources/HFAPIHubAuth/`, the doc-comment cross-references in `Sources/HFAPI/` (`Auth.swift`, `HFError.swift`), the tests (the suite, `OAuthClientFactoryTests`, and the keychain/user-agent identifiers), and `README.md`.
- [x] Run `swift build` and `swift test` to confirm the renames are complete and nothing references the old names.
- [x] Align `HF…​.swift` file names that hold bare types with their type names via `git mv` (see "File names" below).
