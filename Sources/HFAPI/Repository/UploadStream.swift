// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Async sequence of ``UploadEvent`` progress notifications for a streaming
/// upload. Await ``value`` for the resulting ``CommitInfo``.
///
/// Cancellation: call ``cancel()`` to abort the upload, or drop the iterator
/// early – the underlying `AsyncThrowingStream`'s `onTermination` hook fires
/// cancellation through to the Rust future.
public struct UploadStream: AsyncSequence, Sendable {
    public typealias Element = UploadEvent

    let events: AsyncThrowingStream<UploadEvent, Error>
    let task: Task<CommitInfo, Error>
    private let handle: OperationHandle

    init(
        events: AsyncThrowingStream<UploadEvent, Error>,
        task: Task<CommitInfo, Error>,
        handle: OperationHandle
    ) {
        self.events = events
        self.task = task
        self.handle = handle
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<UploadEvent, Error>.AsyncIterator {
        events.makeAsyncIterator()
    }

    /// The ``CommitInfo`` for the resulting commit, awaited. Safe to call
    /// before, during, or after iterating events.
    ///
    /// Propagates `Task.cancel()` to the underlying Rust future: if the
    /// awaiter's task is cancelled, ``cancel()`` fires and the Rust upload
    /// drops at its next `tokio::select!` poll. Without this wrap, a
    /// consumer that awaits only ``value`` (i.e. doesn't iterate events)
    /// would see `CancellationError` while the Rust future kept running to
    /// completion – the iteration path is covered by the stream's
    /// `onTermination` hook, but the value-only path is not.
    public var value: CommitInfo {
        get async throws {
            try await cancelOnTaskCancel(handle) {
                try await task.value
            }
        }
    }

    /// Cancels the upload. Idempotent.
    public func cancel() {
        handle.cancel()
    }

    /// True once ``cancel()`` has been called (or the iterator was dropped
    /// early).
    public var isCancelled: Bool {
        handle.isCancelled()
    }
}
