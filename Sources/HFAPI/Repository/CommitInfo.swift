// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI
import HFAPIShared

/// Result returned after a commit-creating operation (upload, delete,
/// or `createCommit`). Mirrors `hf_hub::repository::CommitInfo`.
///
/// All fields are optional because the Hub may omit any of them in the
/// response – most commonly `prURL` and `prNumber` are present only when
/// `createPR` was set on the underlying call.
public struct CommitInfo: Sendable, Equatable, Hashable {
    /// URL of the created commit on the Hub. `nil` when the Hub omits the
    /// field; a non-empty but malformed Hub-side value also falls through
    /// to `nil` and is logged via `HFLog` from `HFAPIShared`.
    public let commitURL: URL?
    /// Commit message recorded for the operation.
    public let commitMessage: String?
    /// Commit description/body, when provided.
    public let commitDescription: String?
    /// Commit SHA.
    public let commitOID: String?
    /// Pull-request URL, when `createPR` was enabled and a PR was opened.
    /// Same parsing tolerance as ``commitURL``.
    public let prURL: URL?
    /// Pull-request number, when `createPR` was enabled and a PR was opened.
    public let prNumber: UInt64?

    init(_ dto: CommitInfoDto) {
        self.commitURL = parseCommitURL(dto.commitUrl, field: "commitUrl")
        self.commitMessage = dto.commitMessage
        self.commitDescription = dto.commitDescription
        self.commitOID = dto.commitOid
        self.prURL = parseCommitURL(dto.prUrl, field: "prUrl")
        self.prNumber = dto.prNum
    }
}

/// Parse a Hub-supplied URL string. Returns `nil` for both "field absent"
/// and "field present but malformed", but warns via ``HFLog`` for the
/// latter so the asymmetry isn't silent. Logging is appropriate here
/// because each `CommitInfo` arrives on a single mutation – not the
/// 1000-entry listings ``parseHubTimestamp(_:)`` handles, where the same
/// log policy would mean 1000 warnings per request.
private func parseCommitURL(_ raw: String?, field: String) -> URL? {
    guard let raw, !raw.isEmpty else { return nil }
    if let url = URL(string: raw) { return url }
    commitURLLogger.warning(
        "CommitInfo.\(field): rejected non-empty value \(raw) – not a valid URL"
    )
    return nil
}

private let commitURLLogger = HFLog(
    subsystem: "co.huggingface.swift-hf-api",
    category: "CommitInfo"
)
