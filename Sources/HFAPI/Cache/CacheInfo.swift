// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// A single file in a cached revision.
///
/// Mirrors `hf_hub::cache::CachedFileInfo`. ``filePath`` is the pointer in
/// the `snapshots/` tree (a symlink on Unix); ``blobPath`` is the canonical
/// location of the underlying content under `blobs/`. Both refer to the
/// same bytes – multiple revisions of the same repo can share a blob.
public struct CachedFileInfo: Sendable, Equatable, Hashable {
    public let fileName: String
    public let filePath: URL
    public let blobPath: URL
    public let sizeOnDisk: UInt64
    public let blobLastAccessed: Date
    public let blobLastModified: Date

    init(_ dto: CachedFileInfoDto) {
        self.fileName = dto.fileName
        self.filePath = URL(fileURLWithPath: dto.filePath)
        self.blobPath = URL(fileURLWithPath: dto.blobPath)
        self.sizeOnDisk = dto.sizeOnDisk
        self.blobLastAccessed = Date(timeIntervalSince1970: TimeInterval(dto.blobLastAccessedSecs))
        self.blobLastModified = Date(timeIntervalSince1970: TimeInterval(dto.blobLastModifiedSecs))
    }
}

/// A cached revision (commit) of a repository.
public struct CachedRevisionInfo: Sendable, Equatable, Hashable {
    public let commitHash: String
    /// Directory of pointer files for this revision
    /// (`<cache>/<repo_folder>/snapshots/<commit_hash>/`).
    public let snapshotPath: URL
    public let files: [CachedFileInfo]
    /// Sum of ``CachedFileInfo/sizeOnDisk`` for every file. Blobs shared
    /// with other revisions of the same repo are counted here but not in
    /// ``CachedRepoInfo/sizeOnDisk``.
    public let sizeOnDisk: UInt64
    /// Refs (branches, tags, `refs/pr/<n>`, ...) that point at this commit.
    /// May be empty for revisions only reachable by SHA.
    public let refs: [String]
    public let lastModified: Date

    init(_ dto: CachedRevisionInfoDto) {
        self.commitHash = dto.commitHash
        self.snapshotPath = URL(fileURLWithPath: dto.snapshotPath)
        self.files = dto.files.map(CachedFileInfo.init)
        self.sizeOnDisk = dto.sizeOnDisk
        self.refs = dto.refs
        self.lastModified = Date(timeIntervalSince1970: TimeInterval(dto.lastModifiedSecs))
    }
}

/// Repository type discovered in the local cache. Mirrors ``RepoType``
/// for the types this client wraps; ``other(_:)`` carries the raw lowercase
/// singular string for any other type found on disk (e.g., a Space
/// downloaded by the CLI before this client was scoped to model/dataset).
public enum CachedRepoType: Sendable, Equatable, Hashable {
    case model
    case dataset
    case other(String)

    init(rawType: String) {
        switch rawType {
        case "model": self = .model
        case "dataset": self = .dataset
        default: self = .other(rawType)
        }
    }
}

/// A cached repository, with its revisions aggregated.
public struct CachedRepoInfo: Sendable, Equatable, Hashable {
    public let repoID: String
    /// Type of the cached repo. ``CachedRepoType/other(_:)`` covers Space and
    /// Kernel repos that may exist locally even though this client doesn't
    /// expose typed handles for them.
    public let type: CachedRepoType
    /// Absolute path of the repo's cache subfolder
    /// (`<cache>/<type>s--<owner>--<name>/`).
    public let repoPath: URL
    public let revisions: [CachedRevisionInfo]
    /// Number of unique blobs stored for this repo. Two revisions sharing
    /// the same blob count once.
    public let nbFiles: UInt64
    /// Bytes used on disk for unique blobs, with shared blobs counted once.
    public let sizeOnDisk: UInt64
    public let lastAccessed: Date
    public let lastModified: Date

    init(_ dto: CachedRepoInfoDto) {
        self.repoID = dto.repoId
        self.type = CachedRepoType(rawType: dto.repoType)
        self.repoPath = URL(fileURLWithPath: dto.repoPath)
        self.revisions = dto.revisions.map(CachedRevisionInfo.init)
        self.nbFiles = dto.nbFiles
        self.sizeOnDisk = dto.sizeOnDisk
        self.lastAccessed = Date(timeIntervalSince1970: TimeInterval(dto.lastAccessedSecs))
        self.lastModified = Date(timeIntervalSince1970: TimeInterval(dto.lastModifiedSecs))
    }
}

/// A single warning emitted during a cache scan. Parsed from the raw
/// warning strings the underlying Rust crate's walker produces, so callers
/// can pattern-match on the kind rather than substring-match the string.
///
/// The walker only emits warnings for two failure modes today; both carry
/// the offending pointer or blob path plus the OS-level reason. Future
/// upstream additions land in ``other(_:)`` so this type stays
/// non-breaking across cache-layout evolution.
public enum CacheWarning: Sendable, Equatable, Hashable {
    /// A `snapshots/<commit>/<path>` pointer (typically a symlink)
    /// references a blob the filesystem can't canonicalize – the target
    /// is missing or otherwise unresolvable. Usually caused by an
    /// interrupted download or a manual cleanup that removed the blob
    /// without removing the pointer.
    case danglingSnapshot(path: String, reason: String)
    /// A blob exists under `blobs/` but reading its metadata failed
    /// (e.g., permission denied, I/O error).
    case unreadableBlob(path: String, reason: String)
    /// A warning the walker emitted that this library doesn't yet
    /// classify. Forward-compatible escape hatch for future upstream
    /// additions.
    case other(String)

    /// Original walker string, preserved across all cases so callers
    /// can surface the raw warning verbatim (in logs, for example).
    public var rawValue: String {
        switch self {
        case .danglingSnapshot(let path, let reason):
            "Cannot resolve \(path): \(reason)"
        case .unreadableBlob(let path, let reason):
            "Cannot read blob for \(path): \(reason)"
        case .other(let raw):
            raw
        }
    }

    init(rawValue raw: String) {
        if let parsed = Self.parse(prefix: "Cannot resolve ", from: raw) {
            self = .danglingSnapshot(path: parsed.path, reason: parsed.reason)
        } else if let parsed = Self.parse(prefix: "Cannot read blob for ", from: raw) {
            self = .unreadableBlob(path: parsed.path, reason: parsed.reason)
        } else {
            self = .other(raw)
        }
    }

    /// Parse a `<prefix><path>: <reason>` warning string into its
    /// components. The walker uses the same shape for every error it
    /// emits today, so a single helper covers both classified cases.
    private static func parse(prefix: String, from raw: String)
        -> (path: String, reason: String)?
    {
        guard raw.hasPrefix(prefix) else { return nil }
        let tail = raw.dropFirst(prefix.count)
        guard let sep = tail.range(of: ": ") else { return nil }
        return (
            path: String(tail[..<sep.lowerBound]),
            reason: String(tail[sep.upperBound...])
        )
    }
}

/// Snapshot of the local Hugging Face cache directory.
///
/// Returned by ``HFClient/scanCache()``. Aggregates every cached repository
/// found at ``cacheDirectory`` along with total disk usage and any
/// warnings emitted during the scan (e.g., dangling snapshot pointers).
public struct CacheInfo: Sendable, Equatable, Hashable {
    public let cacheDirectory: URL
    public let repos: [CachedRepoInfo]
    /// Sum of ``CachedRepoInfo/sizeOnDisk`` across all repos.
    public let sizeOnDisk: UInt64
    /// Warnings emitted by the cache walker for entries it could not
    /// fully scan. See ``CacheWarning`` for the recognized kinds plus
    /// the forward-compatible ``CacheWarning/other(_:)`` escape hatch.
    public let warnings: [CacheWarning]

    /// Underlying FFI snapshot. Retained so the cache-deletion FFI can
    /// receive the same data the original scan produced without having to
    /// rebuild it from the Swift types.
    let rawDTO: HfCacheInfoDto

    init(_ dto: HfCacheInfoDto) {
        self.cacheDirectory = URL(fileURLWithPath: dto.cacheDir)
        self.repos = dto.repos.map(CachedRepoInfo.init)
        self.sizeOnDisk = dto.sizeOnDisk
        self.warnings = dto.warnings.map(CacheWarning.init(rawValue:))
        self.rawDTO = dto
    }
}
