# REST recovery — possible future direction

**Status: proposal, no decision made.** This document explores a possible future direction for `swift-hf-api`. Nothing here has been committed to, and the current code intentionally keeps the full FFI wrap as shipped. The doc records the analysis so the option stays available if and when it becomes worth pursuing.

The current state: `swift-hf-api` wraps the full `hf-hub` Rust crate behind a Swift facade. The original experiment was to see what wrapping a Rust crate in Swift would look like. With the answer largely in hand, one direction worth considering is narrowing that wrap to the parts of `hf-hub` where the Rust value is genuinely concentrated, and restoring native-Swift implementations for the pure-REST surface.

If pursued, the scope would mirror what the FFI currently targets: models and datasets. Repositories, files, listings, commits, refs, diffs, and the user/auth surfaces. The broader pre-migration Swift surface (collections, discussions, spaces, papers, etc.) would remain out of scope.

## Where the Rust value is concentrated

| Subsystem | Stay in Rust? | Why |
|---|---|---|
| Xet upload/download | Yes | `xet-core` is Rust-only; no Swift-native path exists. |
| Cache layout (blobs, snapshots, refs, .no_exist, .incomplete) | Yes | Cross-process atomic finalization, symlink/copy platform branching, lock semantics. Subtle enough that hf-hub has shipped race-condition fixes recently. |
| Download orchestration (resume, retry budget, xet branching, HEAD fan-out for snapshots) | Yes | Tightly coupled to cache + xet; the genuinely tricky transport logic. |
| Upload orchestration (LFS classification, preupload, xet preflight, commit API) | Yes | Same shape as download – cache-aware, xet-aware. |
| REST API GET endpoints (info, list_tree, list_commits, refs, diffs, paths_info, file_metadata, exists) | No | HTTP+JSON over `URLSession` + `Codable`. Mature in Swift. |
| REST listing endpoints (list_models, list_datasets) | No | GET with Link-header pagination. |
| REST mutation endpoints (update_settings, create/delete branch/tag) | No | POST/DELETE/PUT with small JSON bodies. |
| Auth on the REST side | No | URLSession can lazily call the existing `TokenProvider`. |
| Network monitor, offline-mode detection | No | Already Swift-native. |

## Recoverable REST surface

All ~16 of these methods existed as native-Swift implementations at commit `31c57ed^` (the pre-migration tip) and could be lifted forward if this direction is pursued.

**On `HFClient`:**

- [ ] `listModels` / `listModelsStream` – paginated GET.
- [ ] `listDatasets` / `listDatasetsStream` – paginated GET.
- [ ] `whoami` – GET `/api/whoami-v2`.

**On `RepositoryProtocol` (model + dataset):**

- [ ] `info()` – GET `/api/<kind>/<repo_id>`.
- [ ] `exists()` – HEAD, 2xx vs 404.
- [ ] `listTree`, `pathsInfo`, `fileMetadata` – tree/path/metadata endpoints.
- [ ] `listCommits`, `listRefs` – commits and refs endpoints.
- [ ] `commitDiff`, `rawDiff`, `rawDiffEntries` – diff endpoints.
- [ ] `updateSettings` – PUT settings JSON.
- [ ] `createBranch` / `deleteBranch` / `createTag` / `deleteTag` – ref mutation endpoints.

## What stays on the FFI path

| Category | Methods |
|---|---|
| File transfer | `downloadFile`, `downloadFileStream`, `downloadFileToBytes`, `downloadFileBytesStream`, `snapshotDownload` |
| Upload orchestration | `uploadFile`, `uploadFileBytes`, `uploadFileStream`, `uploadFileBytesStream`, `uploadFolder`, `uploadFolderStream`, `createCommit`, `createCommitStream` |
| Composite mutation | `deleteFile`, `deleteFolder` (route through `create_commit`) |
| Cancellation, token-provider bridge, progress event types | `OperationHandle`, `FFITokenProvider`, `DownloadEvent`, `UploadEvent` |

The Rust crate keeps `client.rs`, `repository.rs`, `progress.rs`, `cancellation.rs`, and the cache + transfer + xet bindings from `hf-hub`. Roughly half of `dto.rs` (the REST-side DTOs) is deletable.

## What this would gain

- Roughly half the DTO mirror layer would disappear. Every "add a field, mirror in three places" tax would fall off for the REST surface.
- Swift-native URL-loading-system integration on the REST side. `URLSession` honors macOS system proxy configuration (`URLSessionConfiguration.connectionProxyDictionary` and the system network preferences), `NSAppTransportSecurity` per-bundle overrides from Info.plist, and globally registered `URLProtocol` test mocks. `reqwest` sees none of those – it has its own env-var proxy handling and its own TLS stack. Keychain is *not* on this list: the existing OAuth flow already stores tokens in Keychain via `HFAPIOAuth`'s `OAuthManager`, and the resulting token reaches Rust through the `TokenProviderAdapter` callback, so Keychain integration works today regardless of which side owns the HTTP transport.
- Smaller binary footprint and faster builds (less Rust code linked through UniFFI; the same artifactbundle pipeline would shrink).
- Idiomatic Swift API by construction on the REST half – no facade-translation work to hide Rust builder shapes.

### Items that would no longer be blocked on upstream

Twelve of the fifteen "Watching for upstream additions" entries in `docs/upstream-patches.md` would convert from "wait for upstream and then plumb three layers" to "implement directly in Swift when a consumer asks for it":

1. List-endpoint filter coverage on `list_models` / `list_datasets`.
2. `create_branch` `overwrite` and `empty_branch` parameters.
3. `update_settings` xet-enabled field.
4. Dedicated `list_parquet_files` and `tags` endpoints.
5. `getOAuthUserInfo` endpoint.
6. Access-request family on gated repositories.
7. Tree-size endpoint.
8. `createRepository(resourceGroupId:)`.
9. `info(securityStatus:filesMetadata:)` flags on repository info.
10. `FileMetadataInfo::is_lfs` (HEAD response header).
11. Raw status character on `GitStatus::Unknown` (diff parsing).
12. `createModelTag` / `createDatasetTag`.

Three entries would still be upstream-bound because they live on the transfer/FFI side:

- `download_file` transport selector (force LFS vs. force Xet vs. automatic) – transfer concern.
- `HFClient::set_token` (in-place token mutator) – relevant because the FFI client still needs token rotation for transfer operations.
- UniFFI Swift bindgen `nonisolated(unsafe)` on callback vtables – the FFI callback surface shrinks (progress handlers and chunk handlers remain) but doesn't disappear.

## What this would lose

- Free hf-hub bug fixes on the REST side. In practice these are concentrated in the transfer/cache/xet half anyway, which would remain wrapped.
- Future hf-hub additions to the REST surface (the "Watching" list) would need Swift work instead of binding regeneration. But that work was going to be required either way; the question is whether it's "write a Swift method" or "extend DTO, FFI method, Swift wrapper, regenerate bindings."
- Some duplicated effort with `huggingface_hub` (Python) – both languages independently implementing Hub REST. That duplication already exists today since the Python side never wrapped hf-hub.

## Linux networking constraint

The pre-migration Swift stack hit a recurring stability problem on Linux: `FoundationNetworking`'s libcurl-backed `URLSession` crashes under concurrent HTTP requests, even when the surrounding test suite is serialized. The pre-migration `SnapshotDownloadTests` were guarded with `#if swift(>=6.1) && !canImport(FoundationNetworking)` for exactly this reason (commit `e5e5ff7`, "Skip problematic tests on Linux"). A second, narrower instance still lives in `Tests/HFAPIOAuthTests/Helpers/MockURLProtocol.swift:117`: chunked delivery through `URLProtocol` is not stable on FoundationNetworking, so the mock degrades to a single `didLoad`.

This is one of the original motivations for wrapping `reqwest` through Rust. The proposal keeps the transfer/cache/xet half (which is where the concurrent-request pattern lives) inside Rust, so this constraint would not block the direction. But it would shape what "pure-Swift REST" means here:

- The REST GETs in scope (`info`, `exists`, `listTree`, `pathsInfo`, `fileMetadata`, `listCommits`, `listRefs`, diffs, `whoami`) are one-shot requests with no fan-out. They should be safe on FoundationNetworking + libcurl.
- The REST listing endpoints (`listModels`, `listDatasets`) follow Link-header pagination sequentially, so they are also one-shot per page – fine on Linux.
- Parallel REST request patterns should not be introduced on the Swift side without first proving the libcurl backend has been fixed upstream. If a future API genuinely needs concurrent fan-out, it would route through the Rust transfer client instead.
- Treat this as a pre-flight gate, not an assumption: before lifting any REST method back into Swift, run an explicit Linux stress test (described under [Robustness validation on Linux](#robustness-validation-on-linux)) and only proceed if it passes.

## Robustness validation on Linux

The risk to manage is "the FoundationNetworking crash that motivated wrapping Rust hasn't actually gone away on the Swift versions this package ships against." That should be confirmed before lifting any REST method back into Swift, not after.

Validation steps, in order:

1. **Static stress test.** A new Linux-only integration test issues a single REST GET against `huggingface.co` in a tight loop (~200 iterations, serialized) and asserts no crash, no hang, no decode failure. This catches obvious libcurl-handle reuse bugs in the one-shot path.
2. **Concurrent stress test.** A second Linux-only test fires N parallel `info()` requests through a single `URLSession` (N=8, 16, 32) and verifies all complete. This is the exact pattern that crashed pre-migration. If this still crashes, the listing endpoints stay out of the Swift lift and route through Rust.
3. **Lifecycle test.** Create and tear down `URLSession` instances in a loop to surface any handle-leak or finalizer-order bug in the libcurl backend.
4. **Token-provider integration.** A short test confirms the Swift `TokenProvider` flow (lazy fetch, cached, refresh on 401) survives the same loop without leaking sessions or tasks.

These tests would live under `Tests/HFAPILinuxStressTests` (or similar – name TBD) and be gated `#if canImport(FoundationNetworking)` so they only run on Linux CI. They are network-touching by design; mark them with the same trait the existing online tests use so they can be skipped in air-gapped runs.

If steps 1–3 pass, REST methods could be lifted one suite at a time and the existing pre-migration test suite (also lifted) re-run against the Swift implementation on Linux CI before deleting any FFI method.

### Out-of-tree probe result (2026-05-15)

A standalone probe at `/tmp/linux-net-probe` exercised steps 1–3 against `https://huggingface.co/api/models/openai-community/gpt2` inside the `swift:6.2.3` Docker image (aarch64 via OrbStack on macOS):

| Phase | Pattern | Result |
|---|---|---|
| 1 | 200 sequential GETs through a shared `URLSession` | 200/200 (`200=200`), ~29s |
| 2 | 8 / 16 / 32 concurrent in-flight × 3 batches (168 total) | 168/168, sub-second per batch |
| 3 | 50 bursts × 4 in-flight, fresh `URLSession` per burst | 132 × 200, 68 × **429** (HF rate limit, not transport failure), no crash |
| 4 | 30 serial GETs with `Authorization: Bearer …` header attached | 30/30 |

The phase-2 fan-out pattern is the exact shape commit `e5e5ff7` flagged as crashing. It did not crash on Swift 6.2.3. The phase-3 429s are server-side throttling – the requests reached `huggingface.co` and got real HTTP responses back, which is itself evidence that the libcurl backend is delivering correct results under load.

Caveats: aarch64 runner; small JSON payloads only (streaming-body patterns would stay on the Rust side either way). The probe was not promoted to a permanent test target – that would land with the first Swift REST lift if this direction is pursued. The result is recorded here so the assumption "Swift 6.2.3 fixed it" has a citation if the work is later considered.

## Sequencing (if pursued)

1. Restore the pre-migration REST implementations (lift from `31c57ed^`), adapted to the current type system. Keep the FFI surface unchanged for now – the new Swift impls live alongside the FFI-backed defaults.
2. Switch the `FFIBackedRepository` extension's REST methods over to call the Swift impls instead of the FFI defaults. The Rust crate continues to expose those methods, but unused.
3. Delete the now-unused FFI methods and their DTOs from `rust/src/core/{client,repository,dto}.rs`. Regenerate bindings. Drop the corresponding Swift wrapper translation code.
4. Confirm tests pass (rust-on and rust-off), then ship.

Each step would be independently reversible. Step 1 is purely additive; step 2 changes call routing; step 3 is the actual deletion.

## Open questions

- The current `TokenProvider` lives on the Rust side via `FFITokenProvider`. A Swift REST path would need a Swift-side `TokenProvider` view of the same source of truth. Cleanest shape: a Swift `TokenProvider` protocol that the Rust path adapts (rather than the reverse). Pre-migration Swift had this protocol.
- Network monitor and offline-mode detection are already Swift-native; nothing to do.
- Error taxonomy: a Swift REST path would emit Swift-native `HFError` directly instead of going through `HFErrorFFI`. The user-visible `HFError` enum would stay the same; only its construction path would differ.
- Tests: the pre-migration test suite covered the REST surface. Those tests would be lifted alongside the implementations. The transfer-side test suite would remain unchanged.

