# Download and cache design

Our download/cache subsystem differs from [upstream](https://github.com/huggingface/swift-huggingface) in architecture, not just features. The upstream repo partially adopted features from [PR #21](https://github.com/huggingface/swift-huggingface/pull/21) but kept a different architecture that mixes concerns and introduces bugs. We use PR #21's architecture, which cleanly separates cache management from destination copying.

## Core architectural difference

**Upstream:** `downloadFile` handles both cache storage and destination copying. `downloadSnapshot` passes per-file destination paths into `downloadFile`, which must manage both concerns across every code path (cache hit, blob exists, fresh download, resume, error fallback).

**Ours:** `downloadFile` only manages cache coordination (blob storage, symlinks, locking, resume) and returns the cache path. Copying to a user-provided destination is handled at the `downloadSnapshot` level — the entire snapshot directory is copied once at the end.

This matches Python's `huggingface_hub`, where `hf_hub_download` returns the cache path and `snapshot_download` handles `local_dir` separately.

### Bugs this prevents

The separation structurally prevents two bugs present on upstream's `main` (identified in [PR #42](https://github.com/huggingface/swift-huggingface/pull/42)):

1. **Missing snapshot entry for duplicate blobs.** When two files share a blob (same etag), upstream's blob-exists early return skips creating a snapshot symlink for the second file. Our architecture funnels every code path through `createCacheEntries`, which always creates the symlink.

2. **Double path in destination copy.** Upstream's `downloadSnapshot` constructs per-file destinations, then `downloadFile` appends the repo path again, producing paths like `out/prompts/a.txt/prompts/a.txt`. Our architecture has no per-file destination arithmetic — there's nothing to get wrong.

## Other differences

- **Parallel downloads** with configurable concurrency (default 8) and size-weighted progress reporting
- **Resume support** via HTTP Range headers and `.incomplete` files, compatible with Python's cache format
- **File locking** via [swift-filelock](https://github.com/DePasqualeOrg/swift-filelock) for cross-process safety
- **Offline mode** via `localFilesOnly` parameter and automatic `NetworkMonitor` detection
- **`resolveCachedSnapshot` public API** for zero-network cache lookups that resolve branch refs locally
- **Snapshot metadata saved after downloads**, so `resolveCachedSnapshot` only reports complete snapshots
- **`HubCache` required** (not optional), simplifying every cache interaction
