# Upstream patches

This project depends on three Rust crates – `hf-hub`, `xet-core`, and `uniffi-rs` – that we patch with small, PR-shaped fixes. Each patch lives as a single commit on a long-lived branch on a `DePasqualeOrg` fork; `swift-hf-api/rust/Cargo.toml` points at the fork's branch via `git = "..."` (for `hf-hub`) or `[patch.crates-io]` (for `xet-core` and `uniffi-rs`). Each commit is independently submittable upstream; when a fix lands upstream, we drop the corresponding commit from our branch and rebase on the new upstream tip.

## Why we maintain a patched fork

Upstream review/release cycles are slow relative to the migration's pace, and a few of the issues we hit are blockers without a workaround that's actually equivalent. Patching the fork keeps us shipping the proper fix instead of accumulating "we route around it because…" tech debt, while still leaving a clean PR-shaped commit ready to go upstream.

We already do this for `uniffi-rs` (BOM-strip fix, `[patch.crates-io]` block in `rust/Cargo.toml`). Adding `hf-hub` to the same pattern is a small extension, not a new mechanism.

## Active patches on `hf-hub`

The fork lives at `https://github.com/DePasqualeOrg/hf-hub` (origin) with `https://github.com/huggingface/hf-hub` as `upstream`. Our cumulative branch is `swift-hf-api-patches`. Each commit on that branch corresponds to one upstream PR.

### 1. HRTB inference failure in `snapshot_download_impl`

**Symptom.** `cargo build` fails when calling `model.snapshot_download()...send().await` from inside `#[uniffi::export(async_runtime = "tokio")]` with:

```
error: implementation of `FnOnce` is not general enough
note: closure with signature `fn(&'0 String) -> ...` must implement `FnOnce<(&'1 String,)>`,
      for any two lifetimes `'0` and `'1`
```

…and a similar error for a closure taking `&DownloadFileParams`.

**Root cause.** Two closures inside `hf-hub/src/repository/download.rs` have non-HRTB-quantified lifetime signatures. Rust can't prove the closure satisfies `for<'a> FnMut(&'a T) -> _` when the resulting future is consumed in a generic-async context (such as the body of a UniFFI-exported async fn):

- Line 595 (`head_futs` inside `snapshot_download_impl`):
  ```rust
  let head_futs = filenames.iter().map(|filename| { ... async move { ... } });
  ```
  The closure receives `&String` from `iter()`. The async block captures `filename.clone()` plus `repo_folder_ref: &PathBuf`, `cache_dir: &Path`, etc.
- Line 879 (`download_concurrently`):
  ```rust
  futures::stream::iter(params.iter().map(|p| api.download_file_inner(p)))
  ```
  The closure receives `&DownloadFileParams` and returns the future from `download_file_inner`.

The same closures compile fine in normal `tokio::main` contexts, so they're invisible to upstream's existing test suite. `download_file_to_bytes` and `download_file_stream` are **not** affected – their builders compile cleanly through the FFI.

**Fix shape.** Take ownership instead of borrowing in both spots:

- `head_futs`: change `filenames.iter().map(|filename| ...)` to `filenames.iter().cloned().map(|filename: String| ...)`. Drops the `let filename = filename.clone();` line that's now redundant. The async block still captures `repo_folder_ref` etc., but those are concrete-lifetime captures, not closure-argument lifetimes – they don't trigger HRTB inference.
- `download_concurrently`: change the signature from `params: &[DownloadFileParams]` to `params: Vec<DownloadFileParams>` and iterate by value: `params.into_iter().map(|p| async move { api.download_file_inner(&p).await })`. Two call sites in `snapshot_download_impl` need to clone or move into the helper accordingly.

Both edits are 5–10 lines and structurally minimal. Behavior is identical: the closures still produce the same per-file metadata-fetch and per-file download futures.

**PR title and description sketch.**

> **Make snapshot_download_impl closures HRTB-clean**
>
> Two closures in the snapshot-download path have non-HRTB-quantified lifetime
> signatures that prevent the surrounding async fns from being consumed in
> generic-async contexts (e.g., as the body of an async fn exported through
> UniFFI's `tokio` runtime). Rust can't infer `for<'a> FnMut(&'a T) -> _` for
> closures that return futures borrowing from the closure argument; the fix
> is to pass owned values instead.
>
> Specifically:
> - `head_futs` in `snapshot_download_impl` takes `&String` from `filenames.iter()`.
>   Switch to `filenames.iter().cloned()` so the closure receives `String` and
>   the redundant inner `filename.clone()` can be dropped.
> - `download_concurrently` takes `params: &[DownloadFileParams]` and the closure
>   receives `&DownloadFileParams`. Switch to `params: Vec<DownloadFileParams>`
>   and `params.into_iter().map(|p| async move { ... })`. Two call sites in
>   `snapshot_download_impl` updated to pass by value.
>
> Behavior is identical: same per-file metadata-fetch and per-file download
> futures, same parallelism, same xet batching. The change is purely about
> closure shape so the compiler can prove the HRTB requirement.
>
> Repro for the original failure:
>
> ```rust
> #[uniffi::export(async_runtime = "tokio")]
> impl Wrapper {
>     pub async fn snap(&self) -> Result<String, MyError> {
>         self.client.model("o", "n").snapshot_download().send().await?;
>         Ok("ok".into())
>     }
> }
> // error: implementation of `FnOnce` is not general enough
> // closure with signature `fn(&'0 String) -> ...` must implement
> // `FnOnce<(&'1 String,)>`, for any two lifetimes `'0` and `'1`
> ```
>
> After this PR, the same code compiles.

**Upstream PR status.** Pending – to be filed by the user.

### 2. TLS backend selection

**Symptom.** `hf-hub` consumers cannot opt into `native-tls`. The current upstream `Cargo.toml` does:

```toml
reqwest = { version = "0.13", features = ["json", "stream", "multipart", "query"] }
```

…which inherits reqwest 0.13's default features (`charset`, `http2`, `system-proxy`, `default-tls`). Reqwest 0.13's `default-tls = ["rustls"]` – this version flipped the default to rustls. So the existing situation is: consumers get rustls, with no documented or supported way to switch. The recently merged `rustls-tls = ["reqwest/rustls"]` feature (#160) is effectively a no-op – it enables what's already enabled by default.

The migration doc's earlier claim that "Security.framework is still pulled in by reqwest's default features alongside rustls" is empirically false on reqwest 0.13: `cargo tree` shows rustls only, no `hyper-tls` / `native-tls-crate`. The "duplicate TLS stacks" worry was based on reqwest ≤ 0.12 behavior.

This patch is therefore purely additive – it enables per-platform TLS choice (e.g., native-tls on Apple to leverage `Security.framework`, rustls on Linux to avoid `openssl-sys`) without changing the default for any existing consumer.

**Fix shape.**

```toml
[dependencies]
reqwest = { version = "0.13", default-features = false, features = ["json", "stream", "multipart", "query", "charset", "http2", "system-proxy"] }

[features]
default = ["rustls-tls"]
native-tls = ["reqwest/native-tls"]
rustls-tls = ["reqwest/rustls"]
blocking = ["tokio/rt"]
```

Behavior preservation argument:

- Existing consumers using `hf-hub = "1"` (no feature config) used to inherit `default-tls=rustls` + `charset` + `http2` + `system-proxy` from reqwest. After the patch they get the same set, just routed through `default = ["rustls-tls"]` + the explicit reqwest features.
- Existing consumers using `features = ["rustls-tls"]` get the same result as before (rustls-tls is in default; adding it again is a no-op).
- New: consumers who want `native-tls` set `default-features = false, features = ["native-tls"]`. New: consumers who want rustls and want to be sure native-tls isn't linked transitively set `default-features = false, features = ["rustls-tls"]`.

The naming follows reqwest's own user-facing feature conventions (`native-tls`, `rustls`); we expose them under hf-hub's namespace as `native-tls` and `rustls-tls` (matching the existing `rustls-tls` from #160).

**Why upstream should want this.** It's strictly additive (zero behavior change for any existing consumer), follows reqwest's naming, opens up native-tls for Apple consumers who care about binary size and Security.framework integration, and lets rustls-only consumers prove there's no native-tls in their dep tree.

**PR title and description sketch.**

> **Add native-tls feature alongside rustls-tls**
>
> Currently consumers cannot opt into reqwest's native-tls backend – only the
> default rustls path is available. This PR adds a `native-tls` feature that
> mirrors the existing `rustls-tls` feature, with `default-features = false`
> on the reqwest dep so the TLS backend can be selected explicitly.
>
> All previously-implicit reqwest defaults (`charset`, `http2`, `system-proxy`)
> are re-enabled explicitly so disabling defaults doesn't silently regress
> behavior. The `default` feature continues to enable `rustls-tls`, so any
> consumer not changing their feature configuration sees no behavior change.
>
> Verified with `cargo tree`: with no features changed, the dep tree is
> identical before and after this PR. With `default-features = false,
> features = ["native-tls"]`, only native-tls is linked.

**Upstream PR status.** Pending – to be filed by the user.

### 3. Per-builder `disable_implicit_token`

**Symptom.** Consumers using `HFClientBuilder` to set up a client whose token is supplied dynamically (via `swift-hf-api`'s `FFITokenProvider` callback, vault-backed credentials, etc.) cannot suppress the implicit token resolution chain (`HF_TOKEN` env, `HF_TOKEN_PATH`, `$HF_HOME/token`) on a per-builder basis. The only escape today is `HF_HUB_DISABLE_IMPLICIT_TOKEN=1`, which is a process-wide env mutation and a side-effect from a library's perspective.

For `swift-hf-api`'s dynamic-token mode this means: when the foreign provider returns `nil` (e.g., user signed out of OAuth), the inner `HFClient` still runs against whatever ambient token the env chain resolves. The provider was supposed to be the only source of truth – instead, an env-side token bleeds through and authenticates the request the consumer expected to be unauthenticated.

**Root cause.** `HFClientBuilder::build()` calls `let token = self.token.or_else(resolve_token);`. When `self.token` is `None`, `resolve_token()` is unconditional except for the process-wide env-var check. There's no per-builder opt-out.

**Fix shape.**

- Add `disable_implicit_token: Option<bool>` to `HFClientBuilder`.
- Add `pub fn disable_implicit_token(mut self, disable: bool) -> Self` setter.
- In `build()`, gate the `or_else` on the new flag:
  ```rust
  let token = self.token.or_else(|| {
      if self.disable_implicit_token.unwrap_or(false) {
          None
      } else {
          resolve_token()
      }
  });
  ```
- Three new unit tests mirroring the existing `HF_HUB_DISABLE_IMPLICIT_TOKEN` env-var coverage.

**Why upstream should want this.** Strictly additive – every existing consumer keeps the documented env-fallback behavior. The new method gives library wrappers (anything embedding `hf-hub` behind a token provider of their own) a clean way to disable env fallback without a process-wide side effect. Builder-scoped flags follow the existing patterns on the same struct (`cache_enabled`, `retry_max_attempts`, etc.).

**PR title and description sketch.**

> **Per-builder `disable_implicit_token` option**
>
> The `HF_HUB_DISABLE_IMPLICIT_TOKEN` env var lets callers disable the
> implicit token resolution chain (`HF_TOKEN`, `HF_TOKEN_PATH`,
> `$HF_HOME/token`), but only process-wide. Library wrappers that embed
> `hf-hub` behind their own dynamic-token mechanism (OAuth refresh,
> vault-backed credentials, …) can't use that mechanism without
> reaching into the process environment, which is a side effect from
> their consumer's perspective.
>
> This PR adds a `disable_implicit_token(bool)` method on
> `HFClientBuilder` that toggles the same logic per-builder. An
> explicit `.token(...)` always wins, matching the env-var precedence.
>
> Strictly additive: existing consumers keep the documented
> env-fallback behavior. New unit tests cover the explicit-wins,
> implicit-blocked, and false-passthrough cases.

**Upstream PR status.** Pending – to be filed by the user.

### 4. Resumable cached downloads

**Symptom.** A cached file download (`HFRepository::download_file` with no `local_dir`) that is interrupted mid-stream — network drop, process kill, OS sleep, cancelled task — discards everything received so far and restarts from byte 0 on the next call. For a multi-GB model on a flaky connection this is the difference between "eventually finishes" and "never finishes".

**Root cause.** `download_file_inner` in `hf-hub/src/repository/download.rs:470-497` writes the response body to `<blob>.incomplete` via `stream_response_to_file_with_progress`, which opens the destination with `std::fs::File::create(dest)` (`download.rs:906`). `create` truncates if the file exists, so any partial bytes from a prior run are discarded. The GET sent at line 478 has no `Range:` header. The `.incomplete` filename is *only* used to mark the file as "not yet finalized for the cache" — it is not consulted as a resume source.

Python `huggingface_hub` handles this in `src/huggingface_hub/file_download.py:1828` (`with incomplete_path.open("ab") as f: resume_size = f.tell()`) and `:362` (`headers["Range"] = ...`), with mid-stream retry on transient errors at `:419-446`. The Rust crate currently has neither cross-process nor in-flight resume.

**Fix shape.**

1. `stream_response_to_file_with_progress` (line 899) currently takes `dest: &Path` and opens the file itself. Refactor to take `file: &mut std::fs::File` so the caller controls open mode (and so the helper can write into a partially-filled file). Pass `initial_offset: u64` so progress events report the correct cumulative position. Return `(u64, HFResult<()>)` where the `u64` is "bytes written this call" so the caller can decide whether the chunk loop made progress.
2. Update both call sites:
   - `download_file_to_local_dir` (line 246): open with `File::create(&dest_path)` (current behavior preserved – `local_dir` has no `.incomplete` convention).
   - `download_file_to_cache_network` (line 481): open `.incomplete` with `OpenOptions::new().create(true).append(true)`. Loop with a retry budget: read `file.metadata()?.len()` as `resume_size`, add `Range: bytes=<resume_size>-` when non-zero, send GET. If the server returns 200 instead of 206 (Range header ignored, e.g. behind CloudFront with content-encoding), `set_len(0)` + `seek(0)` and re-stream. Call the helper; on transient mid-stream error, decrement the retry budget (or reset it if the call made any progress), sleep, and re-enter the loop with the new resume offset. Once the helper returns `Ok(())`, drop the handle, `rename(.incomplete → blob)`, finalize.
3. Skip 416 handling for v1. If a `.incomplete` file is larger than the upstream file (server-side change, corrupted incomplete), the request returns 416 and the error bubbles up. Caller can retry with `force_download(true)` to clear `.incomplete` and start fresh. This matches Python's behavior. Add 416 handling as a follow-up only if real users hit it.

The mid-stream retry budget mirrors Python's `_nb_retries = 5` with reset-on-progress: a connection that drops every 30 seconds but successfully delivers a few MB before each drop will eventually complete; a connection that produces no bytes will give up after 5 attempts.

**Why upstream should want this.** Mirrors `huggingface_hub` (Python) behavior 1:1, which is the reference implementation. Resumable downloads are a documented feature of `huggingface_hub` and an expected one of any Hub client; users of the `hf-hub` crate today silently lose progress on every interruption. The patch is contained to `download.rs` and strictly additive at the public surface (the builder shape doesn't change). The internal helper signature does change, but it is `pub(super)`-scoped (no API impact).

**PR title and description sketch.**

> **Resume cached file downloads from `.incomplete`**
>
> Today `download_file` writes to `<blob>.incomplete` via `File::create`,
> which truncates the file each call. A download interrupted by a network
> drop or process exit therefore restarts from byte 0 on retry, which is
> impractical for multi-GB model files on flaky connections.
>
> This PR makes the cached download path resumable, mirroring the behavior
> of `huggingface_hub`'s Python client (`file_download.py::http_get`):
>
> - `.incomplete` is opened in append mode; existing bytes are kept.
> - `Range: bytes=<existing-size>-` is sent when resuming.
> - If the server ignores the Range header (returns 200 instead of 206),
>   the file is truncated and the download proceeds fresh.
> - Mid-stream transient errors (connect, timeout) trigger an internal
>   retry that reissues the GET with an updated Range header. Up to 5
>   retries, counter resets on each successful chunk.
> - Final size is validated against `Content-Length` / `X-Linked-Size`.
>
> `download_file` to `local_dir` is unchanged (no `.incomplete` convention
> there). Xet downloads are unchanged (the xet-core stream has its own
> resume hook). Snapshot downloads benefit automatically since each
> per-file download routes through `download_file_inner`.
>
> The helper `stream_response_to_file_with_progress` now takes a
> caller-opened `&mut File` and an `initial_offset: u64`, returning
> `(bytes_written, Result<()>)`. Both call sites are updated.

**Upstream PR status.** Pending – to be filed by the user.

### 5. Snapshot `Start` cascade

**Symptom.** `snapshot_download` emits its outer aggregate `DownloadEvent::Start { total_files, total_bytes }`, then dispatches per-file work through `download_file_inner`. Each non-xet file's `download_file_inner` path itself emits `Start { total_files: 1, total_bytes: file_size }` from `download_file_to_local_dir` and `download_file_to_cache_network`. A consumer binding a progress bar's total to the most recent `Start.total_bytes` — the documented way to learn totals upfront — sees the bar reset for every small non-xet file in the snapshot.

**Root cause.** The progress contract in `hf-hub/src/progress.rs` states one `Start → Progress → … → Complete` per operation. The snapshot path emits `1 + N_non_xet`. `download_file_inner` is also the implementation behind the public single-file `download_file` API, where the per-file `Start` is correct; the bug is the leakage when the same inner function is reused by the snapshot orchestrator.

Python `huggingface_hub` has the structurally identical shape and solves it at the analogous layer: `_snapshot_download.py:402-428` defines `_AggregatedTqdm`, a shim that intercepts each per-file tqdm's construction and folds its `total` into the parent bar instead of letting it reset. `hf-hub`'s `snapshot_download_impl` has no equivalent intercept.

**Fix shape.** Inside `snapshot_download_impl`, wrap `params.progress` in a small `ProgressHandler` decorator (`SnapshotPerFileFilter`) before dispatching per-file work. The decorator drops `DownloadEvent::Start` and forwards every other event unchanged. The wrapped progress is what `build_download_params` receives in both branches (local-dir and cache mode); the snapshot-level aggregate `Start` continues to emit via the unwrapped `params.progress`. `download_file_inner`, `DownloadFileParams`, and `build_download_params` are untouched – the orchestration concern stays in the orchestrator.

After this change, `snapshot_download` emits exactly one `Start` per operation. Per-file lifecycle continues to flow through `DownloadEvent::Progress { files: [...] }`, the documented per-file channel. Standalone `download_file` is byte-identical to before.

**Why upstream should want this.** Mirrors Python's `_AggregatedTqdm` behavior – the snapshot orchestrator owning the lifecycle policy is the documented pattern. Tiny patch (one private decorator, four lines wired into the existing branches), additive only.

**PR title and description sketch.**

> **Collapse snapshot Start cascade to a single event per operation**
>
> `hf-hub/src/progress.rs` documents one `Start` per download operation.
> `snapshot_download_impl` violates this: it emits an aggregate `Start`,
> then dispatches per-file work through `download_file_inner`, where
> each non-xet file emits its own `Start` (`download_file_to_local_dir`
> and `download_file_to_cache_network`). A consumer binding a progress
> bar's total to `Start.total_bytes` – the documented way to learn
> totals upfront – sees the bar reset for every small non-xet file in
> a snapshot download.
>
> Python `huggingface_hub` solved the same shape at the analogous
> layer: `_snapshot_download.py:402-428` defines `_AggregatedTqdm`, a
> wrapper at the snapshot orchestrator that intercepts each per-file
> tqdm and folds its `total` into the parent bar. `hf_hub_download`
> itself is unchanged; the snapshot layer owns the lifecycle policy.
>
> This PR follows the same structure: a small `ProgressHandler`
> decorator (`SnapshotPerFileFilter`) is installed in
> `snapshot_download_impl` and wraps `params.progress` before per-file
> fan-out. The decorator drops `DownloadEvent::Start` and forwards
> every other event unchanged. `download_file_inner`,
> `DownloadFileParams`, and `build_download_params` are untouched – the
> orchestration concern lives where the orchestration lives. Per-file
> lifecycle continues to flow through
> `DownloadEvent::Progress { files: [...] }`.
>
> Standalone `download_file` is byte-identical to before.
> `snapshot_download` now emits exactly one `Start` per operation, as
> the docs say.

**Upstream PR status.** Pending – to be filed by the user.

### 6. Transfer-byte channel on `DownloadEvent::AggregateProgress`

**Symptom.** Xet downloads emit `DownloadEvent::AggregateProgress` events roughly every 100 ms, but `bytes_completed` only changes at xorb-write boundaries. For multi-MB xorbs on a residential connection that lands at ~10–30 second intervals: the bar holds, then jumps a chunk's worth at once.

**Root cause.** `hf-hub/src/xet.rs::spawn_download_progress_poller` polls `group.progress()`, which returns a `GroupProgressReport` (`xet_data/src/progress_tracking/progress_types.rs`) carrying two parallel counters:

- `total_bytes_completed` – bytes flushed to disk by `SequentialWriter::run` at xorb-completion boundaries. Naturally chunky.
- `total_transfer_bytes_completed` – network bytes received from CAS, incremented chunk-by-chunk by `report_transfer_progress` in `xet_data/src/file_reconstruction/reconstruction_terms/xorb_block.rs:144-151`. Smooth.

The poller emits only the disk-write side. The network-side fields are read on the stack and discarded on the next line. `UploadEvent::Progress` in the same module already carries both channels; the download `AggregateProgress` variant is asymmetric.

Python `huggingface_hub`'s default `xet_get` path uses `hf_xet.download_files`'s 1-arg `progress_updater`, which is also fed only the disk-write counter. Python's 2-arg form – `progress_updater(total_update, item_updates)` – exposes both channels via `PyTotalProgressUpdate`. The Rust crate has no equivalent of the 2-arg form because the trait-level event hides the smoother counter.

**Fix shape.** Extend `DownloadEvent::AggregateProgress` to mirror `UploadEvent::Progress`'s two-channel split with three new fields: `transfer_bytes_completed`, `transfer_bytes`, `transfer_bytes_per_sec`. Populate them in `spawn_download_progress_poller` from the `GroupProgressReport` value already in scope.

Technically a breaking change under strict Rust semver: exhaustive pattern matches on `AggregateProgress { bytes_completed, total_bytes, bytes_per_sec }` without `..` stop compiling. In-tree consumers (`hfrs/src/progress.rs`, `examples/progress.rs`) already use `..` and are unaffected. Migration for external callers is mechanical: add the new fields, or add `..`. No `#[non_exhaustive]` annotation – the existing progress types don't use it, and adding it here would create a new asymmetry with `UploadEvent::Progress` (the variant we're claiming to mirror).

**Why upstream should want this.** Restores the symmetry between `UploadEvent::Progress` and `DownloadEvent::AggregateProgress`, both of which read from a `*ProgressReport` with two parallel counters. Surfaces a useful smoother UI driver that the trait boundary previously hid. The data is already on the stack at the emission site; the patch is field-extension only.

**PR title and description sketch.**

> **Expose transfer-byte channel on `DownloadEvent::AggregateProgress`**
>
> `hf-hub/src/xet.rs::spawn_download_progress_poller` reads
> `xet_data::progress_tracking::GroupProgressReport`, which carries two
> parallel byte counters: `total_bytes_completed` (bytes flushed to
> disk at xorb-write boundaries – naturally chunky) and
> `total_transfer_bytes_completed` (network bytes received from CAS,
> incremented chunk-by-chunk – smooth). The current
> `DownloadEvent::AggregateProgress` variant only carries the
> disk-write side; the transfer side is read on the stack and
> discarded.
>
> Python `hf_xet`'s 2-arg `progress_updater(total_update, item_updates)`
> form exposes both channels via `PyTotalProgressUpdate`; the 1-arg
> form used by `huggingface_hub.xet_get` exposes only the disk-write
> counter, matching what hf-hub emits today. The smoother signal
> exists and is the right driver for a UI bar; it just isn't on
> hf-hub's side of the trait boundary.
>
> This PR extends `AggregateProgress` with three new fields –
> `transfer_bytes_completed`, `transfer_bytes`,
> `transfer_bytes_per_sec` – mirroring the two-channel split that
> already exists on `UploadEvent::Progress`.
>
> Breaking change. Pattern matches on the variant without `..` stop
> compiling. Migration is mechanical: add the new fields, or add `..`.
> In-tree consumers already use `..` and are unaffected. No
> `#[non_exhaustive]` – the existing progress types don't carry it,
> and adding it only on the variant we're touching would create a new
> asymmetry with the upload side.

**Upstream PR status.** Pending – to be filed by the user.

### 7. Public `GlobMatcher` type

**Symptom.** `hf-hub` already uses `globset` internally to compile and apply `allow_patterns` / `ignore_patterns` filters during `snapshot_download` (see `matches_any_glob` in `hf-hub/src/repository/files.rs:280-287`). Downstream consumers that want to reuse the same glob semantics for non-download paths — for example, filtering files inside a previously cached snapshot before reading them off disk — have to re-implement `globset` semantics themselves. The Swift wrapper in this project previously shipped a hand-rolled regex translator (`Sources/HFAPI/Cache/GlobMatcher.swift`) to do exactly that. The Swift implementation can drift from the Rust crate on edge cases such as how `**` is interpreted outside a full path component, or whether a trailing `/` triggers directory-shorthand expansion.

**Fix shape.** Add a small `pub struct GlobMatcher` in `hf-hub/src/repository/files.rs` next to the existing internal `matches_any_glob`. The new type wraps `globset::GlobMatcher` compiled via `GlobBuilder::new(...).literal_separator(true).build()?` so `*` and `?` do not cross path segment boundaries (gitignore-style segmentation, which matches what's natural for repo-relative path matching). The constructor also adds a Hugging Face / `huggingface_hub` convention: a trailing `/` on a pattern is normalized to append `*`, so `"data/"` is treated as `"data/*"`. Re-exported at `hf_hub::repository::GlobMatcher`.

The existing `matches_any_glob` is left untouched — its default `globset::Glob::new(p).compile_matcher()` semantics (where `*` does cross `/`) are preserved so the behavior of `snapshot_download`'s `allow_patterns` / `ignore_patterns` filters is unchanged.

Unit tests cover the `literal_separator(true)` behavior, `**` recursion (including the canonical globset rule where `**` outside a full path component degrades to a single `*`), the question-mark single-char rule, the trailing-slash shorthand, and malformed pattern rejection.

**Why upstream should want this.** Downstream consumers already depend on the same `globset` semantics that `snapshot_download` uses internally; right now there is no public way to construct or apply a matcher with the same shape. Promoting it costs almost nothing — it's a wrapper around an existing dependency — and removes a reimplementation hazard for anyone building higher-level cache or filter UIs.

**PR title and description sketch.**

> **Expose `GlobMatcher` as a public type**
>
> `hf-hub` already uses `globset` internally to filter
> `allow_patterns`/`ignore_patterns` during snapshot_download (see
> `matches_any_glob` in `repository/files.rs`). Downstream consumers
> that want to apply the same matching to non-download paths — for
> example, filtering files in a previously cached snapshot — have to
> re-implement globset semantics themselves, which silently drifts on
> edge cases like trailing-slash directories or `**` placement.
>
> This PR adds a public `GlobMatcher` type wrapping
> `globset::GlobMatcher` with two defaults aimed at Hub-style path
> matching:
>
> - `literal_separator(true)`. `*` and `?` do not cross `/`
>   boundaries. Cross-segment matches require `**`, which must be a
>   full path component.
> - Trailing-`/` shorthand. A pattern ending in `/` is normalized to
>   append `*`, so `"data/"` is treated as `"data/*"`. This mirrors a
>   common Hugging Face / huggingface_hub convention.
>
> Re-exported at `hf_hub::repository::GlobMatcher`. The internal
> `matches_any_glob` is untouched — its behavior (which uses default
> globset semantics, where `*` does cross `/`) is preserved exactly so
> existing `snapshot_download` filter matching is not disturbed.

**Upstream PR status.** Pending – to be filed by the user.

### 8. Public repository-ID segment validation

**Symptom.** `hf-hub` accepts any string for `(owner, name)` in its repo handles (`HFClient::model`, `::dataset`, etc.). Downstream consumers that want to surface a typed error before issuing a request — for example, a Swift `RepositoryID` value type that throws on construction — have to port the validation rules in their own language. `huggingface_hub` enforces these rules in `utils/_validators.py` (`REPO_ID_REGEX` plus a small set of additional checks); without a Rust mirror, every consumer reimplementing the rules risks drifting from the canonical set.

**Fix shape.** Add `pub fn validate_repo_id_segment(segment: &str, role: SegmentRole) -> Result<(), RepoIdValidationError>` in a new module `hf-hub/src/repository/repo_id.rs`. `SegmentRole` is a small `enum { Owner, Name }` that affects only the `.git` suffix rule (name-only). `RepoIdValidationError` is a `thiserror`-derived enum with one variant per failure mode (`Empty`, `TooLong`, `InvalidCharacter`, `LeadingOrTrailingDot`, `LeadingOrTrailingHyphen`, `DoubleHyphen`, `DoubleDot`, `GitSuffix`).

The validator operates on a single segment at a time because callers typically have the two components separately (or split them once at parse time). The rules mirror the ones implied by `huggingface_hub`'s `REPO_ID_REGEX` plus the auxiliary `validate_repo_id` checks: 1–96 characters drawn from `[A-Za-z0-9._-]`, must not start or end with `.` or `-`, must not contain `--` or `..`, and the `name` segment must not end with `.git`.

Unit tests cover each rule, the 96-character boundary, the role-scoped `.git` suffix rule, and the format of the rendered error messages.

**Why upstream should want this.** The Hub itself enforces these rules; consumers that want to fail fast (with a typed error rather than a 404 from the API) currently have to reimplement them. This PR adds a small, additive surface that mirrors the canonical Python rules. No existing API changes — `HFClient::model`/`::dataset` still accept any string; the validator is opt-in for consumers that want to call it before constructing a handle.

**PR title and description sketch.**

> **Expose repository ID segment validation**
>
> `hf-hub` accepts any string for `(owner, name)` in repo handles
> (`HFClient::model`, `::dataset`, etc. — no validation). Downstream
> consumers that want to mirror the Hub's own naming rules — for
> example, to surface a typed RepositoryID error before issuing a
> request that would 404 — have to re-implement the rules in their own
> language, where they drift over time.
>
> This PR adds a public `validate_repo_id_segment(segment, role)`
> function plus `SegmentRole { Owner, Name }` and a typed
> `RepoIdValidationError` enum with one variant per failure mode. The
> rules mirror `huggingface_hub`'s `validate_repo_id`
> (`utils/_validators.py`): 1–96 characters from `[A-Za-z0-9._-]`,
> must not start or end with `.` or `-`, must not contain `--` or
> `..`, and `name` must not end with `.git`.
>
> The validator works on one segment at a time because the canonical
> two-segment form `owner/name` is typically split before storage in
> handle types. Strictly additive — `HFClient::model`/`::dataset`
> still accept any string; the validator is opt-in.

**Upstream PR status.** Pending – to be filed by the user.

### 9. Cache revision deletion (`HFCacheInfo::delete_revisions`, `DeleteCacheStrategy`)

**Symptom.** `hf-hub` ships `HFClient::scan_cache` for inspecting the local cache (`hf-hub/src/cache/mod.rs:121`) but no deletion API. `huggingface_hub` (Python) exposes `HFCacheInfo.delete_revisions(*hashes) -> DeleteCacheStrategy` with a dry-run/execute split (`utils/_cache_manager.py:365`), which exists so a UI can show the estimated freed size and per-path detail before the user commits to the deletion. Downstream consumers that want the same UX have to port the algorithm themselves and risk drifting from the cache-layout invariants the Hub crate already enforces.

**Fix shape.** Add a new module `hf-hub/src/cache/deletion.rs` with:

```rust
pub struct DeleteCacheStrategy { /* expected_freed_size, blobs, refs, repos, snapshots, locks, missing_revisions */ }
pub struct ExecuteResult { pub failures: Vec<Failure> }
pub struct Failure { pub path: PathBuf, pub kind: PathKind, pub error: std::io::Error }
pub enum PathKind { Repo, Snapshot, Ref, Blob, Locks }

impl HFCacheInfo {
    pub fn delete_revisions(&self, commit_hashes: &[String]) -> DeleteCacheStrategy { /* ... */ }
}

impl DeleteCacheStrategy {
    pub fn execute(&self) -> std::io::Result<ExecuteResult> { /* ... */ }
}
```

Key algorithm invariants (matching Python `_cache_manager.py`):

1. A target hash is attributed to the first repo it appears under (rare cross-repo SHA collisions notwithstanding).
2. If every revision of a repo is targeted, the whole repo dir is queued for deletion and `.locks/<repo_folder>/` is added — but only if it exists on disk, so caches that never ran a download don't produce spurious `NotFound` failures.
3. Per-revision deletion only removes blobs that aren't still referenced by surviving revisions in the same repo.
4. A blob referenced by multiple deleted revisions in one repo is counted once in `expected_freed_size`.
5. `execute` runs in the order `repos → snapshots → refs → blobs → locks` so a half-finished deletion leaves extra blobs, not dangling snapshot pointers.
6. Per-path `NotFound` / `PermissionDenied` outcomes go to `failures` (mirroring Python `_try_delete_path`); other I/O errors propagate as `Err`.

Re-exported at `hf_hub::cache::{DeleteCacheStrategy, ExecuteResult, Failure, PathKind}` and at the module root.

Unit tests cover the shared-blob-survives case, the whole-repo wipe case, missing-revision reporting, the actual filesystem effect of `execute`, and the idempotent re-execution path (every removed path becomes a `NotFound` entry in `failures`).

**Why upstream should want this.** The Hub crate already owns the cache-layout authority; downstream consumers that want a typed deletion API today have to either re-derive the algorithm in their host language or shell out to the Python CLI. The patch is contained (one new module, two `pub` methods on the existing `HFCacheInfo` type) and strictly additive — no existing API changes.

**PR title and description sketch.**

> **Add `delete_revisions` and `DeleteCacheStrategy`**
>
> `hf-hub` exposes `HFClient::scan_cache` for cache inspection but no
> deletion API. `huggingface_hub` (Python) ships
> `HFCacheInfo.delete_revisions(*hashes) -> DeleteCacheStrategy` with a
> dry-run/execute split so a UI can show the estimated freed size and
> per-path detail before the user commits to the deletion. Downstream
> consumers that want the same UX have to port the algorithm
> themselves and risk drifting from the cache-layout invariants the
> Hub crate already enforces.
>
> This PR mirrors the Python shape:
>
> - `HFCacheInfo::delete_revisions(commit_hashes) -> DeleteCacheStrategy`
>   builds a plan. Hashes not found in the cache are reported in
>   `missing_revisions` rather than failing.
> - `DeleteCacheStrategy::execute() -> io::Result<ExecuteResult>`
>   applies the plan in the order `repos → snapshots → refs → blobs →
>   locks`. Per-path `NotFound`/`PermissionDenied` outcomes land in
>   `failures`; other I/O errors propagate.
>
> Strictly additive — no existing API changes.

**Upstream PR status.** Pending – to be filed by the user.

### 10. Co-locate the Xet cache with an explicit hub cache directory

**Symptom.** `hf-hub` lets a consumer pin the hub cache location via `HFClientBuilder::cache_dir`, but the Xet cache root (chunk cache, shard cache, staging) is resolved independently, entirely inside `xet-core`, from the `HF_XET_CACHE` → `HF_HOME` → `XDG_CACHE_HOME` environment chain (falling back to `~/.cache/huggingface/xet`). Setting `cache_dir` therefore relocates the hub cache but leaves the Xet cache at its environment-derived default. On a sandboxed host — an iOS app, whose only writable area is its container — the consumer points `cache_dir` at the app-group container, yet Xet transfers still target `~/.cache/huggingface/xet`, which resolves outside the container. `xet-core`'s eager `create_dir_all` of that path in `TranslatorConfig::new` fails with `EPERM`, surfacing as `Xet batchDownload failed: I/O error: I/O error: Operation not permitted (os error 1)`.

**Fix shape.** When `cache_dir` is set explicitly, derive the Xet cache root as its sibling `xet/` directory (`<root>/hub` → `<root>/xet`) and pass it to the `XetSession` via `XetConfig`'s `data.cache_root` field (added in the companion xet-core patch). This mirrors xet-core's own default layout, where `$HF_HOME/hub` and `$HF_HOME/xet` are siblings — the patch simply preserves that relationship when the hub side is relocated. `HFClientBuilder::build` records the derived path on `HFClientInner.xet_cache_dir`; `xet_session()` builds `XetConfig::new()`, sets `data.cache_root` from it, and constructs the session with `XetSessionBuilder::new_with_config` instead of `::new()`. Only absolute `cache_dir` values with a real parent are used; a relative or root-level path — and a `cache_dir` left to its default — fall back to `None`, so xet-core's environment-based resolution and `HF_XET_CACHE` precedence are unchanged.

**Why upstream should want this.** Strictly additive — no public API changes; `cache_dir` simply gains a documented side effect that restores an invariant xet-core already assumes by default. Without it, every `hf-hub` consumer that relocates the hub cache silently desynchronizes the two caches, and any sandboxed consumer cannot use Xet at all. Depends on the companion xet-core patch (`Add data.cache_root to override the Xet cache root`); the two are submittable as a pair.

**PR title and description sketch.**

> **Co-locate the Xet cache with an explicit hub cache_dir**
>
> When `HFClientBuilder::cache_dir` is set explicitly, derive the Xet
> cache root as its sibling `xet/` directory (`<root>/hub` →
> `<root>/xet`) and pass it to the XetSession via `XetConfig`'s
> `data.cache_root`. This mirrors xet-core's own `$HF_HOME/hub` +
> `$HF_HOME/xet` layout and keeps the two caches co-located on
> sandboxed hosts where xet-core's environment-derived default would
> land outside the writable container.
>
> Only absolute `cache_dir` values with a real parent are used;
> otherwise, and when `cache_dir` is left to default, the Xet cache
> root falls back to xet-core's environment-based resolution.
>
> Strictly additive — no existing API changes.

**Upstream PR status.** Pending – to be filed by the user (with the companion xet-core patch).

## Active patches on `xet-core`

The fork lives at `https://github.com/DePasqualeOrg/xet-core` (origin) with `https://github.com/huggingface/xet-core` as `upstream`. Our cumulative branch is `swift-hf-api-patches`, wired through `rust/Cargo.toml`'s `[patch.crates-io]` block (the `hf-xet`, `xet-client`, `xet-runtime`, `xet-data`, and `xet-core-structures` crates all point at the same fork rev). Each commit on that branch corresponds to one upstream PR.

### 1. TLS passthrough for the xet client

**Symptom.** With `hf-hub` selecting a TLS backend per platform (native-tls on Apple, rustls-tls on Linux — see hf-hub patch #2), `hf-xet`'s transitive default `rustls-tls` re-activates and unifies in the dependency graph, so the feature selection does not take effect end to end.

**Fix shape.** Add a `rustls-tls` passthrough feature and disable the transitive xet-client TLS defaults so the backend chosen by `hf-hub` propagates cleanly.

**PR title.** `Add rustls-tls passthrough and disable transitive xet-client defaults`

**Upstream PR status.** Pending – to be filed by the user.

### 2. Configurable Xet cache root (`data.cache_root`)

**Symptom.** The Xet cache root (chunk cache, shard cache, staging) is resolved in `xet_runtime::core::xet_cache_root()` purely from the `HF_XET_CACHE` → `HF_HOME` → `XDG_CACHE_HOME` environment chain, with `~/.cache/huggingface/xet` as the fallback. There is no programmatic override: `XetConfig` — the only input to `XetSessionBuilder::new_with_config` — has no field for it. A host that needs the cache somewhere specific (a sandboxed app whose environment-derived default is not writable) cannot express that without mutating process-wide environment variables, which is racy across clients and `unsafe` under Rust 2024.

**Fix shape.** Add a `cache_root: String` field to the `data` config group (`xet_runtime/src/config/groups/data.rs`), empty by default. In `xet_data/src/processing/configurations.rs`, `TranslatorConfig::new` resolves the root through a new `resolve_cache_root(config)` helper: when `data.cache_root` is non-empty it is used (run through the same `TemplatedPathBuf` expansion as the environment paths), otherwise it falls back to `xet_cache_root()`. Both the endpoint-cache branch (`compute_cache_path`) and the `memory://` branch go through the helper. Empty (the default) reproduces the existing environment-based behavior exactly — no regression for any current caller.

**Why upstream should want this.** Strictly additive — a new optional config field, default-empty, with the established env-override codepath (`HF_XET_DATA_CACHE_ROOT`) coming for free from the config-group macro. It gives embedders a first-class, per-session way to place the cache without process-global environment mutation. `hf-hub` is the first consumer (see hf-hub patch #10).

**PR title and description sketch.**

> **Add data.cache_root to override the Xet cache root**
>
> The Xet cache root (chunk cache, shard cache, staging) was resolved
> solely from the HF_XET_CACHE / HF_HOME / XDG_CACHE_HOME environment
> chain, with no programmatic override. On sandboxed hosts (e.g. iOS
> apps) the environment-derived default lands outside the writable
> container, so Xet transfers fail with EPERM.
>
> Add a `data.cache_root` config field; when non-empty it takes
> precedence over the environment chain (and is run through the same
> template expansion). `TranslatorConfig` resolves the root through
> the new `resolve_cache_root` helper instead of calling
> `xet_cache_root()` directly. Empty (the default) preserves the
> existing environment-based behavior exactly.

**Upstream PR status.** Pending – to be filed by the user.

### 3. Finalize download progress totals together

**Symptom.** A download's progress bar jumps to ~99% early and sits there until the transfer actually finishes.

**Root cause.** `FileDownloadSession::setup_reconstructor` (`xet_data/src/processing/file_download_session.rs`) pre-finalized the logical-byte progress total up front — `update_item_size(size, is_final = true)` — for full-file downloads with a known size and for fully-bounded ranges. The network transfer total, however, is discovered incrementally by `ReconstructionTermManager` as it fetches reconstruction term blocks (`update_transfer_size` per block). The two aggregate channels (`GroupProgressReport::total_bytes` vs `total_transfer_bytes`) therefore finalized on different timelines. A consumer that scales the smooth transfer ratio (`transfer_completed / transfer_total`) against the already-final logical total overshoots: once the first discovered block's xorbs finish transferring, the ratio briefly hits ~1.0, the estimate spikes to the full logical size, and a monotonic progress bar pins near 100% for the rest of the download.

**Fix shape.** Drop the up-front `update_item_size` calls in `setup_reconstructor` (the 4-arm `match` on `range` collapses to "set the byte range if present"). `ReconstructionTermManager` becomes the single source of truth for the logical total, discovering and finalizing it incrementally — exactly as it already does for open-ended ranges — so it stays in lockstep with the transfer total at every tick. The caller-provided file size is still used for the post-reconstruction `SizeMismatch` check in `download_file_with_id`.

**Why upstream should want this.** Removes a special case rather than adding one, and unifies the known-size path with the open-ended-range path that already worked correctly. No public API change; the only observable difference is that the logical progress total now ramps up during term discovery instead of being full immediately — which is what any consumer blending it with the transfer total needs.

**PR title and description sketch.**

> **Finalize download progress totals together**
>
> `setup_reconstructor` pre-finalized the logical-byte progress total
> up front for full-file and bounded-range downloads, while the network
> transfer total is discovered incrementally by
> `ReconstructionTermManager`. A consumer scaling the transfer ratio
> against the already-final logical total overshoots — once the first
> discovered block's xorbs finish transferring, the ratio briefly hits
> ~1.0 and the progress bar pins near 100% for the rest of the
> download.
>
> Drop the up-front finalization and let the manager discover and
> finalize both aggregate totals together. The caller-provided file
> size is still used for the post-reconstruction `SizeMismatch` check.

**Upstream PR status.** Pending – to be filed by the user.

## Active patches on `uniffi-rs`

These are wired through `rust/Cargo.toml`'s `[patch.crates-io]` block. See the comment block in that file for context. The fork branch's commit SHA is pinned at `e3e998025`, which includes the BOM-strip fix and the Swift FFI visibility options used by `rust/uniffi.toml`. When the needed Swift bindgen fixes land upstream, we drop the patch and bump the upstream `uniffi` dep.

## Refresh protocol

When an upstream PR for one of our patches merges:

1. Fetch upstream into the fork: `cd /Users/anthony/files/projects/forked/hf-hub && git fetch upstream main`
2. Rebase the patches branch and drop the merged commit:
   `git rebase --onto upstream/main <merged-commit>^ <patches-branch>`
3. Push the rebased branch: `git push origin <patches-branch> --force-with-lease`
4. Update `swift-hf-api/rust/Cargo.toml` to the new tip SHA.
5. Run `./scripts/rust/regenerate-wrapper.sh && ./scripts/rust/build/build-rust-apple-slices.sh && ./scripts/rust/build/assemble-artifactbundle.sh 0.0.0-dev` and `swift test` (rust-on + rust-off) to confirm nothing regresses.
6. Update this doc: move the merged entry to a "Historical" section with the merge SHA / version it shipped in.

Force-push to a fork branch is acceptable here – the branch is owned by this project and no one else consumes it.

## When to add a new patch

A patch belongs on the fork only if **all** of these hold:

- The fix is small (under ~50 lines) and behavior-preserving.
- We've identified the root cause and the fix has the shape of a credible upstream PR.
- The alternative (a workaround in our crate) costs us a real feature or performance characteristic.

If the alternative is "we add a few lines of glue" and that's fine, glue is the right answer. The fork should never be the place where we go to avoid understanding a problem.

## Watching for upstream additions

Some changes upstream would let us simplify or remove parts of our facade without needing a fork patch. Track them here so a future `hf-hub` bump triggers the simplification.

### List-endpoint filter coverage on `list_models` / `list_datasets`

**Watch for.** Upstream builder methods accepting the per-Hub filter parameters that `huggingface_hub` (Python) exposes but `hf-hub` does not yet – most notably `language`, `task_categories`, `task_ids`, `multilinguality`, `size_categories`, `language_creators`, `benchmark`, `gated`, `inference`, and (for `list_datasets`) `tag` array form.

**Why we care.** The Swift wrapper's `HFListModelsBuilder` and `HFListDatasetsBuilder` faithfully expose what `hf-hub` ships: `search`, `author`, `filter` (single tag), `sort`, `pipeline_tag`, `limit`, plus a few flags. Pre-migration consumers (using the previous Swift implementation) had typed access to the broader filter set. Today those callers must either pre-filter in code on a wider result set, or stuff multiple terms into the single `filter` field as Hub-style tag tokens (`"language:en"`, `"license:apache-2.0"`).

**Action when it lands.** Add matching `HFListModelsBuilder`/`HFListDatasetsBuilder` methods that pass the new fields straight through `HFListModelsParamsDto`/`HFListDatasetsParamsDto` to `hf-hub`. Update the release notes accordingly.

### `create_branch` `overwrite` and `empty_branch` parameters

**Watch for.** Upstream support for the `overwrite` and `empty_branch` flags on `HFRepository::create_branch`. The Hub API documents both; `hf-hub` currently only forwards `revision` (as `startingPoint`).

**Why we care.** A workflow that creates a fresh branch with no parent commit (`empty_branch: true`) or that replaces an existing branch in-place (`overwrite: true`) is reachable from the Hub API but not from the Swift wrapper. The pre-migration API exposed both.

**Action when it lands.** Add matching parameters to ``RepositoryProtocol/createBranch(_:revision:)``; thread them through the FFI to the upstream builder.

### `update_settings` xet-enabled field

**Watch for.** An `xet_enabled: Option<bool>` builder method on `HFRepository::update_settings`. The Hub API supports flipping Xet on a repo via `PUT /api/<kind>/<repo_id>/settings` with `"xetEnabled": true`; `hf-hub` currently doesn't surface it.

**Why we care.** Pre-migration Swift consumers could opt a repo into Xet via the wrapper. Today the only way is to do it through the Hub web UI or a hand-crafted HTTP call.

**Action when it lands.** Add `xetEnabled` to ``RepositoryProtocol/updateSettings(private:gated:description:discussionsDisabled:gatedNotifications:)`` and pass through.

### Dedicated `list_parquet_files` and `tags` endpoints

**Watch for.** Methods on `HFClient` (or `HFRepository<RepoTypeDataset>`) wrapping `GET /api/datasets/<repo_id>/parquet/<config>/<split>/<file>` and `GET /api/models-tags-by-type` / `GET /api/datasets-tags-by-type`. The Hub serves both today; `hf-hub` doesn't expose them.

**Why we care.** Parquet enumeration is a useful dataset-discovery primitive, and tag-by-type lookups are how a generic UI can populate a search-filter dropdown. Both were available in the pre-migration Swift API.

**Action when it lands.** Add the corresponding builders to ``DatasetRepository`` / ``HFClient`` and surface DTOs through the FFI.

### `getOAuthUserInfo` endpoint

**Watch for.** A method on `HFClient` (or a small standalone helper in `hf_hub::users`) that hits `GET /oauth/userinfo` and returns the typed user-info payload (claims like `name`, `picture`, `email_verified`, `orgs`).

**Why we care.** `whoami` returns the bearer-bound user identity, but `/oauth/userinfo` returns the OIDC-standard claim set that an OAuth-authenticated app needs to render a profile UI. The pre-migration Swift API exposed this.

**Action when it lands.** Add a matching method on `HFClient` and an `OAuthUserInfo` DTO. Until then, OAuth-authenticated consumers can call the endpoint manually via `URLSession`.

### `download_file` transport selector (force LFS vs. force Xet vs. automatic)

**Watch for.** A builder method on `HFRepository::download_file` (and the snapshot equivalent) that lets the caller force the transport path: LFS-only, Xet-only, or the current automatic selection.

**Why we care.** The pre-migration Swift API exposed this for debugging and for forcing a specific path when one was misbehaving in production. Today the Rust crate auto-picks based on which header the Hub returns, with no override.

**Action when it lands.** Thread the new builder argument through `HFRepositoryFfi::download_file*` and surface as an enum on the Swift download builders.

### UniFFI Swift bindgen `nonisolated(unsafe)` on callback vtables

**Watch for.** A `uniffi.toml` flag (or unconditional bindgen template change) that emits `nonisolated(unsafe) static let vtablePtr: UnsafePointer<...>` for callback-trait vtables, instead of the bare `static let` the current Swift bindings produce.

**Why we care.** The generated `HFAPIFFI/Generated/HFAPIFFI.swift` holds one such vtable per `with_foreign` trait (`FfiTokenProvider`, `FfiDownloadProgressHandler`, `FfiUploadProgressHandler`, `FfiByteChunkHandler`). Swift 6 strict concurrency flags `UnsafePointer` as non-`Sendable` global state, so the generated module fails to compile under Swift 6 mode. We work around this in `Package.swift` by pinning the `HFAPIFFI` target to `swiftLanguageMode(.v5)` – fine for the generated module (consumers never import it), but a long-term smell that blocks Swift 6 adoption across the package surface if a future generated symbol leaks into the public API.

The pointer is allocated once at module load and Rust owns its lifetime, so the memory model is sound; the missing piece is bindgen advertising that to Swift via `nonisolated(unsafe)`.

**Action when it lands.** Drop the `swiftLanguageMode(.v5)` override on the `HFAPIFFI` target in `Package.swift`. Remove the explanatory comment block plus the inline TODO. The wider package already builds under Swift 6 mode; the override is scoped to the generated module only.

### Access-request family on gated repositories

**Watch for.** Methods on `HFClient` (or `HFRepository<T>`) wrapping `POST /api/<kind>/<repo_id>/ask-access`, plus the moderation-side `grantAccess`, `handleAccessRequest`, and `listAccessRequests` endpoints. The Hub serves all of them; `hf-hub` does not currently expose any.

**Why we care.** Pre-migration callers used `requestModelAccess` / `requestDatasetAccess` to programmatically request a gated repository's weights, and the moderation-side endpoints let an org owner approve or list pending requests. Without these, a consumer downloading from a gated repo must redirect the user to the Hub web UI to click "Request access" before any `downloadFile` will succeed — there is no programmatic path. This is the highest-severity public-surface gap in the migration.

**Action when it lands.** Add `requestModelAccess(reason:)` / `requestDatasetAccess(reason:)` on the matching `*Repository` types and `grantAccess(repoID:user:)`, `handleAccessRequest(repoID:user:status:)`, `listAccessRequests(repoID:)` on `HFClient`. Surface the request/response DTOs through the FFI. Document the gated-download UX update in the release notes when shipping.

### Tree-size endpoint

**Watch for.** A method on `HFRepository<T>` wrapping `GET /api/<kind>/<repo_id>/tree-size/<revision>/<path>`. The Hub returns the cumulative size of a subtree in one HEAD-style request; `hf-hub` does not surface it today.

**Why we care.** The current workaround is `listTree(recursive: true, expand: true)` followed by summing `size` across all entries client-side. For repositories with thousands of files this is wasteful — the Hub already computes the aggregate.

**Action when it lands.** Add `treeSize(revision:path:)` on `RepositoryProtocol` returning `UInt64`. Thread the new builder through `HFRepositoryFfi`.

### `createRepository(resourceGroupId:)`

**Watch for.** A `resource_group_id: Option<String>` builder method on `hf_hub::HFClient::create_repository`. The Hub accepts it on the create-repo payload; `hf-hub` currently does not expose it.

**Why we care.** Org-managed repositories use resource groups to scope billing and visibility. Pre-migration callers could create a repo into a specific resource group; today the only way is to set it via the Hub web UI after creation.

**Action when it lands.** Add `resourceGroupID: String? = nil` to `HFClient.createRepository(kind:repoID:private:...)` and pass through `HFClientFfi::create_repository`.

### `info(securityStatus:filesMetadata:)` flags on repository info

**Watch for.** `security_status: Option<bool>` and `files_metadata: Option<bool>` builder methods on `HFRepository::info`. The Hub's `/api/<kind>/<repo_id>` endpoint accepts both as query parameters and returns blob-level security and metadata info when they're set.

**Why we care.** The pre-migration API let callers opt into the heavier response shape on demand. Without these, callers either always pay for the larger payload (if defaulted on) or never see the per-blob security info at all (if defaulted off). The Rust crate currently defaults them off, so the second case applies.

**Action when it lands.** Add `securityStatus: Bool? = nil` and `filesMetadata: Bool? = nil` to `ModelRepository.info(...)` and `DatasetRepository.info(...)`. Thread them through `HFRepositoryFfi::info_model` / `info_dataset`.

### `FileMetadataInfo::is_lfs`

**Watch for.** An `is_lfs: bool` field on `hf_hub::FileMetadataInfo` derived from the `X-Linked-Size` header that the Hub returns on the resolve URL HEAD response. The header is the canonical LFS-pointer signal; the upstream struct exposes `commit_hash`, `etag`, `xet_hash`, `size`, and `location` but does not surface this bit today.

**Why we care.** The pre-migration Swift API exposed `File.isLFS: Bool` on the per-file HEAD response (see `git show main:Sources/HFAPI/Hub/File.swift:20`). Consumers used it to branch their download path or to render an LFS badge in a file browser. Today the same signal is only reachable through `repo.info().siblings[].lfs != nil`, which is a different code path (full repo info, not single-file HEAD) and won't work for files the Hub omits from `siblings` (rare but possible). `xet_hash != nil` is a partial proxy — a file can be LFS-backed without being Xet-backed.

**Action when it lands.** Add `isLFS: Bool` to `FileMetadata` (`Sources/HFAPI/Repository/RepoTreeEntry.swift:100`) and map from the new DTO field. Note the addition in the release notes.

### Raw status character on `GitStatus::Unknown`

**Watch for.** A payload-carrying variant on `hf_hub::repository::GitStatus::Unknown` (e.g., `Unknown(char)`) so the raw single-letter status code from `git diff-tree --raw` is preserved instead of collapsed to a unit variant. Today the `From<char>` impl in `hf-hub/src/repository/diff.rs:114-128` maps `'X'` *and* any unrecognized character to the same `GitStatus::Unknown` — once we hit that case, the original character is lost.

**Why we care.** Every other forward-compat "unknown" case in the Swift wrapper (`XetOperation.other(String)`, `GatedMode.unknown(String)`, `CachedRepoType.other(String)`, `SecurityStatus.other(String)`) carries the raw payload so callers can at least log the unrecognized value. `GitStatus.unknown` is the lone exception. Carrying the raw character through to Swift would let consumers distinguish "saw the documented `X` placeholder" from "git introduced a new status letter we haven't mapped yet".

**Action when it lands.** Add a `String` payload to `GitStatus.unknown` in `Sources/HFAPI/Repository/CommitsAndDiffs.swift`, thread the new DTO field through `GitStatusDTO::Unknown` in `rust/src/core/dto.rs`, regenerate the UniFFI bindings, and update the L7 entry in `docs/0.4.0-review-fifth-pass.md` to closed.

### `createModelTag` / `createDatasetTag` (Hub metadata tags)

**Watch for.** Methods on `HFClient` wrapping `POST /api/<kind>-tag/<repo_id>`. The Hub distinguishes between *git tag refs* (already exposed via `createTag` on the repo type) and *Hub metadata tags* — the latter are taxonomy labels surfaced in the model card UI (e.g., `pytorch`, `text-classification`). `hf-hub` exposes the former but not the latter.

**Why we care.** Pre-migration callers could programmatically tag uploaded repositories with the same taxonomy that `getModelTags()` / `getDatasetTags()` enumerates. Without this, automated upload pipelines either omit metadata tags or scrape the Hub UI to apply them.

**Action when it lands.** Add `createModelTag(repoID:tag:)` and `createDatasetTag(repoID:tag:)` on `HFClient`. Distinct method names from `createTag` (the git-ref variant on repository types) so the two namespaces don't shadow each other in the IDE.

### `HFClient::set_token` (or equivalent in-place token mutator)

**Watch for.** A public method on `HFClient` (or a trait-based hook) that mutates the token attached to an already-built client without requiring a full rebuild. Today `HFClientInner.token` is a private static `Option<String>` (see `src/client.rs`), and the only way to change it is to construct a new `HFClient` via the builder.

**Why we care.** Phase 5 of the Rust migration ships a Swift-side `FFITokenProvider` callback so OAuth token refresh propagates into `HFClient`. Without an upstream setter, our Rust facade rebuilds `hf_hub::HFClient` whenever the provider returns a new token (~50ms TLS reconnect on each rotation). An upstream `set_token` (likely backed by `Mutex` or `ArcSwap`) lets us swap the rebuild path for an in-place mutation – same FFI surface, faster rotation, no client clone churn.

**Action when it lands.** In `rust/src/core/client.rs`, replace the rebuild path inside `HFClientFFI::active_client()` with the upstream setter call. Remove the cached `BuilderConfig` field if `set_token` makes it unnecessary. Update the migration doc's "FFI design – async token provider" section accordingly. The `// TODO: replace rebuild with hf_hub::HFClient::set_token() when upstream exposes it` comment that lands with the bridge implementation marks the swap-out point.

## Layout reference

```
/Users/anthony/files/projects/forked/hf-hub/        ← fork checkout
  ├── (origin)   https://github.com/DePasqualeOrg/hf-hub.git
  ├── (upstream) https://github.com/huggingface/hf-hub.git
  ├── main                  ← tracks upstream/main, pull-only
  └── swift-hf-api-patches  ← cumulative patch branch (see above)

/Users/anthony/files/projects/forked/swift-hf-api/rust/Cargo.toml
  hf-hub = { git = "https://github.com/DePasqualeOrg/hf-hub", rev = "<tip-of-patches-branch>", features = [...] }
  [patch.crates-io]
  uniffi* = { git = "https://github.com/DePasqualeOrg/uniffi-rs.git", rev = "e3e998025..." }
```
