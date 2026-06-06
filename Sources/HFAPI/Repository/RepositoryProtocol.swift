// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Shared surface across ``ModelRepository`` and ``DatasetRepository``.
///
/// Methods that are universal across kinds (`exists`, `listTree`,
/// `pathsInfo`, `fileMetadata`) are required here; kind-specific
/// methods (`info()` returning a different `*Info` struct per kind) stay
/// on the concrete types.
///
/// Mainly useful for code that wants to operate uniformly over a
/// heterogeneous collection of repos. Each repo type's concrete API is
/// independent – you don't need to import this protocol to use them.
///
/// Convenience methods built on top of the required surface
/// (`fileExists`, `uploadFiles`, `deleteFiles`, `resolveCachedSnapshot`,
/// `resolveCachedFilePath`) live as protocol-level defaults in
/// `HFRepositoryProtocol+Conveniences.swift` and are available through
/// any conformer.
///
/// External conformance is technically possible but not a goal: the
/// shared dispatch for every required method lives on an internal
/// sub-protocol (`FFIBackedRepository`) that carries the FFI handle, so
/// a third-party conformer would need to reimplement every requirement
/// itself against its own backend. The protocol exists so that consumers
/// can write code uniform across `ModelRepository` and `DatasetRepository`,
/// not as an extension point.
public protocol RepositoryProtocol: Sendable {
    var owner: String { get }
    var name: String { get }
    var repoID: String { get }

    /// Returns `true` if the repository exists. A 404 from the Hub maps to
    /// `false`. Authentication or authorization errors propagate as
    /// ``HFError`` – they do **not** map to `false`, since "exists but not
    /// visible" is meaningfully different from "does not exist".
    func exists() async throws -> Bool

    /// List files and directories at a revision.
    ///
    /// - Parameters:
    ///   - revision: Git revision to list. Defaults to the main branch.
    ///   - recursive: Traverse subdirectories. Defaults to `false`.
    ///   - expand: Include per-file metadata (size, LFS info, last-commit
    ///     summary). Defaults to `false`.
    ///   - limit: Cap the total number of entries returned.
    func listTree(
        revision: String?,
        recursive: Bool,
        expand: Bool,
        limit: Int?
    ) async throws -> [RepoTreeEntry]

    /// Info about specific paths in the repository. Prefer this over
    /// [`listTree`](listTree(revision:recursive:expand:limit:)) when the
    /// set of paths is known up front.
    func pathsInfo(_ paths: [String], revision: String?) async throws -> [RepoTreeEntry]

    /// Metadata for a single file fetched via a HEAD request. Returns the
    /// resolved commit hash, ETag, file size, and Xet hash without
    /// downloading the content.
    func fileMetadata(_ filePath: String, revision: String?) async throws -> FileMetadata

    /// List commits at a revision. The FFI eagerly drains the underlying
    /// pagination stream – pass `limit` for repositories with long
    /// histories.
    ///
    /// - Parameters:
    ///   - revision: Git revision (branch, tag, or commit SHA). Defaults
    ///     to the main branch.
    ///   - limit: Cap on the total number of commits returned.
    func listCommits(revision: String?, limit: Int?) async throws -> [GitCommitInfo]

    /// List branches, tags, converts, and (optionally) pull-request refs.
    ///
    /// - Parameter includePullRequests: Include pull-request refs.
    ///   Defaults to `false`.
    func listRefs(includePullRequests: Bool) async throws -> GitRefs

    /// The Hub's non-raw compare payload as text. Use
    /// ``rawDiff(_:)`` for raw git-style diff text or
    /// ``rawDiffEntries(_:)`` for parsed per-file entries.
    ///
    /// - Parameter compare: revision spec describing what to compare.
    ///   Either a single revision (compared against its parent) or
    ///   `<base>..<head>` form (two dots).
    func commitDiff(_ compare: String) async throws -> String

    /// Raw diff payload between two revisions as a string.
    ///
    /// - Parameter compare: revision spec, single revision or
    ///   `<base>..<head>`.
    func rawDiff(_ compare: String) async throws -> String

    /// Raw diff between two revisions, parsed into per-file entries.
    ///
    /// The FFI eagerly drains the underlying parser into an array; the
    /// method is not an `AsyncSequence` despite the parser being
    /// stream-shaped on the Rust side. Use this when you want the parsed
    /// entries; use ``rawDiff(_:)`` for the unparsed text body.
    ///
    /// - Parameter compare: revision spec, single revision or
    ///   `<base>..<head>`.
    func rawDiffEntries(_ compare: String) async throws -> [FileDiff]

    /// Update repository settings. Each parameter is optional – passing
    /// `nil` leaves the corresponding setting untouched on the Hub. The
    /// underlying endpoint is `PUT /api/{plural}/{repo_id}/settings`.
    ///
    /// - Parameters:
    ///   - private: Whether the repository should be private. Mirrors the
    ///     Hub's JSON field name; the read-side property is exposed as
    ///     `isPrivate` (Swift Bool-property convention).
    ///   - gated: Access-gating mode for the repository.
    ///   - description: Repository description shown on the Hub page.
    ///   - discussionsDisabled: Whether discussions are disabled.
    ///   - gatedNotifications: Notification preferences for gated-access requests.
    func updateSettings(
        private: Bool?,
        gated: GatedApprovalMode?,
        description: String?,
        discussionsDisabled: Bool?,
        gatedNotifications: GatedNotifications?
    ) async throws

    /// Create a branch on this repository.
    ///
    /// - Parameters:
    ///   - branch: Name of the branch to create.
    ///   - revision: Revision to branch from. Defaults to the current main
    ///     branch head.
    func createBranch(_ branch: String, revision: String?) async throws

    /// Delete a branch from this repository.
    ///
    /// - Parameter branch: Name of the branch to delete.
    func deleteBranch(_ branch: String) async throws

    /// Create a tag on this repository.
    ///
    /// - Parameters:
    ///   - tag: Name of the tag to create.
    ///   - revision: Revision to tag. Defaults to the current main branch
    ///     head.
    ///   - message: Annotation message for the tag.
    func createTag(_ tag: String, revision: String?, message: String?) async throws

    /// Delete a tag from this repository.
    ///
    /// - Parameter tag: Name of the tag to delete.
    func deleteTag(_ tag: String) async throws

    /// Delete a file from this repository in a single-op commit.
    ///
    /// - Parameters:
    ///   - pathInRepo: Path of the file to delete, relative to the repo root.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message. Defaults to `"Delete {path}"`.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    @discardableResult
    func deleteFile(
        _ pathInRepo: String,
        revision: String?,
        commitMessage: String?,
        createPR: Bool
    ) async throws -> CommitInfo

    /// Delete every file under a folder in a single commit.
    ///
    /// The current tree is listed recursively and every file at or below
    /// `pathInRepo` becomes a delete operation; directories disappear as a
    /// consequence of deleting their contents.
    ///
    /// - Parameters:
    ///   - pathInRepo: Folder path within the repository.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    @discardableResult
    func deleteFolder(
        _ pathInRepo: String,
        revision: String?,
        commitMessage: String?,
        createPR: Bool
    ) async throws -> CommitInfo

    /// Upload a single file (read from a local path) to this repository
    /// in a one-op commit.
    ///
    /// The local file is not snapshotted – it must still exist, unchanged,
    /// when the underlying commit runs.
    ///
    /// - Parameters:
    ///   - file: Local file URL to read content from at commit time.
    ///   - pathInRepo: Destination path within the repository.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message. Defaults to `"Upload {path}"`.
    ///   - commitDescription: Extended description for the commit.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    ///   - parentCommit: Expected parent commit SHA. Fails if the branch
    ///     head moved past it.
    ///   - progress: Optional progress callback. Runs on a tokio worker
    ///     thread; perform UI work on the main actor only after returning.
    @discardableResult
    func uploadFile(
        _ file: URL,
        pathInRepo: String,
        revision: String?,
        commitMessage: String?,
        commitDescription: String?,
        createPR: Bool,
        parentCommit: String?,
        progress: (@Sendable (UploadEvent) -> Void)?
    ) async throws -> CommitInfo

    /// Upload an in-memory buffer to this repository as a single file.
    ///
    /// - Parameters:
    ///   - bytes: File body to upload.
    ///   - pathInRepo: Destination path within the repository.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message. Defaults to `"Upload {path}"`.
    ///   - commitDescription: Extended description for the commit.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    ///   - parentCommit: Expected parent commit SHA.
    ///   - progress: Optional progress callback.
    @discardableResult
    func uploadFileBytes(
        _ bytes: Data,
        pathInRepo: String,
        revision: String?,
        commitMessage: String?,
        commitDescription: String?,
        createPR: Bool,
        parentCommit: String?,
        progress: (@Sendable (UploadEvent) -> Void)?
    ) async throws -> CommitInfo

    /// Upload a single file with progress streamed as a sequence of
    /// ``UploadEvent`` values. The returned ``UploadStream`` is an
    /// `AsyncSequence`; await ``UploadStream/value`` for the resulting
    /// ``CommitInfo``. Breaking out of the event iteration fires the
    /// cancellation handle through to the underlying upload.
    func uploadFileStream(
        _ file: URL,
        pathInRepo: String,
        revision: String?,
        commitMessage: String?,
        commitDescription: String?,
        createPR: Bool,
        parentCommit: String?
    ) -> UploadStream

    /// Upload an in-memory buffer with progress streamed via an
    /// `AsyncThrowingStream`. See ``RepositoryProtocol/uploadFileStream(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:)``
    /// for the cancellation contract.
    func uploadFileBytesStream(
        _ bytes: Data,
        pathInRepo: String,
        revision: String?,
        commitMessage: String?,
        commitDescription: String?,
        createPR: Bool,
        parentCommit: String?
    ) -> UploadStream

    /// Recursively upload every file under a local folder in a single
    /// commit.
    ///
    /// - Parameters:
    ///   - folder: Local folder URL to upload from. Must exist when the
    ///     commit runs.
    ///   - pathInRepo: Destination directory within the repository.
    ///     Defaults to the repository root.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message.
    ///   - commitDescription: Extended description for the commit.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    ///   - allowPatterns: Globs selecting which local files to include.
    ///     Matched against each file's path relative to `folder`
    ///     (not the absolute path and not prefixed with `pathInRepo`).
    ///     When set, only files matching at least one pattern are
    ///     uploaded.
    ///   - ignorePatterns: Globs of local files to skip. Matched against
    ///     the same `folder`-relative paths as `allowPatterns`.
    ///   - deletePatterns: Globs of *remote* files to delete in the same
    ///     commit. Matched against existing repository paths relative to
    ///     repo root (**not** relative to `pathInRepo`).
    ///   - progress: Optional progress callback. Runs on a tokio worker
    ///     thread; perform UI work on the main actor only after returning.
    @discardableResult
    func uploadFolder(
        _ folder: URL,
        pathInRepo: String?,
        revision: String?,
        commitMessage: String?,
        commitDescription: String?,
        createPR: Bool,
        allowPatterns: [String]?,
        ignorePatterns: [String]?,
        deletePatterns: [String]?,
        progress: (@Sendable (UploadEvent) -> Void)?
    ) async throws -> CommitInfo

    /// Recursively upload a folder with progress streamed via an
    /// `AsyncThrowingStream`. See
    /// ``RepositoryProtocol/uploadFileStream(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:)``
    /// for the cancellation contract; `uploadFolderStream` follows the
    /// same shape and reuses ``UploadStream``.
    func uploadFolderStream(
        _ folder: URL,
        pathInRepo: String?,
        revision: String?,
        commitMessage: String?,
        commitDescription: String?,
        createPR: Bool,
        allowPatterns: [String]?,
        ignorePatterns: [String]?,
        deletePatterns: [String]?
    ) -> UploadStream

    /// Lowest-level mutation primitive – apply an arbitrary mix of add and
    /// delete operations in a single commit. Mirrors
    /// `hf_hub::HFRepository::create_commit`.
    ///
    /// For one-shot workflows, prefer the convenience wrappers
    /// (``RepositoryProtocol/uploadFile(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:progress:)``,
    /// ``RepositoryProtocol/uploadFolder(_:pathInRepo:revision:commitMessage:commitDescription:createPR:allowPatterns:ignorePatterns:deletePatterns:progress:)``,
    /// ``RepositoryProtocol/deleteFile(_:revision:commitMessage:createPR:)``,
    /// ``RepositoryProtocol/deleteFolder(_:revision:commitMessage:createPR:)``).
    ///
    /// - Parameters:
    ///   - operations: ``CommitOperation`` entries to land in the commit.
    ///   - commitMessage: Required commit message.
    ///   - commitDescription: Extended description for the commit.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    ///   - parentCommit: Expected parent commit SHA. Fails if the branch
    ///     head moved past it.
    ///   - progress: Optional progress callback. Runs on a tokio worker
    ///     thread; perform UI work on the main actor only after returning.
    @discardableResult
    func createCommit(
        operations: [CommitOperation],
        commitMessage: String,
        commitDescription: String?,
        revision: String?,
        createPR: Bool,
        parentCommit: String?,
        progress: (@Sendable (UploadEvent) -> Void)?
    ) async throws -> CommitInfo

    /// Streaming variant of ``RepositoryProtocol/createCommit(operations:commitMessage:commitDescription:revision:createPR:parentCommit:progress:)``.
    /// Returns an ``UploadStream``; await ``UploadStream/value`` for the
    /// resulting ``CommitInfo``. See ``RepositoryProtocol/uploadFileStream(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:)``
    /// for the cancellation contract.
    func createCommitStream(
        operations: [CommitOperation],
        commitMessage: String,
        commitDescription: String?,
        revision: String?,
        createPR: Bool,
        parentCommit: String?
    ) -> UploadStream

    /// Download a single file from the repository into the local cache.
    /// Available on every repository kind – `hf_hub`'s download builders
    /// are generic over `RepoType`.
    ///
    /// - Parameters:
    ///   - filename: Path of the file inside the repository.
    ///   - revision: Git revision (branch, tag, or commit SHA). Defaults to
    ///     the main branch.
    ///   - localDir: Local directory to install the file into. When `nil`
    ///     (default), the file lands in the Hub cache.
    ///   - forceDownload: Re-download even if a cached copy exists.
    ///   - networkAccess: Controls cache vs. network resolution. Defaults
    ///     to ``NetworkAccess/default``.
    ///   - progress: Optional progress callback. Runs on a tokio worker
    ///     thread; perform UI work on the main actor only after returning.
    /// - Returns: The on-disk URL of the downloaded blob.
    func downloadFile(
        _ filename: String,
        revision: String?,
        localDir: URL?,
        forceDownload: Bool,
        networkAccess: NetworkAccess,
        progress: (@Sendable (DownloadEvent) -> Void)?
    ) async throws -> URL

    /// Download a file with progress streamed as a sequence of
    /// ``DownloadEvent`` values. The returned ``DownloadStream`` is an
    /// `AsyncSequence`; await ``DownloadStream/value`` for the on-disk URL.
    /// Breaking out of the event iteration fires the cancellation handle
    /// through to the underlying download.
    func downloadFileStream(
        _ filename: String,
        revision: String?,
        localDir: URL?,
        forceDownload: Bool,
        networkAccess: NetworkAccess
    ) -> DownloadStream

    /// Download a file into memory and return its contents as `Data`.
    /// The bytes are read from the local cache after the file finishes
    /// downloading; use ``downloadFileBytesStream(_:revision:)``
    /// when chunk-by-chunk consumption matters.
    ///
    /// **Peak memory:** this method allocates a `Data` the full size of
    /// the file in addition to the on-disk cached copy. For multi-GB
    /// shards the resident-memory cost equals the file size for the
    /// duration of the read. Use the streaming variant if RAM is bounded
    /// or the file is larger than a few hundred MB.
    func downloadFileToBytes(
        _ filename: String,
        revision: String?,
        localDir: URL?,
        forceDownload: Bool,
        networkAccess: NetworkAccess,
        progress: (@Sendable (DownloadEvent) -> Void)?
    ) async throws -> Data

    /// Download a file and stream its bytes chunk-by-chunk via a
    /// ``BytesDownloadStream``. The stream is an `AsyncSequence` of `Data`
    /// chunks; ``BytesDownloadStream/contentLength`` resolves to the
    /// server-reported total when `Content-Length` is present. Breaking
    /// out of the chunk iteration cancels the underlying download.
    ///
    /// `forceDownload` is intentionally not exposed – the streaming path
    /// bypasses the on-disk cache, so there is nothing for the flag to
    /// override.
    func downloadFileBytesStream(
        _ filename: String,
        revision: String?
    ) -> BytesDownloadStream

    /// Download a snapshot of every selected file at a resolved revision.
    /// Returns the snapshot directory URL.
    ///
    /// `allowPatterns` and `ignorePatterns` use globset syntax (`*`, `?`,
    /// `**`, character classes) and are matched against each candidate
    /// file's repository path (forward-slash-joined, relative to the repo
    /// root).
    ///
    /// - Parameters:
    ///   - revision: Git revision (branch, tag, or commit SHA). Defaults
    ///     to the main branch.
    ///   - allowPatterns: Globs selecting files to include.
    ///   - ignorePatterns: Globs of files to skip.
    ///   - localDir: Local directory to install the snapshot into. When
    ///     `nil` (default), the snapshot lands in the Hub cache and is
    ///     symlinked under `snapshots/{revision}/`.
    ///   - forceDownload: Re-download every file even if a cached copy
    ///     exists.
    ///   - networkAccess: Controls cache vs. network resolution. Defaults
    ///     to ``NetworkAccess/default``.
    ///   - maxWorkers: Maximum number of concurrent file downloads.
    ///   - progress: Optional progress callback.
    func snapshotDownload(
        revision: String?,
        allowPatterns: [String]?,
        ignorePatterns: [String]?,
        localDir: URL?,
        forceDownload: Bool,
        networkAccess: NetworkAccess,
        maxWorkers: Int?,
        progress: (@Sendable (DownloadEvent) -> Void)?
    ) async throws -> URL
}
