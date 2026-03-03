# Swift ModelScope Client: Planning Document

## Goal

Add ModelScope Hub support to the Swift ecosystem by reusing shared infrastructure from swift-hf-api and building a separate ModelScope client module alongside it.

## Background

The Python ModelScope SDK (`modelscope.hub`) and Python `huggingface_hub` solve the same problem (downloading and caching models from a hub) but use fundamentally different approaches in the layers that matter most: caching, metadata retrieval, and authentication. However, the low-level infrastructure (HTTP with retry, composable auth providers, download coordination) is nearly identical.

swift-hf-api already has a clean `Shared/` directory containing this infrastructure. The plan is to extract it into a reusable module and build a new `MSAPI` module on top of it.

## Architecture Decision

**Shared foundation + independent clients**, not a unified abstraction.

### What is shared (infrastructure)

These files in `Sources/HFAPI/Shared/` are already hub-agnostic:

| File | Purpose | Changes needed for sharing |
|------|---------|----------------------------|
| `HTTPClient.swift` | HTTP fetch with retry, rate-limit parsing, pagination, streaming | Make `public`. Remove "Hugging Face" from doc comments. |
| `TokenProvider.swift` | Composable auth: fixed, environment, OAuth, custom, composite | Already generic in pattern, but HF env var names are hardcoded. Extract the pattern; HF and MS each define their own environment cases. |
| `CacheLocationProvider.swift` | Composable cache dir resolution | Same as TokenProvider: extract the pattern, each client defines its own env vars. |
| `NetworkMonitor.swift` | Connectivity monitoring | Fully generic, no changes needed. |
| `MultipartBuilder.swift` | Multipart form data construction | Fully generic, no changes needed. |
| `Value.swift` | Dynamic JSON value type | Fully generic, no changes needed. |
| `Extensions/` | URL, Data, JSONDecoder, URLSession helpers | Fully generic, no changes needed. |

### What diverges (client layer)

| Concern | Hugging Face | ModelScope | Why they can't unify |
|---------|-------------|-----------|---------------------|
| **Cache structure** | Content-addressed blobs + symlinks (ETag-keyed) | Direct file storage + pickle metadata (revision-keyed) | Fundamentally different storage models |
| **Metadata retrieval** | HTTP HEAD per file (lazy, ETag-based) | API list call for all files (eager, hash-based) | Different network strategies |
| **Auth mechanism** | Bearer token from env/file | Session cookie from token, or `MODELSCOPE_API_TOKEN` env var | Different HTTP auth headers |
| **Default endpoint** | `https://huggingface.co` | `https://www.modelscope.cn` (China) / `https://www.modelscope.ai` (international) | Multi-region with dynamic endpoint selection |
| **Repo kinds** | model, dataset, space | model, dataset (no spaces) | Different feature sets |
| **File integrity** | ETag from HTTP headers | SHA256 computed during download | Different validation approaches |
| **Large file transport** | Xet for files >16 MiB | Parallel range requests (160 MB chunks) for files >500 MB | Completely different protocols |
| **API response format** | Standard REST with Link-header pagination | JSON-wrapped responses with `Data` field, page-number pagination | Different parsing logic |

### What is new for ModelScope

The `MSAPI` module needs these MS-specific components:

| Component | Purpose | Notes |
|-----------|---------|-------|
| `MSClient` | API client for ModelScope Hub | Wraps `HTTPClient`. Handles cookie-based auth, multi-region endpoints, MS-specific API routes. |
| `MSCache` | Cache manager | Simpler than `HubCache` — direct file storage, metadata in JSON (not pickle — we're in Swift). Revision + path keyed. No symlinks needed. |
| `MSClient+Files` | File download and snapshot download | Eager file list fetch, SHA256 validation, parallel range-request support for large files. |
| `MSClient+Models` | Model listing and info | MS API routes: `/api/v1/models`, etc. |
| `MSClient+Datasets` | Dataset listing and info | MS API routes with page-number pagination. |
| `MSTokenProvider` | MS-specific token resolution | Reads from `MODELSCOPE_API_TOKEN` env var, `~/.modelscope/credentials` file, or explicit token. |
| `MSCacheLocationProvider` | MS-specific cache directory | Reads from `MODELSCOPE_CACHE` env var, defaults to `~/.cache/modelscope/hub/`. |
| Model types | `MSModel`, `MSDataset`, `MSFile`, etc. | MS-specific response types — different JSON schemas from HF. |

## Proposed Package Structure

There are two reasonable approaches for the package layout:

### Option A: Multi-module in swift-hf-api (monorepo)

Add new targets to the existing `Package.swift`:

```
Sources/
  HubCore/                    # Extracted shared infrastructure
    HTTPClient.swift
    TokenProvider.swift        # Base pattern only
    CacheLocationProvider.swift # Base pattern only
    NetworkMonitor.swift
    MultipartBuilder.swift
    Value.swift
    Extensions/
  HFAPI/                      # Hugging Face client (depends on HubCore)
    Hub/
      HubClient.swift
      HubCache.swift
      HubClient+Files.swift
      ... (existing HF-specific files)
    InferenceProviders/
    OAuth/
  MSAPI/                      # ModelScope client (depends on HubCore)
    MSClient.swift
    MSCache.swift
    MSClient+Files.swift
    MSClient+Models.swift
    MSClient+Datasets.swift
    MSTokenProvider.swift
    MSCacheLocationProvider.swift
    Types/
      MSModel.swift
      MSDataset.swift
      MSFile.swift
```

```swift
// Package.swift additions
.target(
    name: "HubCore",
    dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "FileLock", package: "swift-filelock"),
        .product(name: "SSE", package: "swift-sse"),
    ],
    path: "Sources/HubCore"
),
.target(
    name: "HFAPI",
    dependencies: ["HubCore", .product(name: "Xet", package: "swift-xet")],
    path: "Sources/HFAPI"
),
.target(
    name: "MSAPI",
    dependencies: ["HubCore"],
    path: "Sources/MSAPI"
),
```

**Pros**: Single repo, shared CI, atomic changes across modules, simpler dependency management for downstream consumers.
**Cons**: Package name ("swift-hf-api") is HF-branded. Consumers who only want MS pull in the whole repo.

### Option B: Separate packages

Extract `HubCore` into its own package, keep HF and MS as separate packages depending on it.

```
swift-hub-core/     → HubCore library
swift-hf-api/       → HFAPI library (depends on swift-hub-core)
swift-ms-api/        → MSAPI library (depends on swift-hub-core)
```

**Pros**: Clean separation, consumers pull only what they need, no branding conflict.
**Cons**: Three repos to maintain, cross-repo changes are harder, version coordination overhead.

### Recommendation

**Option A** is more practical for now. The package can be renamed to something neutral (e.g., `swift-hub-api`) if the scope broadens, and consumers can depend on just the `MSAPI` or `HFAPI` product they need. Option B can be revisited later if the package grows large or if there's a need for independent release cadences.

## Key Design Decisions

### MSCache: simpler than HubCache

ModelScope's Python cache uses pickle for metadata. In Swift, we should use JSON instead. The cache structure would be:

```
~/.cache/modelscope/hub/
  <owner>/<name>/
    .cache-metadata.json       # File list with hashes and revisions
    <file_path>                # Actual files, flat within repo dir
```

No symlinks, no content-addressed blobs. This matches the Python SDK's approach (direct storage, revision-keyed), is simpler to implement, and avoids symlink issues on non-Unix platforms.

### Authentication: cookie-based with bearer fallback

ModelScope uses session cookies (`m_session_id`) derived from an access token. The `MSClient` should:

1. Resolve a token via `MSTokenProvider` (env var, credentials file, or explicit)
2. Attach it as a cookie on each request (matching the Python SDK behavior)
3. Also support bearer token for API endpoints that accept it

Token resolution order:
1. Explicit token passed to `MSClient`
2. `MODELSCOPE_API_TOKEN` environment variable
3. `~/.modelscope/credentials` file

### Multi-region endpoint selection

ModelScope has two main endpoints:
- `https://www.modelscope.cn` (China, default)
- `https://www.modelscope.ai` (international)

The `MSClient` should support:
- Explicit endpoint override
- `MODELSCOPE_DOMAIN` environment variable
- `MODELSCOPE_PREFER_AI_SITE` flag to prefer the international endpoint
- Default to `.cn`

### Pagination

ModelScope uses page-number pagination (`page` + `page_size` query params) rather than Link-header pagination. The existing `HTTPClient.fetchPaginated` uses Link headers, so `MSClient` needs its own pagination helper that increments a page number until the response is empty.

### File integrity

ModelScope validates downloads with SHA256 hashes provided by the API (not HTTP ETags). The download flow:
1. Fetch file list from API (includes SHA256 for each file)
2. Check local cache for file at correct revision
3. Download if missing, compute SHA256 during download
4. Validate hash matches API-provided hash

## Scope for Initial Implementation

Focus on read-only operations first (download and cache), which is the primary use case for ML model consumption on Apple devices.

### Phase 1: Foundation

1. Extract `HubCore` module from existing `Shared/` directory
2. Generalize `TokenProvider` and `CacheLocationProvider` base patterns
3. Update `HFAPI` to depend on `HubCore` instead of inline `Shared/`
4. Verify all existing HF tests still pass

### Phase 2: MS Core Client

5. Create `MSAPI/MSTokenProvider.swift` with MS-specific token resolution
6. Create `MSAPI/MSCacheLocationProvider.swift` with MS-specific cache paths
7. Create `MSAPI/MSClient.swift` wrapping `HTTPClient` with cookie auth and multi-region endpoints
8. Create MS-specific response types (`MSModel`, `MSDataset`, `MSFile`)

### Phase 3: MS Download and Cache

9. Create `MSAPI/MSCache.swift` with JSON-based metadata and direct file storage
10. Create `MSAPI/MSClient+Files.swift` with `downloadFile` and `downloadSnapshot`
11. Implement SHA256 integrity validation during download
12. Implement parallel range-request download for large files (matching Python SDK's chunked download)

### Phase 4: MS API Operations

13. Create `MSAPI/MSClient+Models.swift` (list models, get model info, get model files)
14. Create `MSAPI/MSClient+Datasets.swift` (list datasets, get dataset info, get dataset files)
15. Implement page-number pagination helper

### Phase 5: Testing

16. Unit tests for MSCache (store, retrieve, metadata persistence)
17. Unit tests for MSTokenProvider and MSCacheLocationProvider
18. Integration tests for MSClient against ModelScope API (download a small public model)
19. Verify HFAPI tests still pass with the HubCore extraction

## Open Questions

- **Package naming**: Should we rename the package from `swift-hf-api` to something neutral like `swift-hub-api` now, or wait?
- **Upload support**: The Python MS SDK supports uploads. Do we need this in the Swift client, or is read-only sufficient for now?
- **Dataset streaming**: ModelScope has dataset-specific features (formations, virgo configs). Are these needed?
- **CLI**: The Python MS SDK has a CLI (`modelscope download`). Do we want a Swift CLI counterpart?

## Implementation Checklist

- [ ] Extract `HubCore` module from `Shared/`
- [ ] Generalize `TokenProvider` base pattern in `HubCore`
- [ ] Generalize `CacheLocationProvider` base pattern in `HubCore`
- [ ] Update `HFAPI` to import from `HubCore`
- [ ] Verify existing HF tests pass
- [ ] Create `MSTokenProvider`
- [ ] Create `MSCacheLocationProvider`
- [ ] Create `MSClient` with cookie auth and multi-region endpoints
- [ ] Create MS response types (`MSModel`, `MSDataset`, `MSFile`)
- [ ] Create `MSCache` with JSON metadata
- [ ] Create `MSClient+Files` (downloadFile, downloadSnapshot)
- [ ] Implement SHA256 validation
- [ ] Implement parallel range-request downloads for large files
- [ ] Create `MSClient+Models`
- [ ] Create `MSClient+Datasets`
- [ ] Implement page-number pagination
- [ ] Unit tests for MSCache
- [ ] Unit tests for MS token/cache providers
- [ ] Integration tests against ModelScope API
- [ ] Final verification of all HFAPI tests
