// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Download helpers shared across ``ModelRepository`` and
/// ``DatasetRepository``. Each helper takes the underlying
/// ``HfRepositoryFfi`` so the per-kind extensions can stay one-liners.
///
/// `hf_hub::HFRepository<T>::download_file` (and its siblings) are generic
/// over `T: RepoType`, so every kind supports downloads. The Swift surface
/// reflects that: the public download methods live on
/// ``RepositoryProtocol``.

func repoDownloadFile(
    _ ffi: HfRepositoryFfi,
    filename: String,
    revision: String?,
    localDir: URL?,
    forceDownload: Bool,
    networkAccess: NetworkAccess,
    progress: (@Sendable (DownloadEvent) -> Void)?
) async throws -> URL {
    let handler: FfiDownloadProgressHandler? = progress.map { ClosureProgressHandler(closure: $0) }
    let resolvedOffline = await resolveNetworkAccess(networkAccess)
    let localDirPath = localDir?.path(percentEncoded: false)
    return try await withCancellableHFOperation { handle in
        let path = try await ffi.downloadFileToCache(
            filename: filename,
            revision: revision,
            localDir: localDirPath,
            forceDownload: forceDownload,
            localFilesOnly: resolvedOffline,
            handle: handle,
            progress: handler
        )
        return URL(fileURLWithPath: path)
    }
}

func repoDownloadFileStream(
    _ ffi: HfRepositoryFfi,
    filename: String,
    revision: String?,
    localDir: URL?,
    forceDownload: Bool,
    networkAccess: NetworkAccess
) -> DownloadStream {
    let localDirPath = localDir?.path(percentEncoded: false)
    // `onTermination` (wired up by `makeOperationStream`) fires lazily –
    // on the producer's next `yield()` after the consumer iterator has
    // been dropped – so for downloads that emit progress infrequently a
    // `break` alone may take seconds to convert into a `handle.cancel()`
    // (or never, if the producer happens not to yield again). Documented
    // contract: call ``DownloadStream/cancel()`` explicitly to abort the
    // underlying Rust future deterministically. Auto-cancellation via
    // termination is best-effort.
    return makeOperationStream(
        handler: StreamingProgressHandler.init,
        operation: { handle, handler in
            let resolvedOffline = await resolveNetworkAccess(networkAccess)
            let path = try await ffi.downloadFileToCache(
                filename: filename,
                revision: revision,
                localDir: localDirPath,
                forceDownload: forceDownload,
                localFilesOnly: resolvedOffline,
                handle: handle,
                progress: handler
            )
            return URL(fileURLWithPath: path)
        },
        wrap: DownloadStream.init
    )
}

func repoDownloadFileToBytes(
    _ ffi: HfRepositoryFfi,
    filename: String,
    revision: String?,
    localDir: URL?,
    forceDownload: Bool,
    networkAccess: NetworkAccess,
    progress: (@Sendable (DownloadEvent) -> Void)?
) async throws -> Data {
    // hf-hub's `download_file_to_bytes` doesn't touch the cache and has no
    // `force_download` / `local_dir` / `local_files_only` knobs. Routing
    // through `downloadFile` + an on-disk read preserves the cache-bypass
    // and offline-fallback semantics.
    let url = try await repoDownloadFile(
        ffi,
        filename: filename,
        revision: revision,
        localDir: localDir,
        forceDownload: forceDownload,
        networkAccess: networkAccess,
        progress: progress
    )
    // Read off-executor: `Data(contentsOf:)` is synchronous and would block
    // the calling task's actor for the duration of a multi-GB read. Wrap
    // the (Cocoa-typed) read failure as ``HFError.io`` so consumers see
    // the same error surface as the rest of the wrapper.
    //
    // `Task { … }` (not `Task.detached`) keeps the task in the surrounding
    // priority context and lets it observe its own cancellation, though
    // `Data(contentsOf:)` is a blocking C call that won't interrupt
    // mid-read regardless. The `withTaskCancellationHandler` wrap exists
    // so a caller-side `Task.cancel()` between completion of the network
    // download and the start of this read still bubbles `HFError.cancelled`
    // out before the blocking read begins.
    let readTask = Task<Data, Error>(priority: .userInitiated) {
        do {
            try Task.checkCancellation()
            return try Data(contentsOf: url)
        } catch is CancellationError {
            throw HFError.cancelled
        } catch let error as HFError {
            throw error
        } catch {
            let nsError = error as NSError
            throw HFError.io(
                message:
                    "Failed to read cached blob at \(url.path(percentEncoded: false)): "
                    + "\(error.localizedDescription) (\(nsError.domain) code \(nsError.code))"
            )
        }
    }
    return try await withTaskCancellationHandler {
        try await readTask.value
    } onCancel: {
        readTask.cancel()
    }
}

// This duplicates the catch-and-map shape that `makeOperationStream` provides
// for ``DownloadStream`` / ``UploadStream``. The bytes-stream returns a
// `(chunks, contentLength)` value pair from one FFI call instead of the
// `(events, result-URL)` shape `makeOperationStream` is built around;
// generalizing the helper would cost more than the ~10 duplicated lines below.
func repoDownloadFileBytesStream(
    _ ffi: HfRepositoryFfi,
    filename: String,
    revision: String?
) -> BytesDownloadStream {
    let handle = OperationHandle()
    let (stream, continuation) = AsyncThrowingStream<Data, Error>
        .makeStream(bufferingPolicy: .unbounded)
    continuation.onTermination = { @Sendable [handle] _ in
        handle.cancel()
    }

    // Listen to the FFI's progress channel so `contentLength` can resolve
    // as soon as `DownloadEvent::Start { total_bytes }` fires after the
    // response headers are read — well before byte streaming completes.
    let lengthSignal = ContentLengthSignal()
    let chunkHandler = ChunkStreamingHandler(continuation: continuation)
    let progressHandler = ContentLengthProgressHandler(signal: lengthSignal)
    let completionTask: Task<Void, Error> = Task {
        defer {
            continuation.finish()
            // Backstop in case the Rust future errors before emitting
            // `.start` (e.g., HEAD failure). First-resolution-wins so this
            // is a no-op if the start event already fired.
            lengthSignal.resolve(nil)
        }
        do {
            _ = try await ffi.downloadFileStream(
                filename: filename,
                revision: revision,
                handle: handle,
                progress: progressHandler,
                chunks: chunkHandler
            )
        } catch let error as HfErrorFfi {
            let mapped = HFError(error)
            continuation.finish(throwing: mapped)
            throw mapped
        } catch is CancellationError {
            continuation.finish(throwing: HFError.cancelled)
            throw HFError.cancelled
        } catch {
            // Any non-FFI error (future error paths) surfaces unchanged
            // to both the chunk iterator and `finish()` accessor; the outer
            // `defer` would otherwise complete the stream as if successful
            // and silently truncate the byte download.
            continuation.finish(throwing: error)
            throw error
        }
    }

    return BytesDownloadStream(
        chunks: stream,
        lengthSignal: lengthSignal,
        handle: handle,
        completion: completionTask
    )
}

func repoSnapshotDownload(
    _ ffi: HfRepositoryFfi,
    revision: String?,
    allowPatterns: [String]?,
    ignorePatterns: [String]?,
    localDir: URL?,
    forceDownload: Bool,
    networkAccess: NetworkAccess,
    maxWorkers: Int?,
    progress: (@Sendable (DownloadEvent) -> Void)?
) async throws -> URL {
    let handler: FfiDownloadProgressHandler? = progress.map { ClosureProgressHandler(closure: $0) }
    let resolvedOffline = await resolveNetworkAccess(networkAccess)
    let localDirPath = localDir?.path(percentEncoded: false)
    return try await withCancellableHFOperation { handle in
        let path = try await ffi.snapshotDownload(
            revision: revision,
            allowPatterns: allowPatterns,
            ignorePatterns: ignorePatterns,
            localDir: localDirPath,
            forceDownload: forceDownload,
            localFilesOnly: resolvedOffline,
            maxWorkers: maxWorkers.map(UInt32.init),
            handle: handle,
            progress: handler
        )
        return URL(fileURLWithPath: path)
    }
}

/// Resolves a ``NetworkAccess`` to the boolean `local_files_only` flag
/// expected by the underlying FFI. ``NetworkAccess/useIfAvailable``
/// consults ``NetworkMonitor``'s `shouldUseOfflineMode()` so callers
/// automatically fall back to the cache when the network is unreachable;
/// the explicit cases (``NetworkAccess/use`` / ``NetworkAccess/bypass``)
/// win over auto-detection. The `.useIfAvailable` case is Apple-only —
/// on Linux the default is `.use`.
private func resolveNetworkAccess(_ policy: NetworkAccess) async -> Bool {
    switch policy {
    case .use: return false
    case .bypass: return true
    #if canImport(Network)
        case .useIfAvailable:
            return await NetworkMonitor.shared.state.shouldUseOfflineMode()
    #endif
    }
}

/// Async sequence of ``DownloadEvent`` progress notifications for a single
/// download invocation. Await ``value`` for the resulting on-disk URL.
///
/// Cancellation: call ``cancel()`` to abort the download, or drop the
/// iterator early – the underlying `AsyncThrowingStream`'s `onTermination`
/// hook fires cancellation through to the Rust future.
public struct DownloadStream: AsyncSequence, Sendable {
    public typealias Element = DownloadEvent

    let events: AsyncThrowingStream<DownloadEvent, Error>
    let task: Task<URL, Error>
    private let handle: OperationHandle

    init(
        events: AsyncThrowingStream<DownloadEvent, Error>,
        task: Task<URL, Error>,
        handle: OperationHandle
    ) {
        self.events = events
        self.task = task
        self.handle = handle
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<DownloadEvent, Error>.AsyncIterator {
        events.makeAsyncIterator()
    }

    /// The on-disk URL of the downloaded file, awaited. Safe to call before,
    /// during, or after iterating events; the underlying `Task.value` is
    /// memoized.
    ///
    /// Propagates `Task.cancel()` to the underlying Rust future: a cancel on
    /// the awaiter's task fires ``cancel()`` and the download drops at its
    /// next `tokio::select!` poll. Consumers that iterate events see
    /// cancellation through the stream's `onTermination` hook; this wrap
    /// covers the value-only path.
    public var value: URL {
        get async throws {
            try await cancelOnTaskCancel(handle) {
                try await task.value
            }
        }
    }

    /// Cancels the download. Idempotent.
    public func cancel() {
        handle.cancel()
    }

    /// True once ``cancel()`` has been called (or the iterator was dropped
    /// early).
    public var isCancelled: Bool {
        handle.isCancelled()
    }
}

/// Async sequence of `Data` chunks for a streaming-bytes download.
///
/// ## Backpressure
///
/// The chunk stream is constructed with `.unbounded` buffering policy:
/// dropping bytes mid-download is never acceptable, so chunks accumulate
/// in memory if the consumer falls behind. Memory growth is proportional
/// to the un-iterated tail of the download. Either iterate eagerly, or
/// cancel via ``cancel()`` (or by breaking out of `for try await chunk in
/// stream { … }`) to release.
///
/// ## Caching
///
/// The streaming path is network-only – chunks come straight from the Hub
/// response. Neither the cache nor `networkAccess`/`forceDownload`
/// apply. To read an already cached file from disk, use
/// ``RepositoryProtocol/downloadFile(_:revision:localDir:forceDownload:networkAccess:progress:)``.
public struct BytesDownloadStream: AsyncSequence, Sendable {
    public typealias Element = Data

    let chunks: AsyncThrowingStream<Data, Error>
    let lengthSignal: ContentLengthSignal
    private let handle: OperationHandle
    let completion: Task<Void, Error>

    init(
        chunks: AsyncThrowingStream<Data, Error>,
        lengthSignal: ContentLengthSignal,
        handle: OperationHandle,
        completion: Task<Void, Error>
    ) {
        self.chunks = chunks
        self.lengthSignal = lengthSignal
        self.handle = handle
        self.completion = completion
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<Data, Error>.AsyncIterator {
        chunks.makeAsyncIterator()
    }

    /// Server-announced total bytes for this download, awaited.
    ///
    /// Resolves as soon as the response headers are read (typically tens
    /// of milliseconds after the request starts), **not** when the
    /// download completes. The value is the response's `Content-Length`
    /// header (or `X-Linked-Size` for LFS-backed files), or `nil` for
    /// chunked transfer encoding where no total is announced.
    ///
    /// Also resolves to `nil` when the download errors before headers
    /// arrive (HEAD failure, transport error). To distinguish "unknown
    /// total size" from "download failed", await ``finish()`` after iteration
    /// finishes.
    ///
    /// Safe to await before, during, or after iterating chunks; the
    /// result is memoized. Propagates `Task.cancel()` to the underlying
    /// Rust future so a cancel between request start and response headers
    /// trips ``cancel()`` instead of leaving the download running.
    public var contentLength: UInt64? {
        get async {
            await cancelOnTaskCancel(handle) {
                await lengthSignal.value
            }
        }
    }

    /// Awaits the download's completion and rethrows any error.
    ///
    /// Consumers iterating ``Element`` chunks see errors through the
    /// iterator's `throws` channel and don't need this accessor.
    /// Consumers awaiting only ``contentLength`` call ``finish()`` to learn
    /// whether the download ultimately succeeded – without it, a failed
    /// download would surface as `contentLength: nil` and be
    /// indistinguishable from a chunked-encoding response with no total.
    ///
    /// Safe to await multiple times; the underlying `Task` memoizes its
    /// result. Propagates `Task.cancel()` to the underlying Rust future so
    /// a value-only consumer (one that doesn't iterate chunks) still
    /// triggers cancellation.
    public func finish() async throws {
        try await cancelOnTaskCancel(handle) {
            try await completion.value
        }
    }

    /// Cancels the download. Idempotent.
    public func cancel() {
        handle.cancel()
    }

    /// True once ``cancel()`` has been called (or the iterator was dropped
    /// early).
    public var isCancelled: Bool {
        handle.isCancelled()
    }
}

/// One-shot async signal that resolves to the download's total content
/// length on the first `.start` progress event (or `nil` if the download
/// errors / completes without emitting `.start`).
///
/// First-resolution-wins is structural here: the state machine transitions
/// from `.pending` to `.resolved` atomically and never back. Subsequent
/// ``resolve(_:)`` calls are no-ops. Concurrent awaits all observe the
/// same resolved value.
///
/// `@unchecked Sendable` because the lock-protected mutable state isn't
/// expressible as `Sendable` via the type system. The class is `final`,
/// the only stored property is mutated only under `lock`, and
/// continuations are resumed outside the lock to avoid reentrant
/// deadlock.
final class ContentLengthSignal: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<UInt64?, Never>])
        case resolved(UInt64?)
    }

    private let lock = NSLock()
    private var state: State = .pending([])

    func resolve(_ value: UInt64?) {
        lock.lock()
        let waiters: [CheckedContinuation<UInt64?, Never>]
        switch state {
        case .pending(let pending):
            waiters = pending
            state = .resolved(value)
        case .resolved:
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    var value: UInt64? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                switch state {
                case .resolved(let resolved):
                    lock.unlock()
                    continuation.resume(returning: resolved)
                case .pending(var pending):
                    pending.append(continuation)
                    state = .pending(pending)
                    lock.unlock()
                }
            }
        }
    }

    deinit {
        // Defense in depth: the producer `Task` in
        // ``repoDownloadFileBytesStream`` always calls `resolve(nil)`
        // from its `defer` block, so this path is unreachable in normal
        // operation. A future refactor that drops the producer task
        // before the defer runs would otherwise hang parked awaiters
        // forever – resume them with `nil` ("unknown / failed") here.
        //
        // Not unit-testable: an awaiter holds the signal strongly while
        // suspended, which keeps deinit from firing.
        //
        // The lock-free read here is sound: `deinit` runs after the last
        // reference is gone, so no other thread can concurrently mutate
        // `state`. `@unchecked Sendable` is preserved because every
        // *non-deinit* path goes through `lock`.
        if case .pending(let waiters) = state {
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }
    }
}

// `@unchecked Sendable` on these handler classes is structurally safe:
// each is `final`, holds only `let`-typed `@Sendable` closures or
// `AsyncThrowingStream.Continuation` (itself `Sendable`), and has no
// mutable state. The `@unchecked` is required only because the
// FFI-generated handler protocols (`FfiDownloadProgressHandler`,
// `FfiUploadProgressHandler`, `FfiByteChunkHandler`) inherit
// `AnyObject + Sendable` and Swift cannot infer the conformance.
private final class ClosureProgressHandler: FfiDownloadProgressHandler, @unchecked Sendable {
    private let closure: @Sendable (DownloadEvent) -> Void

    init(closure: @escaping @Sendable (DownloadEvent) -> Void) {
        self.closure = closure
    }

    func onEvent(event: DownloadEventDto) {
        closure(DownloadEvent(event))
    }
}

/// Bridges the `with_foreign` callback into an `AsyncThrowingStream`. Per the
/// migration doc, the body must do exactly one thing: yield to the
/// continuation. UI work happens on the consumer side after `for await`.
private final class StreamingProgressHandler: FfiDownloadProgressHandler, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(event: DownloadEventDto) {
        continuation.yield(DownloadEvent(event))
    }
}

/// Bridges the byte-chunk `with_foreign` callback into an
/// `AsyncThrowingStream<Data, Error>`. Same threading contract as
/// the download-side `StreamingProgressHandler` – yield, return, no blocking.
private final class ChunkStreamingHandler: FfiByteChunkHandler, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func onChunk(chunk: Data) {
        continuation.yield(chunk)
    }
}

/// Listens for the byte-stream's `.start` progress event so a
/// ``BytesDownloadStream``'s ``BytesDownloadStream/contentLength`` can
/// resolve as soon as the response headers are available – well before
/// the byte stream finishes.
private final class ContentLengthProgressHandler: FfiDownloadProgressHandler, @unchecked Sendable {
    private let signal: ContentLengthSignal

    init(signal: ContentLengthSignal) {
        self.signal = signal
    }

    func onEvent(event: DownloadEventDto) {
        if case .start(_, let totalBytes) = event {
            // The Rust side substitutes 0 for "size unknown" when
            // emitting `.start`. Map back to nil at the Swift boundary so
            // the public `contentLength` signals "unknown" with `nil`,
            // never `0`.
            signal.resolve(totalBytes > 0 ? totalBytes : nil)
        }
    }
}
