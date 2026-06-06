// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Lifecycle events emitted by an upload operation. See `hf_hub::UploadEvent`
/// for the `start → progress → committing → complete` ordering and the
/// silent-gap caveats around inline-fast-path files.
///
/// The two byte-count dimensions on `progress` reflect xet content-defined
/// deduplication: `bytesCompleted`/`totalBytes` track logical content
/// bytes (good for a "% processed" bar), while `transferBytesCompleted`/
/// `transferBytes` track post-dedup network bytes actually sent (good for
/// a "network activity" bar). For deduplicated data,
/// `transferBytes` ≪ `totalBytes`.
public enum UploadEvent: Sendable, Hashable {
    /// Upload has begun; totals are known.
    case start(totalFiles: UInt64, totalBytes: UInt64)
    /// Byte-level progress during the active upload phase, emitted at
    /// ~10Hz by the xet upload poll loop.
    case progress(
        bytesCompleted: UInt64,
        totalBytes: UInt64,
        bytesPerSec: Double?,
        transferBytesCompleted: UInt64,
        transferBytes: UInt64,
        transferBytesPerSec: Double?,
        files: [FileProgress]
    )
    /// Fires once, immediately before the commit API call. Signals that
    /// all byte transfer is done; the call itself is silent until
    /// `complete`.
    case committing
    /// Terminal event on success. Not emitted on failure.
    case complete

    init(_ dto: UploadEventDto) {
        self =
            switch dto {
            case .start(let totalFiles, let totalBytes):
                .start(totalFiles: totalFiles, totalBytes: totalBytes)
            case .progress(
                let bytesCompleted,
                let totalBytes,
                let bytesPerSec,
                let transferBytesCompleted,
                let transferBytes,
                let transferBytesPerSec,
                let files
            ):
                .progress(
                    bytesCompleted: bytesCompleted,
                    totalBytes: totalBytes,
                    bytesPerSec: bytesPerSec,
                    transferBytesCompleted: transferBytesCompleted,
                    transferBytes: transferBytes,
                    transferBytesPerSec: transferBytesPerSec,
                    files: files.map(FileProgress.init)
                )
            case .committing:
                .committing
            case .complete:
                .complete
            }
    }
}
