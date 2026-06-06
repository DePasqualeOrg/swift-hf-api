// Copyright © Anthony DePasquale

//! `OperationHandle` – the Swift-fired cancellation token for long-running
//! FFI calls (`download_file`, `snapshot_download`, `upload_folder`,
//! `create_commit`).
//!
//! UniFFI drops the in-flight Rust future when a Swift `Task` is cancelled,
//! which is enough on its own to abort `tokio` I/O. The handle exists for the
//! `AsyncStream` consumer-drop case described in the migration doc: if a Swift
//! consumer breaks out of a progress stream early, the foreign callback object
//! is freed but the Rust download keeps running and would fire `on_progress`
//! against a dead handle. The Swift wrapper passes an `OperationHandle` into
//! the call, fires `cancel()` from `AsyncStream.Continuation.onTermination`,
//! and Rust runs `tokio::select!` against the token alongside the I/O future.

use std::future::Future;
use std::sync::Arc;

use tokio_util::sync::CancellationToken;

use crate::core::error::{FFIResult, HFErrorFFI};

#[derive(uniffi::Object)]
pub struct OperationHandle {
    pub(crate) token: CancellationToken,
}

#[uniffi::export]
impl OperationHandle {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            token: CancellationToken::new(),
        })
    }

    /// Cancels the in-flight operation. Idempotent.
    pub fn cancel(&self) {
        self.token.cancel();
    }

    /// Returns `true` once `cancel()` has been called. The handle does
    /// not flip to cancelled on normal completion – it is `Arc`-shared by
    /// the Swift wrapper and outlives the in-flight operation.
    pub fn is_cancelled(&self) -> bool {
        self.token.is_cancelled()
    }
}

/// Race an FFI future against an optional cancellation handle.
///
/// `biased;` is intentional – when both futures are ready in the same poll
/// (cancellation arrived just as the result resolved) we prefer the result
/// so a completed operation isn't reported as cancelled. When `handle` is
/// `None`, the future is awaited directly.
///
/// Factored out of `repository.rs` so every long-running operation
/// (`download_file`, `download_file_to_bytes`, `download_file_stream`,
/// `snapshot_download`, `upload_file`, `upload_folder`, `create_commit`,
/// and the listing-stream pair) shares one cancellation preamble. Without
/// the helper the 8-line `match handle { ... tokio::select! { ... } }`
/// shape had to be retyped at every call site.
pub(crate) async fn run_cancellable<F, T>(
    handle: Option<Arc<OperationHandle>>,
    fut: F,
) -> FFIResult<T>
where
    F: Future<Output = FFIResult<T>>,
{
    match handle {
        Some(handle) => tokio::select! {
            biased;
            result = fut => result,
            () = handle.token.cancelled() => Err(HFErrorFFI::Cancelled),
        },
        None => fut.await,
    }
}
