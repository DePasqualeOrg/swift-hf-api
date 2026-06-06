// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Sort field for ``HFClient/listModels(search:author:filter:sort:pipelineTag:full:cardData:fetchConfig:limit:)``
/// and ``HFClient/listDatasets(search:author:filter:sort:full:limit:)``. The
/// raw value is the camelCase Hub field name passed in the `?sort=` query
/// parameter.
///
/// Callers use a canonical case (`.downloads`, `.likes`, …) for fields
/// this library knows about, and ``other(_:)`` to forward a Hub field
/// this library does not yet know about so new Hub fields can be sorted
/// on without waiting for a library release. Mirrors the ``SecurityStatus``
/// / ``GatedMode`` / ``CachedRepoType`` shape used elsewhere in the
/// codebase for forward-compat enums.
public enum RepoSort: Sendable, Hashable {
    case downloads
    case likes
    case createdAt
    case lastModified
    case trendingScore
    case other(String)

    public var rawValue: String {
        switch self {
        case .downloads: "downloads"
        case .likes: "likes"
        case .createdAt: "createdAt"
        case .lastModified: "lastModified"
        case .trendingScore: "trendingScore"
        case .other(let value): value
        }
    }
}

extension HFClient {
    /// List models from the Hub via `GET /api/models`.
    ///
    /// Mirrors `hf_hub::HFClient::list_models`. Every parameter is optional and
    /// defers to the Hub default when unset. The Hub paginates server-side at
    /// 1000 items per page; the FFI eagerly collects every page into a single
    /// `[ModelInfo]` before returning. Use `limit` when iterating long listings
    /// to avoid pulling more than needed.
    ///
    /// - Parameters:
    ///   - search: Free-text query forwarded as `?search=`. The Hub matches it
    ///     substring-style against the model `id` and card description – it is
    ///     **not** a tag filter.
    ///   - author: Namespace owner forwarded as `?author=` (e.g., `"google"`,
    ///     `"meta-llama"`).
    ///   - filter: A single Hub tag value forwarded as `?filter=`. Use the
    ///     Hub's namespaced format, e.g., `"pytorch"`, `"text-generation"`,
    ///     `"license:apache-2.0"`. Only one tag is sent – narrow further
    ///     client-side if needed.
    ///   - sort: Sort field forwarded as `?sort=`. Use a canonical
    ///     ``RepoSort`` value (e.g., `.downloads`, `.trendingScore`) or
    ///     `RepoSort.other("newField")` for a Hub field this library
    ///     doesn't expose yet.
    ///   - pipelineTag: Pipeline-tag filter (e.g., `"text-classification"`,
    ///     `"automatic-speech-recognition"`), forwarded as `?pipeline_tag=`.
    ///   - full: Fetch the full model information including all fields.
    ///   - cardData: Include the model card metadata in the response.
    ///   - fetchConfig: Include the model configuration in the response.
    ///   - limit: Cap on the total number of items returned. Defaults to
    ///     `1000` (one Hub page). Values above `10_000` are clamped to that
    ///     ceiling on the FFI side – for genuinely unbounded iteration, use
    ///     ``listModelsStream(search:author:filter:sort:pipelineTag:full:cardData:fetchConfig:limit:)``.
    public func listModels(
        search: String? = nil,
        author: String? = nil,
        filter: String? = nil,
        sort: RepoSort? = nil,
        pipelineTag: String? = nil,
        full: Bool? = nil,
        cardData: Bool? = nil,
        fetchConfig: Bool? = nil,
        limit: Int = 1000
    ) async throws -> [ModelInfo] {
        try await mapHFError {
            let dtos = try await ffi.listModels(
                search: search,
                author: author,
                filter: filter,
                sort: sort?.rawValue,
                pipelineTag: pipelineTag,
                full: full,
                cardData: cardData,
                fetchConfig: fetchConfig,
                limit: try unsignedLimit(limit)
            )
            return dtos.map(ModelInfo.init)
        }
    }

    /// Pull-based streaming counterpart to
    /// ``listModels(search:author:filter:sort:pipelineTag:full:cardData:fetchConfig:limit:)``.
    /// Returns a ``ModelInfoListing`` `AsyncSequence`; each `for try
    /// await model in …` iteration calls into the Rust backend to pull
    /// one entry from a capacity-1 channel. The upstream Hub `Stream` is
    /// only advanced when the consumer asks, so memory is bounded
    /// regardless of how slowly the consumer iterates.
    ///
    /// Cancellation: breaking out of the iterator, calling
    /// ``ModelInfoListing/cancel()``, or letting the enclosing `Task`
    /// finish all close the channel; the Rust drain task drops the
    /// in-flight request at its next `tokio::select!` poll.
    ///
    /// Use this form when the result set might be large (the Hub has
    /// hundreds of thousands of models) or when you only want the first
    /// few matches. For small bounded result sets the eager
    /// ``listModels(search:author:filter:sort:pipelineTag:full:cardData:fetchConfig:limit:)``
    /// form is simpler.
    public func listModelsStream(
        search: String? = nil,
        author: String? = nil,
        filter: String? = nil,
        sort: RepoSort? = nil,
        pipelineTag: String? = nil,
        full: Bool? = nil,
        cardData: Bool? = nil,
        fetchConfig: Bool? = nil,
        limit: Int? = nil
    ) async throws -> ModelInfoListing {
        try await mapHFError {
            let ffi = try await ffi.listModelsStream(
                search: search,
                author: author,
                filter: filter,
                sort: sort?.rawValue,
                pipelineTag: pipelineTag,
                full: full,
                cardData: cardData,
                fetchConfig: fetchConfig,
                limit: try limit.map(unsignedLimit)
            )
            return ModelInfoListing(ffi: ffi)
        }
    }

    /// List datasets from the Hub via `GET /api/datasets`.
    ///
    /// Mirrors `hf_hub::HFClient::list_datasets`. Every parameter is optional
    /// and defers to the Hub default when unset.
    ///
    /// - Parameters:
    ///   - search: Free-text query forwarded as `?search=`. Substring-matched
    ///     against the dataset `id` and card description – not a tag filter.
    ///   - author: Namespace owner forwarded as `?author=` (e.g.,
    ///     `"HuggingFaceH4"`, `"allenai"`).
    ///   - filter: A single Hub tag value forwarded as `?filter=` (e.g.,
    ///     `"task_categories:text-classification"`, `"language:en"`,
    ///     `"license:mit"`). Only one tag is sent.
    ///   - sort: Sort field forwarded as `?sort=`. Use a canonical
    ///     ``RepoSort`` value or `RepoSort.other("newField")`.
    ///   - full: Fetch the full dataset information including all fields.
    ///   - limit: Cap on the total number of items returned. Defaults to
    ///     `1000` (one Hub page). Values above `10_000` are clamped on the
    ///     FFI side – for genuinely unbounded iteration, use
    ///     ``listDatasetsStream(search:author:filter:sort:full:limit:)``.
    public func listDatasets(
        search: String? = nil,
        author: String? = nil,
        filter: String? = nil,
        sort: RepoSort? = nil,
        full: Bool? = nil,
        limit: Int = 1000
    ) async throws -> [DatasetInfo] {
        try await mapHFError {
            let dtos = try await ffi.listDatasets(
                search: search,
                author: author,
                filter: filter,
                sort: sort?.rawValue,
                full: full,
                limit: try unsignedLimit(limit)
            )
            return dtos.map(DatasetInfo.init)
        }
    }

    /// Pull-based streaming counterpart to
    /// ``listDatasets(search:author:filter:sort:full:limit:)``. See
    /// ``listModelsStream(search:author:filter:sort:pipelineTag:full:cardData:fetchConfig:limit:)``
    /// for the backpressure, cancellation, and use-case guidance.
    public func listDatasetsStream(
        search: String? = nil,
        author: String? = nil,
        filter: String? = nil,
        sort: RepoSort? = nil,
        full: Bool? = nil,
        limit: Int? = nil
    ) async throws -> DatasetInfoListing {
        try await mapHFError {
            let ffi = try await ffi.listDatasetsStream(
                search: search,
                author: author,
                filter: filter,
                sort: sort?.rawValue,
                full: full,
                limit: try limit.map(unsignedLimit)
            )
            return DatasetInfoListing(ffi: ffi)
        }
    }
}

/// Reject negative `limit` values before they reach `UInt64(_:)`, which
/// traps on negatives. The Hub treats `0` as "no items" and the FFI clamps
/// any value above `MAX_EAGER_LISTING_LIMIT`, so non-negative values pass
/// through unchanged.
private func unsignedLimit(_ value: Int) throws -> UInt64 {
    guard value >= 0 else {
        throw HFError.invalidParameter(message: "limit cannot be negative (got \(value))")
    }
    return UInt64(value)
}

/// Pull-based `AsyncSequence` of ``ModelInfo``. Each call to the
/// iterator's `next()` pulls one entry from the Rust backend over a
/// capacity-1 channel, so the upstream Hub pagination only advances when
/// the consumer asks – memory is bounded regardless of consumer speed.
///
/// Cancellation: dropping the iterator (or the listing itself), calling
/// ``cancel()`` explicitly, or cancelling the enclosing `Task` all
/// trigger the Rust drain task to drop the in-flight request at its
/// next `tokio::select!` poll.
public struct ModelInfoListing: AsyncSequence, Sendable {
    public typealias Element = ModelInfo

    private let ffi: ModelInfoListingFfi

    init(ffi: ModelInfoListingFfi) {
        self.ffi = ffi
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let ffi: ModelInfoListingFfi

        public mutating func next() async throws -> ModelInfo? {
            // `withTaskCancellationHandler` wires Swift `Task.cancel()`
            // through to the Rust drain task: the awaiting `ffi.next()`
            // is unblocked by `Task.cancel()`, but unless we also fire
            // `ffi.cancel()` here the Rust task would keep polling the
            // upstream stream until the Listing reference is dropped.
            // Matches the download/upload stream cancellation idiom.
            let ffi = self.ffi
            do {
                let dto = try await withTaskCancellationHandler {
                    try await ffi.next()
                } onCancel: {
                    ffi.cancel()
                }
                guard let dto else { return nil }
                return ModelInfo(dto)
            } catch let error as HfErrorFfi {
                throw HFError(error)
            } catch is CancellationError {
                // Pre-await `Task.cancel()` raises `CancellationError`
                // before the FFI sees the request; surface the same
                // `HFError.cancelled` consumers get from the FFI path.
                throw HFError.cancelled
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(ffi: ffi)
    }

    /// Abort the underlying request. Idempotent.
    public func cancel() {
        ffi.cancel()
    }

    public var isCancelled: Bool {
        ffi.isCancelled()
    }
}

/// Pull-based `AsyncSequence` of ``DatasetInfo``. Mirrors
/// ``ModelInfoListing``.
public struct DatasetInfoListing: AsyncSequence, Sendable {
    public typealias Element = DatasetInfo

    private let ffi: DatasetInfoListingFfi

    init(ffi: DatasetInfoListingFfi) {
        self.ffi = ffi
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let ffi: DatasetInfoListingFfi

        public mutating func next() async throws -> DatasetInfo? {
            let ffi = self.ffi
            do {
                let dto = try await withTaskCancellationHandler {
                    try await ffi.next()
                } onCancel: {
                    ffi.cancel()
                }
                guard let dto else { return nil }
                return DatasetInfo(dto)
            } catch let error as HfErrorFfi {
                throw HFError(error)
            } catch is CancellationError {
                throw HFError.cancelled
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(ffi: ffi)
    }

    public func cancel() {
        ffi.cancel()
    }

    public var isCancelled: Bool {
        ffi.isCancelled()
    }
}
