# Pagination design

Our pagination system differs from [upstream](https://github.com/huggingface/swift-huggingface) in several ways. Upstream's pagination was introduced in [PR #26](https://github.com/huggingface/swift-huggingface/pull/26).

## Item-level iteration by default

**Upstream:** `listModels()` is `async throws` and returns a single `PaginatedResponse<Model>` (just the first page). Multi-page iteration requires a separate `Pages<T>` type and nested loops:

```swift
let firstPage = try await client.listModels()
for model in firstPage.items {
    print(model.name)
}
// or with Pages for multi-page:
for try await page in client.listModels().pages {
    for model in page.items {
        print(model.name)
    }
}
```

**Ours:** `listModels()` is synchronous and returns a `PaginatedSequence<Model>` that yields individual items, automatically handling page boundaries:

```swift
for try await model in client.listModels() {
    print(model.name)
}
```

Page-level access is available via `.pages` when needed for batch processing:

```swift
for try await page in client.listModels().pages {
    processBatch(page.items)
}
```

## Fully lazy evaluation

**Upstream:** `Pages<T>` takes an already-fetched first page as input, so the first network request happens before iteration begins.

**Ours:** `PaginatedSequence` makes no network requests until the caller starts iterating. The first page is fetched on the first call to `next()`.

## Client-side limit

**Upstream:** The `limit` parameter maps to the server's `limit` query parameter, which controls per-page size. There is no way to cap the total number of results across pages.

**Ours:** The `limit` parameter is enforced client-side across all pages. When the limit is reached, iteration stops and no further pages are fetched. The limit is also passed to the server as the per-page size, which avoids fetching oversized pages when only a small number of results are needed.

## Empty page handling

**Upstream:** Empty pages are yielded to the caller.

**Ours:** `PaginatedSequence` skips empty pages automatically, continuing to the next page as long as there is a next URL. This prevents callers from receiving empty results mid-iteration.

## Retry with backoff

**Upstream:** No retry logic for paginated requests.

**Ours:** First page requests fail immediately (no retry), giving fast feedback on bad parameters or authentication errors. Subsequent page requests retry with exponential backoff on server errors (429, 500, 502, 503, 504), matching Python `huggingface_hub`'s retry behavior. Rate limit responses (429) use the server's `RateLimit` or `Retry-After` header to determine wait time.

## No `direction` parameter

**Upstream:** List methods accept a `direction` parameter for sort direction.

**Ours:** We removed `direction` because the Hugging Face API does not actually support it — Python `huggingface_hub` [removed it in v0.28.0](https://github.com/huggingface/huggingface_hub/commit/b5863da#diff-a823490ba78de6e87b69e0e5d6bd90f8fa6b8f4eL190-L196).

## No query parameter preservation

Upstream stores a `requestURL` on each `PaginatedResponse` and uses a `resolveNextPageURL` function that resolves relative next URLs and back-fills query parameters that the server may have omitted from the Link header. We don't do this because the Hugging Face API returns absolute URLs with complete query parameters in Link headers. Python `huggingface_hub` also follows Link headers directly without parameter preservation.
