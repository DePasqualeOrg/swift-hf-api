// Copyright © Anthony DePasquale

import Foundation

/// Default-argument overloads for every required method on
/// ``RepositoryProtocol`` so that consumers holding `any RepositoryProtocol`
/// keep the same call-site ergonomics as direct ``ModelRepository`` /
/// ``DatasetRepository`` users.
///
/// The protocol requirements themselves cannot carry default values
/// (Swift forbids it). The conforming type's extension on
/// `FFIBackedRepository` provides defaults too – those win for direct
/// concrete-type calls via static dispatch. The overloads here cover the
/// dynamic-dispatch path: `(any RepositoryProtocol).listTree()` resolves
/// to the extension method below, which forwards to the witness through
/// the protocol requirement's strict signature.
extension RepositoryProtocol {
    public func listTree(
        revision: String? = nil,
        recursive: Bool = false,
        expand: Bool = false,
        limit: Int? = nil
    ) async throws -> [RepoTreeEntry] {
        try await listTree(revision: revision, recursive: recursive, expand: expand, limit: limit)
    }

    public func pathsInfo(
        _ paths: [String],
        revision: String? = nil
    ) async throws -> [RepoTreeEntry] {
        try await pathsInfo(paths, revision: revision)
    }

    public func fileMetadata(
        _ filePath: String,
        revision: String? = nil
    ) async throws -> FileMetadata {
        try await fileMetadata(filePath, revision: revision)
    }

    public func listCommits(
        revision: String? = nil,
        limit: Int? = nil
    ) async throws -> [GitCommitInfo] {
        try await listCommits(revision: revision, limit: limit)
    }

    public func listRefs(includePullRequests: Bool = false) async throws -> GitRefs {
        try await listRefs(includePullRequests: includePullRequests)
    }

    public func updateSettings(
        private: Bool? = nil,
        gated: GatedApprovalMode? = nil,
        description: String? = nil,
        discussionsDisabled: Bool? = nil,
        gatedNotifications: GatedNotifications? = nil
    ) async throws {
        try await updateSettings(
            private: `private`,
            gated: gated,
            description: description,
            discussionsDisabled: discussionsDisabled,
            gatedNotifications: gatedNotifications
        )
    }

    public func createBranch(_ branch: String, revision: String? = nil) async throws {
        try await createBranch(branch, revision: revision)
    }

    public func createTag(
        _ tag: String,
        revision: String? = nil,
        message: String? = nil
    ) async throws {
        try await createTag(tag, revision: revision, message: message)
    }

    @discardableResult
    public func deleteFile(
        _ pathInRepo: String,
        revision: String? = nil,
        commitMessage: String? = nil,
        createPR: Bool = false
    ) async throws -> CommitInfo {
        try await deleteFile(
            pathInRepo,
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
        try await deleteFolder(
            pathInRepo,
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
        try await uploadFile(
            file,
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
        try await uploadFileBytes(
            bytes,
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
        uploadFileStream(
            file,
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
        uploadFileBytesStream(
            bytes,
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
        try await uploadFolder(
            folder,
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
        uploadFolderStream(
            folder,
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
        try await createCommit(
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
        createCommitStream(
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
        try await downloadFile(
            filename,
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
        downloadFileStream(
            filename,
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
        try await downloadFileToBytes(
            filename,
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
        downloadFileBytesStream(filename, revision: revision)
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
        try await snapshotDownload(
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
