// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Run an async `body` that takes a fresh ``OperationHandle``, wiring up
/// `Task.cancel()` from the caller's task so the handle's
/// ``OperationHandle/cancel()`` fires and the in-flight Rust future drops
/// at its next `tokio::select!` poll. Also lifts any thrown
/// `HfErrorFfi` to ``HFError``.
///
/// Used by every non-streaming long-running helper (`repoUploadFile`,
/// `repoUploadFolder`, `repoCreateCommit`, `repoDownloadFile`,
/// `repoSnapshotDownload`). Streaming helpers use the same handle but
/// trip cancellation via `AsyncThrowingStream.Continuation.onTermination`
/// instead.
func withCancellableHFOperation<T: Sendable>(
    _ body: (OperationHandle) async throws -> T
) async throws -> T {
    let handle = OperationHandle()
    do {
        return try await withTaskCancellationHandler {
            try await mapHFError {
                try await body(handle)
            }
        } onCancel: {
            handle.cancel()
        }
    } catch is CancellationError {
        // Pre-await `Task.cancel()` short-circuits before the FFI call
        // starts; translate to ``HFError/cancelled`` so consumers only ever
        // pattern-match on a single cancellation variant.
        throw HFError.cancelled
    }
}

/// Wires Swift `Task.cancel()` from the caller's task through to a
/// long-lived ``OperationHandle`` so the underlying Rust future drops at
/// its next `tokio::select!` poll. Used by stream-accessor properties
/// (``DownloadStream/value``, ``BytesDownloadStream/finish()``,
/// ``BytesDownloadStream/contentLength``, ``UploadStream/value``) that wait
/// on an already-spawned task; the cancellation handler is the only
/// machinery they need.
@inline(__always)
func cancelOnTaskCancel<T>(
    _ handle: OperationHandle,
    _ body: () async throws -> T
) async rethrows -> T {
    try await withTaskCancellationHandler {
        try await body()
    } onCancel: {
        handle.cancel()
    }
}

/// Boilerplate-free construction of a streaming operation: build the
/// progress-event stream, hook up cancellation, spawn the result-bearing
/// `Task`, and wrap everything in the caller's stream type.
///
/// Used by every `repoXxxStream` helper. The four sites share the same
/// five-step shape:
///
/// 1. Allocate an ``OperationHandle`` for cancellation propagation.
/// 2. Build an `AsyncThrowingStream` with the requested buffering policy.
/// 3. Wire `onTermination` so dropping the iterator fires cancellation.
/// 4. Spawn a `Task` that calls the FFI, finishing the continuation on
///    completion (success or failure) and mapping `HfErrorFfi` to
///    ``HFError`` at the boundary.
/// 5. Return the consumer-facing stream wrapper around the events, task,
///    and handle.
///
/// Parameters:
///   - bufferingPolicy: Buffering policy for the progress-event stream.
///   - handler: Synchronously builds the FFI callback object that yields
///     into the continuation. Runs once on the calling task before the
///     producer `Task` is spawned.
///   - operation: The FFI call. Receives the handle (so it can pass it
///     as a cancellation token) and the handler built above. Returning a
///     `Result` resolves the stream's `value`; throwing finishes the
///     continuation with the error.
///   - wrap: Builds the consumer-facing wrapper from the resulting
///     `(events, task, handle)` triple.
func makeOperationStream<Event, Result, Handler, Stream>(
    bufferingPolicy: AsyncThrowingStream<Event, Error>.Continuation.BufferingPolicy =
        .bufferingNewest(2),
    handler: (AsyncThrowingStream<Event, Error>.Continuation) -> Handler,
    operation: @escaping @Sendable (OperationHandle, Handler) async throws -> Result,
    wrap: (AsyncThrowingStream<Event, Error>, Task<Result, Error>, OperationHandle) -> Stream
) -> Stream where Event: Sendable, Result: Sendable, Handler: Sendable {
    let handle = OperationHandle()
    let (events, continuation) = AsyncThrowingStream<Event, Error>
        .makeStream(bufferingPolicy: bufferingPolicy)
    continuation.onTermination = { @Sendable [handle] _ in
        handle.cancel()
    }

    let handlerInstance = handler(continuation)
    let task = Task {
        do {
            let result = try await operation(handle, handlerInstance)
            continuation.finish()
            return result
        } catch let error as HfErrorFfi {
            let mapped = HFError(error)
            continuation.finish(throwing: mapped)
            throw mapped
        } catch is CancellationError {
            // Pre-await `Task.cancel()` lands here before the FFI call gets
            // a chance to fire its own ``HFError/cancelled``. Translate so
            // consumers see one cancellation variant.
            continuation.finish(throwing: HFError.cancelled)
            throw HFError.cancelled
        } catch {
            // Any other error (most commonly an `HFError` thrown by the
            // operation closure itself) is forwarded to both the stream
            // and the task's `value`. Without this catch the deferred
            // `continuation.finish()` would have completed the stream
            // cleanly, leaving the error visible only via `task.value` –
            // consumers iterating events would never observe the failure.
            continuation.finish(throwing: error)
            throw error
        }
    }

    return wrap(events, task, handle)
}
