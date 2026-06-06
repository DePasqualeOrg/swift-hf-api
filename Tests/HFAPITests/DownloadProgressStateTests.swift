// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

@Suite("DownloadProgressState")
struct DownloadProgressStateTests {
    @Test("fractionCompleted is nil before Start")
    func nilBeforeStart() {
        let state = DownloadProgressState()
        #expect(state.fractionCompleted == nil)
    }

    @Test("Start sets totals but leaves bytesCompleted at zero")
    func startSetsTotals() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 3, totalBytes: 1000))
        #expect(state.totalFiles == 3)
        #expect(state.totalBytes == 1000)
        #expect(state.bytesCompleted == 0)
        #expect(state.fractionCompleted == 0.0)
        #expect(state.isComplete == false)
    }

    @Test("fractionCompleted is nil when totalBytes is zero")
    func nilWhenTotalIsZero() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 0))
        #expect(state.fractionCompleted == nil)
    }

    @Test("Progress deltas accumulate per file")
    func accumulatesPerFile() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 2, totalBytes: 1000))
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 200, totalBytes: 500, status: .inProgress)
            ])
        )
        #expect(state.bytesCompleted == 200)
        state.observe(
            .progress(files: [
                FileProgress(filename: "b.bin", bytesCompleted: 300, totalBytes: 500, status: .inProgress)
            ])
        )
        #expect(state.bytesCompleted == 500)
        #expect(state.fractionCompleted == 0.5)
    }

    @Test("Subsequent Progress events for the same file replace prior values")
    func replacesPerFileState() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 200, totalBytes: 1000, status: .inProgress)
            ])
        )
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 700, totalBytes: 1000, status: .inProgress)
            ])
        )
        #expect(state.bytesCompleted == 700)
        #expect(state.fractionCompleted == 0.7)
    }

    @Test("AggregateProgress in sync with per-file events does not double-count")
    func aggregateInSyncDoesNotDoubleCount() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        state.observe(
            .aggregateProgress(
                bytesCompleted: 400,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 400,
                transferBytes: 1000,
                transferBytesPerSec: nil
            )
        )
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 400, totalBytes: 1000, status: .inProgress)
            ])
        )
        #expect(state.bytesCompleted == 400)
        #expect(state.fractionCompleted == 0.4)
    }

    @Test("AggregateProgress.transferBytes ahead of per-file emit smooths fractionCompleted")
    func aggregateTransferSmoothsFraction() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        // Transfer can move before the next Xet materialization event.
        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 300,
                transferBytes: 1000,
                transferBytesPerSec: nil
            )
        )
        #expect(state.bytesCompleted == 0)
        #expect(state.fractionCompleted == 0.3)
    }

    @Test("Zero transfer total is not treated as a full cache hit")
    func zeroTransferTotalDoesNotCreditWholeXetPayload() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        // Zero transferBytes means unknown, not fully cached.
        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 0,
                transferBytes: 0,
                transferBytesPerSec: nil
            )
        )
        #expect(state.fractionCompleted == 0.0)
    }

    @Test("Zero transfer total after planning does not discard the transfer denominator")
    func zeroTransferTotalAfterPlanningDoesNotDiscardDenominator() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 250,
                transferBytes: 1000,
                transferBytesPerSec: nil
            )
        )
        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 500,
                transferBytes: 0,
                transferBytesPerSec: nil
            )
        )
        #expect(state.fractionCompleted == 0.5)
    }

    @Test("Chunky aggregate disk progress does not drive the displayed fraction")
    func aggregateDiskProgressDoesNotDriveFraction() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        // Materialization alone must not produce an immediate 99% UI state.
        state.observe(
            .aggregateProgress(
                bytesCompleted: 1000,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 0,
                transferBytes: 0,
                transferBytesPerSec: nil
            )
        )
        #expect(state.fractionCompleted == 0.0)
    }

    @Test("Per-file Progress catching up to aggregate does not move fraction backwards")
    func blendIsMonotonicAcrossXorbBoundary() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        // Transfer leads per-file progress.
        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 500,
                transferBytes: 1000,
                transferBytesPerSec: nil
            )
        )
        let after1 = state.fractionCompleted
        // Materialization arrives before the matching per-file event.
        state.observe(
            .aggregateProgress(
                bytesCompleted: 500,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 500,
                transferBytes: 1000,
                transferBytesPerSec: nil
            )
        )
        let after2 = state.fractionCompleted
        // Matching per-file event arrives.
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 500, totalBytes: 1000, status: .inProgress)
            ])
        )
        let after3 = state.fractionCompleted

        #expect(after1 == 0.5)
        #expect(after2 == 0.5, "blend must not regress when aggregate disk counter catches transfer")
        #expect(after3 == 0.5)
    }

    @Test("Xet transfer dedup does not get an upfront whole-payload credit")
    func xetTransferDedupDoesNotCreditUpfront() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        // Dedup reduces wire bytes, but should not create upfront progress.
        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 0,
                transferBytes: 700,
                transferBytesPerSec: nil
            )
        )
        #expect(state.fractionCompleted == 0.0)

        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 350,
                transferBytes: 700,
                transferBytesPerSec: nil
            )
        )
        // Half of the active transfer maps to half of the Xet payload.
        #expect(state.fractionCompleted == 0.5)

        state.observe(
            .aggregateProgress(
                bytesCompleted: 0,
                totalBytes: 1000,
                bytesPerSec: nil,
                transferBytesCompleted: 700,
                transferBytes: 700,
                transferBytesPerSec: nil
            )
        )
        // Reserve exact 100% for .complete.
        #expect(state.fractionCompleted == 0.999)

        state.observe(.complete)
        #expect(state.fractionCompleted == 1.0)
    }

    @Test("Whole cached files count upfront before active xet transfer")
    func wholeCachedFilesCountUpfront() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 2, totalBytes: 1000))
        state.observe(
            .progress(files: [
                FileProgress(filename: "cached.safetensors", bytesCompleted: 300, totalBytes: 300, status: .complete)
            ])
        )
        #expect(state.fractionCompleted == 0.3)

        state.observe(
            .aggregateProgress(
                bytesCompleted: 350,
                totalBytes: 700,
                bytesPerSec: nil,
                transferBytesCompleted: 350,
                transferBytes: 700,
                transferBytesPerSec: nil
            )
        )
        // 300 cached whole-file bytes + 350 active Xet bytes.
        #expect(state.fractionCompleted == 0.65)
    }

    @Test("Per-file bytesCompleted is clamped to be non-decreasing per filename")
    func perFileClampedNonDecreasing() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 600, totalBytes: 1000, status: .inProgress)
            ])
        )
        // Per-file regressions should be ignored.
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 500, totalBytes: 1000, status: .complete)
            ])
        )
        #expect(state.bytesCompleted == 600)
    }

    @Test("Complete snaps fractionCompleted to 1.0 even if per-file events lag")
    func completeForcesFullFraction() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 1000))
        // Simulate a cache-hit fast path that never emitted intermediate
        // per-file byte deltas.
        state.observe(.complete)
        #expect(state.isComplete == true)
        #expect(state.bytesCompleted == 1000)
        #expect(state.fractionCompleted == 1.0)
    }

    @Test("Start resets prior state for accumulator reuse")
    func startResetsPriorState() {
        var state = DownloadProgressState()
        state.observe(.start(totalFiles: 1, totalBytes: 500))
        state.observe(
            .progress(files: [
                FileProgress(filename: "a.bin", bytesCompleted: 500, totalBytes: 500, status: .complete)
            ])
        )
        state.observe(.complete)

        state.observe(.start(totalFiles: 2, totalBytes: 2000))
        #expect(state.totalBytes == 2000)
        #expect(state.bytesCompleted == 0)
        #expect(state.isComplete == false)
        #expect(state.fractionCompleted == 0.0)
    }
}
