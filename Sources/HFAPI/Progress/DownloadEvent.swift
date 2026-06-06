// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Lifecycle stage of a single file within a download.
public enum FileStatus: Sendable, Hashable {
    /// File has been queued for transfer but no bytes have moved yet.
    case started
    /// Bytes are actively being transferred.
    case inProgress
    /// All bytes for this file have been transferred. Terminal state.
    case complete

    init(_ dto: FileStatusDto) {
        self =
            switch dto {
            case .started: .started
            case .inProgress: .inProgress
            case .complete: .complete
            }
    }
}

/// Per-file delta carried in ``DownloadEvent/progress(files:)``. Only files whose
/// status or byte count changed since the previous event appear; consumers
/// wanting a running per-file view must accumulate state by `filename`.
public struct FileProgress: Sendable, Hashable {
    public let filename: String
    public let bytesCompleted: UInt64
    /// Total bytes expected for this file. Zero when the size is unknown.
    public let totalBytes: UInt64
    public let status: FileStatus

    public init(filename: String, bytesCompleted: UInt64, totalBytes: UInt64, status: FileStatus) {
        self.filename = filename
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.status = status
    }

    init(_ dto: FileProgressDto) {
        self.filename = dto.filename
        self.bytesCompleted = dto.bytesCompleted
        self.totalBytes = dto.totalBytes
        self.status = FileStatus(dto.status)
    }
}

/// Lifecycle events emitted by a download operation. See `hf_hub::DownloadEvent`
/// for the ordering and the two-channel `progress` vs `aggregateProgress` model.
public enum DownloadEvent: Sendable, Hashable {
    /// Download has begun; totals are known. Fires after the HEAD round-trip.
    case start(totalFiles: UInt64, totalBytes: UInt64)
    /// Per-file delta – `files` contains only files whose state changed since
    /// the previous `progress` event.
    case progress(files: [FileProgress])
    /// Aggregate byte-level progress for the in-flight xet batch (~10Hz). Two
    /// byte-count dimensions are reported: `bytesCompleted`/`totalBytes` track
    /// bytes flushed to disk at xorb-write boundaries (naturally chunky); the
    /// `transferBytes*` triplet tracks network bytes received from CAS (smooth,
    /// the right driver for a UI bar).
    case aggregateProgress(
        bytesCompleted: UInt64,
        totalBytes: UInt64,
        bytesPerSec: Double?,
        transferBytesCompleted: UInt64,
        transferBytes: UInt64,
        transferBytesPerSec: Double?
    )
    /// Terminal event on success. Not emitted on failure.
    case complete

    init(_ dto: DownloadEventDto) {
        self =
            switch dto {
            case .start(let totalFiles, let totalBytes):
                .start(totalFiles: totalFiles, totalBytes: totalBytes)
            case .progress(let files):
                .progress(files: files.map(FileProgress.init))
            case .aggregateProgress(
                let bytesCompleted,
                let totalBytes,
                let bytesPerSec,
                let transferBytesCompleted,
                let transferBytes,
                let transferBytesPerSec
            ):
                .aggregateProgress(
                    bytesCompleted: bytesCompleted,
                    totalBytes: totalBytes,
                    bytesPerSec: bytesPerSec,
                    transferBytesCompleted: transferBytesCompleted,
                    transferBytes: transferBytes,
                    transferBytesPerSec: transferBytesPerSec
                )
            case .complete:
                .complete
            }
    }
}
