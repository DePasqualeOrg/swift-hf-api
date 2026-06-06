// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// FFI-backed defaults for every required method on ``RepositoryProtocol``.
/// Every concrete repo handle (``ModelRepository``, ``DatasetRepository``)
/// gets the full surface for free – no per-kind extension blocks required.
///
/// Convenience methods built atop these requirements (`fileExists`,
/// `uploadFiles`, `deleteFiles`, `resolveCachedSnapshot`,
/// `resolveCachedFilePath`) live in
/// `HFRepositoryProtocol+Conveniences.swift` and ride on the public
/// protocol instead of this FFI-handle seam.
extension FFIBackedRepository {
    public var owner: String { ffi.owner() }
    public var name: String { ffi.name() }
    public var repoID: String { ffi.repoId() }

    public func exists() async throws -> Bool {
        try await repoExists(ffi)
    }
    public func listTree(
        revision: String? = nil,
        recursive: Bool = false,
        expand: Bool = false,
        limit: Int? = nil
    ) async throws -> [RepoTreeEntry] {
        try await repoListTree(ffi, revision: revision, recursive: recursive, expand: expand, limit: limit)
    }
    public func pathsInfo(
        _ paths: [String],
        revision: String? = nil
    ) async throws -> [RepoTreeEntry] {
        try await repoPathsInfo(ffi, paths: paths, revision: revision)
    }
    public func fileMetadata(
        _ filePath: String,
        revision: String? = nil
    ) async throws -> FileMetadata {
        try await repoFileMetadata(ffi, filePath: filePath, revision: revision)
    }
    public func listCommits(
        revision: String? = nil,
        limit: Int? = nil
    ) async throws -> [GitCommitInfo] {
        try await repoListCommits(ffi, revision: revision, limit: limit)
    }
    public func listRefs(includePullRequests: Bool = false) async throws -> GitRefs {
        try await repoListRefs(ffi, includePullRequests: includePullRequests)
    }
    public func commitDiff(_ compare: String) async throws -> String {
        try await repoCommitDiff(ffi, compare: compare)
    }
    public func rawDiff(_ compare: String) async throws -> String {
        try await repoRawDiff(ffi, compare: compare)
    }
    public func rawDiffEntries(_ compare: String) async throws -> [FileDiff] {
        try await repoRawDiffStream(ffi, compare: compare)
    }
    public func updateSettings(
        private: Bool? = nil,
        gated: GatedApprovalMode? = nil,
        description: String? = nil,
        discussionsDisabled: Bool? = nil,
        gatedNotifications: GatedNotifications? = nil
    ) async throws {
        try await repoUpdateSettings(
            ffi,
            private: `private`,
            gated: gated,
            description: description,
            discussionsDisabled: discussionsDisabled,
            gatedNotifications: gatedNotifications
        )
    }
    public func createBranch(_ branch: String, revision: String? = nil) async throws {
        try await repoCreateBranch(ffi, branch: branch, revision: revision)
    }
    public func deleteBranch(_ branch: String) async throws {
        try await repoDeleteBranch(ffi, branch: branch)
    }
    public func createTag(
        _ tag: String,
        revision: String? = nil,
        message: String? = nil
    ) async throws {
        try await repoCreateTag(ffi, tag: tag, revision: revision, message: message)
    }
    public func deleteTag(_ tag: String) async throws {
        try await repoDeleteTag(ffi, tag: tag)
    }
    @discardableResult
    public func deleteFile(
        _ pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        createPR: Bool = false
    ) async throws -> CommitInfo {
        try await repoDeleteFile(
            ffi,
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            createPR: createPR
        )
    }
    @discardableResult
    public func deleteFolder(
        _ pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        createPR: Bool = false
    ) async throws -> CommitInfo {
        try await repoDeleteFolder(
            ffi,
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            createPR: createPR
        )
    }
    @discardableResult
    public func uploadFile(
        _ file: URL,
        pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil,
        progress: (@Sendable (UploadEvent) -> Void)? = nil
    ) async throws -> CommitInfo {
        try await repoUploadFile(
            ffi,
            source: .path(path: file.path(percentEncoded: false)),
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPR: createPR,
            parentCommit: parentCommit,
            progress: progress
        )
    }
    @discardableResult
    public func uploadFileBytes(
        _ bytes: Data,
        pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil,
        progress: (@Sendable (UploadEvent) -> Void)? = nil
    ) async throws -> CommitInfo {
        try await repoUploadFile(
            ffi,
            source: .bytes(bytes: bytes),
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPR: createPR,
            parentCommit: parentCommit,
            progress: progress
        )
    }
    public func uploadFileStream(
        _ file: URL,
        pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil
    ) -> UploadStream {
        repoUploadFileStream(
            ffi,
            source: .path(path: file.path(percentEncoded: false)),
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPR: createPR,
            parentCommit: parentCommit
        )
    }
    public func uploadFileBytesStream(
        _ bytes: Data,
        pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil
    ) -> UploadStream {
        repoUploadFileStream(
            ffi,
            source: .bytes(bytes: bytes),
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPR: createPR,
            parentCommit: parentCommit
        )
    }
    @discardableResult
    public func uploadFolder(
        _ folder: URL,
        pathInRepo: String? = nil,
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        allowPatterns: [String]? = nil,
        ignorePatterns: [String]? = nil,
        deletePatterns: [String]? = nil,
        progress: (@Sendable (UploadEvent) -> Void)? = nil
    ) async throws -> CommitInfo {
        try await repoUploadFolder(
            ffi,
            folderPath: folder.path(percentEncoded: false),
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPR: createPR,
            allowPatterns: allowPatterns,
            ignorePatterns: ignorePatterns,
            deletePatterns: deletePatterns,
            progress: progress
        )
    }
    public func uploadFolderStream(
        _ folder: URL,
        pathInRepo: String? = nil,
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        allowPatterns: [String]? = nil,
        ignorePatterns: [String]? = nil,
        deletePatterns: [String]? = nil
    ) -> UploadStream {
        repoUploadFolderStream(
            ffi,
            folderPath: folder.path(percentEncoded: false),
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPR: createPR,
            allowPatterns: allowPatterns,
            ignorePatterns: ignorePatterns,
            deletePatterns: deletePatterns
        )
    }
    @discardableResult
    public func createCommit(
        operations: [CommitOperation],
        commitMessage: String,
        commitDescription: String? = nil,
        revision: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil,
        progress: (@Sendable (UploadEvent) -> Void)? = nil
    ) async throws -> CommitInfo {
        try await repoCreateCommit(
            ffi,
            operations: operations,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            revision: revision,
            createPR: createPR,
            parentCommit: parentCommit,
            progress: progress
        )
    }
    public func createCommitStream(
        operations: [CommitOperation],
        commitMessage: String,
        commitDescription: String? = nil,
        revision: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil
    ) -> UploadStream {
        repoCreateCommitStream(
            ffi,
            operations: operations,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            revision: revision,
            createPR: createPR,
            parentCommit: parentCommit
        )
    }
    public func downloadFile(
        _ filename: String,
        revision: String? = nil,
        localDir: URL? = nil,
        forceDownload: Bool = false,
        networkAccess: NetworkAccess = .default,
        progress: (@Sendable (DownloadEvent) -> Void)? = nil
    ) async throws -> URL {
        try await repoDownloadFile(
            ffi,
            filename: filename,
            revision: revision,
            localDir: localDir,
            forceDownload: forceDownload,
            networkAccess: networkAccess,
            progress: progress
        )
    }
    public func downloadFileStream(
        _ filename: String,
        revision: String? = nil,
        localDir: URL? = nil,
        forceDownload: Bool = false,
        networkAccess: NetworkAccess = .default
    ) -> DownloadStream {
        repoDownloadFileStream(
            ffi,
            filename: filename,
            revision: revision,
            localDir: localDir,
            forceDownload: forceDownload,
            networkAccess: networkAccess
        )
    }
    public func downloadFileToBytes(
        _ filename: String,
        revision: String? = nil,
        localDir: URL? = nil,
        forceDownload: Bool = false,
        networkAccess: NetworkAccess = .default,
        progress: (@Sendable (DownloadEvent) -> Void)? = nil
    ) async throws -> Data {
        try await repoDownloadFileToBytes(
            ffi,
            filename: filename,
            revision: revision,
            localDir: localDir,
            forceDownload: forceDownload,
            networkAccess: networkAccess,
            progress: progress
        )
    }
    public func downloadFileBytesStream(
        _ filename: String,
        revision: String? = nil
    ) -> BytesDownloadStream {
        repoDownloadFileBytesStream(
            ffi,
            filename: filename,
            revision: revision
        )
    }
    public func snapshotDownload(
        revision: String? = nil,
        allowPatterns: [String]? = nil,
        ignorePatterns: [String]? = nil,
        localDir: URL? = nil,
        forceDownload: Bool = false,
        networkAccess: NetworkAccess = .default,
        maxWorkers: Int? = nil,
        progress: (@Sendable (DownloadEvent) -> Void)? = nil
    ) async throws -> URL {
        try await repoSnapshotDownload(
            ffi,
            revision: revision,
            allowPatterns: allowPatterns,
            ignorePatterns: ignorePatterns,
            localDir: localDir,
            forceDownload: forceDownload,
            networkAccess: networkAccess,
            maxWorkers: maxWorkers,
            progress: progress
        )
    }

}
