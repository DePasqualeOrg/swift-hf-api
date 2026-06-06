// Copyright © Anthony DePasquale

import Foundation

/// Convenience methods written against the public ``RepositoryProtocol``
/// surface. These don't need the FFI handle – every body below calls
/// other protocol requirements (`fileMetadata`, `downloadFile`,
/// `snapshotDownload`, `createCommit`), so the conveniences are available
/// through polymorphic `any RepositoryProtocol` values, not just through
/// the concrete ``ModelRepository`` / ``DatasetRepository`` handles.
extension RepositoryProtocol {
    /// Check whether a file exists on the Hub at the given revision.
    ///
    /// Returns `true` when the Hub successfully serves a HEAD for the
    /// path, `false` when the Hub returns `entryNotFound`. Other failures
    /// (auth, transport, rate-limit) propagate as ``HFError`` – they are
    /// not collapsed into `false`, since "exists but not visible" is
    /// meaningfully different from "does not exist".
    ///
    /// - Parameters:
    ///   - filePath: Path of the file inside the repository.
    ///   - revision: Git revision. Defaults to the main branch.
    public func fileExists(_ filePath: String, revision: String? = nil) async throws -> Bool {
        do {
            _ = try await fileMetadata(filePath, revision: revision)
            return true
        } catch HFError.entryNotFound {
            return false
        }
    }

    /// Resolve a previously downloaded snapshot from the local cache
    /// without contacting the Hub. Returns the snapshot directory URL on a
    /// full cache hit, or `nil` when the cache is empty or incomplete for
    /// the requested file set.
    ///
    /// This is the offline counterpart to ``RepositoryProtocol/snapshotDownload(revision:allowPatterns:ignorePatterns:localDir:forceDownload:networkAccess:maxWorkers:progress:)``:
    /// it succeeds without any network round-trip when every required
    /// blob is already cached. Use it on app launch (or in any code path
    /// that should not block on the network) to bind a UI to a fully
    /// cached model.
    ///
    /// Unlike `snapshotDownload(networkAccess: .bypass)`, missing cache
    /// entries surface as `nil` rather than an ``HFError/localEntryNotFound(path:)``
    /// throw – callers can branch on the optional without try/catch.
    ///
    /// - Parameters:
    ///   - revision: Git revision to resolve. Defaults to the main branch.
    ///   - allowPatterns: Glob patterns selecting which files must be
    ///     cached. When `nil`, every file in the snapshot is required.
    ///   - ignorePatterns: Glob patterns excluding files from the
    ///     completeness check.
    public func resolveCachedSnapshot(
        revision: String? = nil,
        allowPatterns: [String]? = nil,
        ignorePatterns: [String]? = nil
    ) async throws -> URL? {
        do {
            return try await snapshotDownload(
                revision: revision,
                allowPatterns: allowPatterns,
                ignorePatterns: ignorePatterns,
                localDir: nil,
                forceDownload: false,
                networkAccess: .bypass,
                maxWorkers: nil,
                progress: nil
            )
        } catch HFError.localEntryNotFound, HFError.cacheNotEnabled {
            return nil
        }
    }

    /// Resolve a previously downloaded single file from the local cache
    /// without contacting the Hub. Returns the on-disk URL when the file
    /// is fully cached for the requested revision, or `nil` when it is
    /// not. Mirrors the contract of
    /// ``resolveCachedSnapshot(revision:allowPatterns:ignorePatterns:)``
    /// but for one specific file.
    ///
    /// Useful in app-launch fast paths that bind a UI to a single cached
    /// file without blocking on the network.
    ///
    /// - Parameters:
    ///   - filePath: Path of the file inside the repository.
    ///   - revision: Git revision. Defaults to the main branch.
    public func resolveCachedFilePath(
        _ filePath: String,
        revision: String? = nil
    ) async throws -> URL? {
        do {
            return try await downloadFile(
                filePath,
                revision: revision,
                localDir: nil,
                forceDownload: false,
                networkAccess: .bypass,
                progress: nil
            )
        } catch HFError.localEntryNotFound, HFError.cacheNotEnabled {
            return nil
        }
    }

    /// Upload many local files at once, each addressed to its own path in
    /// the repository, in a single commit.
    ///
    /// Convenience wrapper over
    /// ``RepositoryProtocol/createCommit(operations:commitMessage:commitDescription:revision:createPR:parentCommit:progress:)``
    /// for the common "upload a handful of files at arbitrary repo paths"
    /// case. Use ``RepositoryProtocol/uploadFolder(_:pathInRepo:revision:commitMessage:commitDescription:createPR:allowPatterns:ignorePatterns:deletePatterns:progress:)``
    /// when the local layout mirrors the repository layout.
    ///
    /// - Parameters:
    ///   - files: Mapping from `pathInRepo` to the local file URL whose
    ///     bytes should be written. Order is not guaranteed.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message. Defaults to
    ///     `"Upload {N} files"`.
    ///   - commitDescription: Extended description for the commit.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    ///   - parentCommit: Expected parent commit SHA.
    ///   - progress: Optional progress callback. Runs on a tokio worker
    ///     thread; perform UI work on the main actor only after returning.
    @discardableResult
    public func uploadFiles(
        files: [String: URL],
        revision: String? = nil,
        commitMessage: String? = nil,
        commitDescription: String? = nil,
        createPR: Bool = false,
        parentCommit: String? = nil,
        progress: (@Sendable (UploadEvent) -> Void)? = nil
    ) async throws -> CommitInfo {
        let operations = files.map { (path, url) in
            CommitOperation.add(pathInRepo: path, source: .path(url))
        }
        return try await createCommit(
            operations: operations,
            commitMessage: commitMessage ?? "Upload \(files.count) files",
            commitDescription: commitDescription,
            revision: revision,
            createPR: createPR,
            parentCommit: parentCommit,
            progress: progress
        )
    }

    /// Delete many files at once in a single commit.
    ///
    /// Convenience wrapper over
    /// ``RepositoryProtocol/createCommit(operations:commitMessage:commitDescription:revision:createPR:parentCommit:progress:)``
    /// for the common "delete a known list of paths" case. Use
    /// ``RepositoryProtocol/deleteFolder(_:revision:commitMessage:createPR:)`` when every path
    /// under a single prefix should go.
    ///
    /// - Parameters:
    ///   - pathsInRepo: Paths to delete, each relative to the repo root.
    ///   - revision: Branch to commit to. Defaults to the main branch.
    ///   - commitMessage: Commit message. Defaults to
    ///     `"Delete {N} files"`.
    ///   - createPR: When `true`, open a pull request instead of
    ///     committing directly. Defaults to `false`.
    @discardableResult
    public func deleteFiles(
        pathsInRepo: [String],
        revision: String? = nil,
        commitMessage: String? = nil,
        createPR: Bool = false
    ) async throws -> CommitInfo {
        let operations = pathsInRepo.map { CommitOperation.delete(pathInRepo: $0) }
        return try await createCommit(
            operations: operations,
            commitMessage: commitMessage ?? "Delete \(pathsInRepo.count) files",
            commitDescription: nil,
            revision: revision,
            createPR: createPR,
            parentCommit: nil,
            progress: nil
        )
    }
}
