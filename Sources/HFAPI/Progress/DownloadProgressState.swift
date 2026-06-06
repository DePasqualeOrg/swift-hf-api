// Copyright © Anthony DePasquale

import Foundation

/// Running aggregation of a download's progress, fed by ``DownloadEvent``s
/// observed in order on the stream.
///
/// Designed for UI bars that only care about a 0.0–1.0 fraction. Mutate the
/// state with ``observe(_:)`` for each event yielded by
/// ``RepositoryProtocol/snapshotDownload(revision:allowPatterns:ignorePatterns:localDir:forceDownload:networkAccess:maxWorkers:progress:)`` (or any other API that
/// emits ``DownloadEvent``); read ``fractionCompleted`` for display.
///
/// Progress blends whole-file events with Xet transfer bytes. Xet per-file
/// counters move at materialization boundaries, so active Xet progress uses
/// ``DownloadEvent/aggregateProgress(bytesCompleted:totalBytes:bytesPerSec:transferBytesCompleted:transferBytes:transferBytesPerSec:)``'s transfer-byte channel. Cached
/// whole files count when emitted as complete; Xet dedup/cache bytes are not
/// credited upfront. The fraction reaches 100% only after
/// ``DownloadEvent/complete``.
public struct DownloadProgressState: Sendable, Equatable {
    /// Number of files in the operation, as reported by
    /// ``DownloadEvent/start(totalFiles:totalBytes:)``.
    public private(set) var totalFiles: UInt64 = 0
    /// Sum of remote file sizes, as reported by
    /// ``DownloadEvent/start(totalFiles:totalBytes:)``.
    public private(set) var totalBytes: UInt64 = 0
    /// Sum of per-file `bytesCompleted` across every file observed so far.
    /// Snaps to ``totalBytes`` on ``DownloadEvent/complete``.
    public private(set) var bytesCompleted: UInt64 = 0
    /// Whether ``DownloadEvent/complete`` has been observed for the current
    /// operation. Once `true`, ``fractionCompleted`` returns `1.0` even if
    /// the per-file sum hasn't caught up (e.g., cache-hit fast paths that
    /// short-circuit per-file byte deltas).
    public private(set) var isComplete: Bool = false

    /// `0.0…1.0` progress fraction, or `nil` when totals are unknown
    /// (before ``DownloadEvent/start(totalFiles:totalBytes:)`` fires or
    /// when the operation reports `totalBytes == 0`).
    ///
    /// Blended whole-file and Xet transfer fraction, monotonic per operation.
    public var fractionCompleted: Double? {
        if isComplete { return 1.0 }
        guard totalBytes > 0 else { return nil }
        return Double(min(blendedBytes, totalBytes - 1)) / Double(totalBytes)
    }

    /// Per-file `bytesCompleted`, keyed by filename. Surviving state across
    /// ``DownloadEvent/progress(files:)`` deltas; the sum is recomputed on
    /// each update.
    private var fileBytes: [String: UInt64] = [:]
    /// Chunky Xet materialization counter, used only to identify per-file Xet bytes.
    private var aggregateBytesCompleted: UInt64 = 0
    /// Xet payload size from ``DownloadEvent/aggregateProgress(bytesCompleted:totalBytes:bytesPerSec:transferBytesCompleted:transferBytes:transferBytesPerSec:)``.
    private var aggregateTotalBytes: UInt64 = 0
    /// Smooth Xet network bytes received.
    private var aggregateTransferBytesCompleted: UInt64 = 0
    /// Latest nonzero Xet network transfer total; zero can mean "not planned yet".
    private var aggregateTransferBytes: UInt64 = 0
    /// True after the active Xet aggregate stream starts.
    private var hasAggregateProgress = false
    /// Per-file byte total observed before the Xet aggregate stream.
    private var preAggregateFileBytes: UInt64 = 0
    /// Monotonic blended byte count used for display.
    private var blendedBytes: UInt64 = 0

    public init() {}

    /// Fold a single event into the running state. Idempotent for repeat
    /// per-file events – the latest `bytesCompleted` per filename wins.
    ///
    /// Resets ``totalFiles``, ``totalBytes``, ``bytesCompleted``, and
    /// ``isComplete`` whenever ``DownloadEvent/start(totalFiles:totalBytes:)``
    /// fires, so a single accumulator can be reused across multiple
    /// sequential downloads without leaking state.
    public mutating func observe(_ event: DownloadEvent) {
        switch event {
        case .start(let totalFiles, let totalBytes):
            self.totalFiles = totalFiles
            self.totalBytes = totalBytes
            self.bytesCompleted = 0
            self.isComplete = false
            self.fileBytes.removeAll(keepingCapacity: true)
            self.aggregateBytesCompleted = 0
            self.aggregateTotalBytes = 0
            self.aggregateTransferBytesCompleted = 0
            self.aggregateTransferBytes = 0
            self.hasAggregateProgress = false
            self.preAggregateFileBytes = 0
            self.blendedBytes = 0
        case .progress(let files):
            for f in files {
                let prev = fileBytes[f.filename] ?? 0
                fileBytes[f.filename] = max(prev, f.bytesCompleted)
            }
            self.bytesCompleted = fileBytes.values.reduce(0, +)
            if !hasAggregateProgress {
                self.preAggregateFileBytes = max(self.preAggregateFileBytes, self.bytesCompleted)
            }
            recomputeBlend()
        case .aggregateProgress(let bytesCompleted, let totalBytes, _, let transferBytesCompleted, let transferBytes, _):
            if !hasAggregateProgress {
                self.preAggregateFileBytes = max(self.preAggregateFileBytes, self.bytesCompleted)
                self.hasAggregateProgress = true
            }
            self.aggregateBytesCompleted = max(self.aggregateBytesCompleted, bytesCompleted)
            self.aggregateTotalBytes = totalBytes
            self.aggregateTransferBytesCompleted = max(self.aggregateTransferBytesCompleted, transferBytesCompleted)
            self.aggregateTransferBytes = max(self.aggregateTransferBytes, transferBytes)
            recomputeBlend()
        case .complete:
            self.isComplete = true
            self.bytesCompleted = totalBytes
            self.blendedBytes = totalBytes
        }
    }

    /// Recompute display bytes from cached/non-Xet file bytes plus scaled Xet
    /// transfer bytes, excluding Xet materialization bytes to avoid double-counting.
    private mutating func recomputeBlend() {
        let protectedFileBytes = min(preAggregateFileBytes, bytesCompleted)
        let postAggregateFileBytes = bytesCompleted - protectedFileBytes
        let xetMaterializedFileBytes = min(postAggregateFileBytes, aggregateBytesCompleted)
        let countedFileBytes = protectedFileBytes + (postAggregateFileBytes - xetMaterializedFileBytes)
        let transferDrivenXetBytes: UInt64
        if aggregateTransferBytes > 0 {
            let completed = min(aggregateTransferBytesCompleted, aggregateTransferBytes)
            transferDrivenXetBytes = UInt64(
                (Double(completed) / Double(aggregateTransferBytes) * Double(aggregateTotalBytes))
                    .rounded(.down)
            )
        } else {
            transferDrivenXetBytes = 0
        }
        let candidate = min(totalBytes, countedFileBytes + transferDrivenXetBytes)
        blendedBytes = max(blendedBytes, candidate)
    }
}
