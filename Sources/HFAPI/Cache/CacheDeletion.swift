// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Plan for removing one or more cached revisions from the local Hugging
/// Face cache. Returned by ``CacheInfo/deleteRevisions(_:)-([String])``
/// (and its variadic / repo-scoped variants); apply the plan with
/// ``execute()``.
///
/// Inspect ``expectedFreedSize``, ``blobs``, ``snapshots``, ``refs``,
/// ``repos``, ``locks``, and ``missingRevisions`` to drive a "free 8.6 GB?"
/// confirmation UI before committing to the deletion.
public struct DeleteCacheStrategy: Sendable, Equatable, Hashable {
    /// Total bytes that will be freed once ``execute()`` runs successfully.
    /// Approximates `du` on the targeted blobs — does not include lock or
    /// `.no_exist` cleanup, which `execute` performs but cannot pre-size.
    public let expectedFreedSize: UInt64

    /// Individual blob files under `<repo>/blobs/` to remove. A blob is
    /// only listed if no surviving revision in the same repo still points
    /// to it.
    public let blobs: Set<URL>

    /// `<repo>/refs/<name>` files for revisions being deleted.
    public let refs: Set<URL>

    /// Full repo directories to remove when every revision of the repo is
    /// being deleted (cleaner than wiping blobs/refs/snapshots one by one).
    public let repos: Set<URL>

    /// `<repo>/snapshots/<commit>/` directories for individual revisions
    /// being deleted (when other revisions of the same repo survive).
    public let snapshots: Set<URL>

    /// `<cacheDir>/.locks/<repoFolder>/` directories whose blobs are being
    /// fully removed (whole-repo deletion only — orphan locks are safe to
    /// wipe once the corresponding blobs are gone). Empty for per-revision
    /// deletions, where other revisions may still need the locks.
    public let locks: Set<URL>

    /// Commit hashes the caller asked to delete that weren't found in
    /// the cache. Informational; deletion proceeds for the hashes that
    /// were found.
    public let missingRevisions: [String]

    /// Underlying FFI snapshot of the strategy. Retained verbatim so
    /// ``execute()`` can hand the same paths back to Rust without losing
    /// information through the URL ↔ string round-trip.
    fileprivate let rawDTO: DeleteCacheStrategyDto

    fileprivate init(_ dto: DeleteCacheStrategyDto) {
        self.expectedFreedSize = dto.expectedFreedSize
        self.blobs = Set(dto.blobs.map { URL(fileURLWithPath: $0) })
        self.refs = Set(dto.refs.map { URL(fileURLWithPath: $0) })
        self.repos = Set(dto.repos.map { URL(fileURLWithPath: $0) })
        self.snapshots = Set(dto.snapshots.map { URL(fileURLWithPath: $0) })
        self.locks = Set(dto.locks.map { URL(fileURLWithPath: $0) })
        self.missingRevisions = dto.missingRevisions
        self.rawDTO = dto
    }

    /// Apply the plan. Returns per-path failures rather than aborting on
    /// the first error — the cache should never end up half-deleted because
    /// a single stale lock file failed to remove.
    ///
    /// Idempotent: re-executing a strategy whose paths have already been
    /// removed reports each path as a not-found ``ExecuteResult/Failure``
    /// entry in ``ExecuteResult/failures``.
    @discardableResult
    public func execute() throws -> ExecuteResult {
        do {
            let dto = try executeDeleteCacheStrategy(strategy: rawDTO)
            return ExecuteResult(dto)
        } catch let error as CacheDeletionErrorFfi {
            throw HFCacheDeletionError(ffi: error)
        }
    }
}

/// Per-path outcome of ``DeleteCacheStrategy/execute()``. Successful paths
/// produce no entry; tolerated failures (`notFound`, `permission`) populate
/// ``failures``; unexpected errors throw out of `execute()` instead.
public struct ExecuteResult: Sendable {
    public let failures: [Failure]

    public struct Failure: Sendable {
        public let path: URL
        public let kind: PathKind
        public let error: Error
    }

    /// Which deletion phase a ``Failure/path`` came from. Mirrors the order
    /// `execute()` removes things in (`repos → snapshots → refs → blobs →
    /// locks`).
    public enum PathKind: Sendable { case repo, snapshot, ref, blob, locks }

    fileprivate init(_ dto: ExecuteResultDto) {
        self.failures = dto.failures.map { Failure($0) }
    }
}

extension ExecuteResult.Failure {
    fileprivate init(_ dto: FailureDto) {
        self.path = URL(fileURLWithPath: dto.path)
        self.kind = ExecuteResult.PathKind(dto.kind)
        self.error = HFCacheDeletionError.pathRemovalFailed(message: dto.message)
    }
}

extension ExecuteResult.PathKind {
    fileprivate init(_ dto: PathKindDto) {
        self =
            switch dto {
            case .repo: .repo
            case .snapshot: .snapshot
            case .ref: .ref
            case .blob: .blob
            case .locks: .locks
            }
    }
}

/// Non-tolerated error surfaced from ``DeleteCacheStrategy/execute()``. A
/// `notFound`/`permissionDenied` outcome at the individual-path level lands
/// in ``ExecuteResult/failures`` instead.
public enum HFCacheDeletionError: Error, LocalizedError, Sendable {
    case ioError(message: String)
    case pathRemovalFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .ioError(let message), .pathRemovalFailed(let message):
            message
        }
    }

    fileprivate init(ffi: CacheDeletionErrorFfi) {
        switch ffi {
        case .Io(let message):
            self = .ioError(message: message)
        }
    }
}

extension CacheInfo {
    /// Plan the deletion of one or more cached revisions by commit hash.
    ///
    /// Hashes not found in the cache are returned in
    /// ``DeleteCacheStrategy/missingRevisions`` rather than throwing —
    /// callers can surface these to the user without aborting the rest of
    /// the deletion.
    public func deleteRevisions(_ commitHashes: String...) -> DeleteCacheStrategy {
        deleteRevisions(commitHashes)
    }

    /// Array form of ``deleteRevisions(_:)-(String...)``.
    public func deleteRevisions(_ commitHashes: [String]) -> DeleteCacheStrategy {
        let dto = computeDeleteCacheStrategy(cacheInfo: rawDTO, commitHashes: commitHashes)
        return DeleteCacheStrategy(dto)
    }

    /// Plan the deletion of every cached revision of a given repository.
    ///
    /// Convenience over ``deleteRevisions(_:)-([String])`` that
    /// resolves a repository ID + type to its full list of commit hashes
    /// and returns the resulting strategy. Returns `nil` if no matching
    /// repo is cached.
    public func deleteRepository(_ repoId: RepositoryID, type: RepoType) -> DeleteCacheStrategy? {
        guard let repo = cachedRepo(repoId, type: type) else { return nil }
        return deleteRevisions(repo.revisions.map(\.commitHash))
    }
}
