// Copyright © Anthony DePasquale

//! Progress events forwarded from `hf_hub::progress::ProgressHandler`
//! through `with_foreign` UniFFI traits into Swift. Download and upload
//! events flow through separate handlers so Swift consumers don't have to
//! pattern-match a flat `ProgressEvent` enum at every call site.

use std::sync::Arc;

use hf_hub::progress::{
    DownloadEvent, FileProgress, FileStatus, ProgressEvent, ProgressHandler, UploadEvent,
};

/// Lifecycle stage of an individual file within a download.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FileStatusDTO {
    Started,
    InProgress,
    Complete,
}

impl From<&FileStatus> for FileStatusDTO {
    fn from(s: &FileStatus) -> Self {
        match s {
            FileStatus::Started => Self::Started,
            FileStatus::InProgress => Self::InProgress,
            FileStatus::Complete => Self::Complete,
        }
    }
}

/// Per-file delta carried in [`DownloadEventDTO::Progress`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct FileProgressDTO {
    pub filename: String,
    pub bytes_completed: u64,
    pub total_bytes: u64,
    pub status: FileStatusDTO,
}

impl From<&FileProgress> for FileProgressDTO {
    fn from(f: &FileProgress) -> Self {
        Self {
            filename: f.filename.clone(),
            bytes_completed: f.bytes_completed,
            total_bytes: f.total_bytes,
            status: FileStatusDTO::from(&f.status),
        }
    }
}

/// Lifecycle events for a single download operation. Mirrors
/// `hf_hub::progress::DownloadEvent` 1:1 – see the upstream docs for ordering
/// and the two-channel `Progress` vs `AggregateProgress` model.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum DownloadEventDTO {
    Start {
        total_files: u64,
        total_bytes: u64,
    },
    /// Per-file delta – `files` contains only files whose status or byte
    /// count changed since the previous `Progress` event.
    Progress {
        files: Vec<FileProgressDTO>,
    },
    /// Aggregate byte-level progress for the in-flight xet batch (~10Hz). Two
    /// byte-count dimensions are reported, mirroring `UploadEventDTO::Progress`:
    /// `bytes_completed`/`total_bytes` track bytes flushed to disk at xorb-write
    /// boundaries (naturally chunky), and `transfer_bytes_completed`/
    /// `transfer_bytes` track network bytes received from CAS (smooth, the
    /// right driver for a UI bar).
    AggregateProgress {
        bytes_completed: u64,
        total_bytes: u64,
        bytes_per_sec: Option<f64>,
        transfer_bytes_completed: u64,
        transfer_bytes: u64,
        transfer_bytes_per_sec: Option<f64>,
    },
    Complete,
}

impl From<&DownloadEvent> for DownloadEventDTO {
    fn from(event: &DownloadEvent) -> Self {
        match event {
            DownloadEvent::Start {
                total_files,
                total_bytes,
            } => Self::Start {
                total_files: *total_files as u64,
                total_bytes: *total_bytes,
            },
            DownloadEvent::Progress { files } => Self::Progress {
                files: files.iter().map(FileProgressDTO::from).collect(),
            },
            DownloadEvent::AggregateProgress {
                bytes_completed,
                total_bytes,
                bytes_per_sec,
                transfer_bytes_completed,
                transfer_bytes,
                transfer_bytes_per_sec,
            } => Self::AggregateProgress {
                bytes_completed: *bytes_completed,
                total_bytes: *total_bytes,
                bytes_per_sec: *bytes_per_sec,
                transfer_bytes_completed: *transfer_bytes_completed,
                transfer_bytes: *transfer_bytes,
                transfer_bytes_per_sec: *transfer_bytes_per_sec,
            },
            DownloadEvent::Complete => Self::Complete,
        }
    }
}

/// Foreign-implemented callback called once per download progress event.
///
/// The Swift implementation must not block – per the migration doc and the
/// upstream `ProgressHandler` contract, the body runs on a tokio worker
/// thread. The standard implementation just yields to an
/// `AsyncStream.Continuation` and returns.
///
/// **Backpressure note**: the FFI signature has no return value, so when the
/// Swift `Continuation.yield(_:)` returns `.dropped` (consumer is slower than
/// the producer) Rust never finds out. For progress events this is fine —
/// each event carries an absolute byte counter, so a dropped event is
/// reconstructable from the next one. Consumers wanting strict
/// every-event-delivery should buffer with `bufferingPolicy: .unbounded` on
/// the Swift `AsyncStream`.
#[uniffi::export(with_foreign)]
pub trait FFIDownloadProgressHandler: Send + Sync {
    fn on_event(&self, event: DownloadEventDTO);
}

/// Foreign-implemented callback called once per byte chunk yielded by a
/// chunked download (`download_file_stream`).
///
/// Same threading and non-blocking contract as
/// [`FFIDownloadProgressHandler::on_event`] – the body runs on a tokio worker
/// thread and should yield to an `AsyncStream.Continuation`. Each chunk is
/// produced by the underlying HTTP byte stream and surfaces verbatim; the
/// caller is responsible for stitching the chunks back together if a single
/// `Data` payload is wanted.
///
/// **Backpressure note**: unlike progress events, byte chunks are NOT
/// reconstructable from the next chunk – a dropped chunk corrupts the
/// assembled payload. Swift wrappers MUST buffer with
/// `bufferingPolicy: .unbounded` to guarantee FIFO delivery.
#[uniffi::export(with_foreign)]
pub trait FFIByteChunkHandler: Send + Sync {
    fn on_chunk(&self, chunk: Vec<u8>);
}

/// Bridges the upstream `ProgressHandler` trait to a foreign-implemented
/// `FFIDownloadProgressHandler`, filtering out the upload variants.
pub(crate) struct DownloadProgressBridge {
    pub(crate) inner: Arc<dyn FFIDownloadProgressHandler>,
}

impl ProgressHandler for DownloadProgressBridge {
    fn on_progress(&self, event: &ProgressEvent) {
        if let ProgressEvent::Download(download) = event {
            self.inner.on_event(DownloadEventDTO::from(download));
        }
    }
}

/// Lifecycle events for a single upload operation. Mirrors
/// `hf_hub::progress::UploadEvent`; see the upstream docs for the
/// `Start → Progress → Committing → Complete` ordering and the silent-gap
/// caveats around fast-path inline files.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum UploadEventDTO {
    Start {
        total_files: u64,
        total_bytes: u64,
    },
    /// Byte-level progress during the active upload phase, emitted at ~10Hz
    /// by the xet upload poll loop. Two byte-count dimensions are reported:
    /// `bytes_completed`/`total_bytes` track logical content bytes, and
    /// `transfer_bytes_completed`/`transfer_bytes` track post-dedup
    /// network bytes actually sent.
    Progress {
        bytes_completed: u64,
        total_bytes: u64,
        bytes_per_sec: Option<f64>,
        transfer_bytes_completed: u64,
        transfer_bytes: u64,
        transfer_bytes_per_sec: Option<f64>,
        files: Vec<FileProgressDTO>,
    },
    /// Fired once, immediately before the commit API call. Signals that all
    /// byte transfer is done; the call itself is silent until `Complete`.
    Committing,
    Complete,
}

impl From<&UploadEvent> for UploadEventDTO {
    fn from(event: &UploadEvent) -> Self {
        match event {
            UploadEvent::Start {
                total_files,
                total_bytes,
            } => Self::Start {
                total_files: *total_files as u64,
                total_bytes: *total_bytes,
            },
            UploadEvent::Progress {
                bytes_completed,
                total_bytes,
                bytes_per_sec,
                transfer_bytes_completed,
                transfer_bytes,
                transfer_bytes_per_sec,
                files,
            } => Self::Progress {
                bytes_completed: *bytes_completed,
                total_bytes: *total_bytes,
                bytes_per_sec: *bytes_per_sec,
                transfer_bytes_completed: *transfer_bytes_completed,
                transfer_bytes: *transfer_bytes,
                transfer_bytes_per_sec: *transfer_bytes_per_sec,
                files: files.iter().map(FileProgressDTO::from).collect(),
            },
            UploadEvent::Committing => Self::Committing,
            UploadEvent::Complete => Self::Complete,
        }
    }
}

/// Foreign-implemented callback called once per upload progress event.
///
/// Same threading and non-blocking contract as
/// [`FFIDownloadProgressHandler::on_event`] – runs on a tokio worker thread,
/// must not block. The standard implementation just yields to an
/// `AsyncStream.Continuation` and returns.
#[uniffi::export(with_foreign)]
pub trait FFIUploadProgressHandler: Send + Sync {
    fn on_event(&self, event: UploadEventDTO);
}

/// Bridges the upstream `ProgressHandler` trait to a foreign-implemented
/// `FFIUploadProgressHandler`, filtering out the download variants.
pub(crate) struct UploadProgressBridge {
    pub(crate) inner: Arc<dyn FFIUploadProgressHandler>,
}

impl ProgressHandler for UploadProgressBridge {
    fn on_progress(&self, event: &ProgressEvent) {
        if let ProgressEvent::Upload(upload) = event {
            self.inner.on_event(UploadEventDTO::from(upload));
        }
    }
}
