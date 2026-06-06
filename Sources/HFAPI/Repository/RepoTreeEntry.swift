// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Last-commit summary attached to a tree entry when the listing was
/// requested with expanded metadata.
public struct LastCommitInfo: Sendable, Equatable, Hashable {
    public let id: String?
    public let title: String?
    /// Commit date parsed from the Hub's ISO-8601 timestamp. `nil` when
    /// the Hub omits the field or sends an unrecognized format.
    public let date: Date?

    init(_ dto: LastCommitInfoDto) {
        self.id = dto.id
        self.title = dto.title
        self.date = parseHubTimestamp(dto.date)
    }
}

/// Outcome of the Hub's malware/safety scan for a blob. ``other(_:)``
/// preserves any future status string the Hub introduces.
public enum SecurityStatus: Sendable, Equatable, Hashable {
    case safe
    case unsafe
    case suspicious
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "safe": self = .safe
        case "unsafe": self = .unsafe
        case "suspicious": self = .suspicious
        default: self = .other(rawValue)
        }
    }
}

/// Security-scan summary for a file, populated when the listing was
/// requested with expanded metadata. The `avScan` and `pickleImportScan`
/// payloads are free-form JSON the Hub returns – consumers decode them
/// with their own policy via `JSONDecoder` (after `data(using: .utf8)`)
/// or `JSONSerialization`.
public struct BlobSecurityInfo: Sendable, Equatable, Hashable {
    /// Status reported by the scanner. The file is considered safe iff
    /// ``SecurityStatus/safe``.
    public let status: SecurityStatus
    /// Raw JSON text of the AV-scan summary (typically a small object with
    /// `virusFound`/`hasUnsafeFile` flags). `nil` when the Hub omits the
    /// field.
    public let avScan: String?
    /// Raw JSON text of the pickle-import-scan summary (typically an
    /// object with `highestSafetyLevel` and an `imports` array). `nil`
    /// when the Hub omits the field.
    public let pickleImportScan: String?

    init(_ dto: BlobSecurityInfoDto) {
        self.status = SecurityStatus(rawValue: dto.status)
        self.avScan = dto.avScanJson
        self.pickleImportScan = dto.pickleImportScanJson
    }
}

/// File or directory entry returned by repository tree/listing APIs.
/// Mirrors `hf_hub::RepoTreeEntry`.
public enum RepoTreeEntry: Sendable, Equatable, Hashable {
    /// A file entry in the repository tree.
    case file(
        oid: String,
        size: UInt64,
        path: String,
        lfs: BlobLfsInfo?,
        lastCommit: LastCommitInfo?,
        xetHash: String?,
        security: BlobSecurityInfo?
    )
    /// A directory entry in the repository tree.
    case directory(
        oid: String,
        path: String,
        lastCommit: LastCommitInfo?
    )

    init(_ dto: RepoTreeEntryDto) {
        self =
            switch dto {
            case .file(let oid, let size, let path, let lfs, let lastCommit, let xetHash, let security):
                .file(
                    oid: oid,
                    size: size,
                    path: path,
                    lfs: lfs.map(BlobLfsInfo.init),
                    lastCommit: lastCommit.map(LastCommitInfo.init),
                    xetHash: xetHash,
                    security: security.map(BlobSecurityInfo.init)
                )
            case .directory(let oid, let path, let lastCommit):
                .directory(
                    oid: oid,
                    path: path,
                    lastCommit: lastCommit.map(LastCommitInfo.init)
                )
            }
    }

    /// Repository-relative path, present on both variants.
    public var path: String {
        switch self {
        case .file(_, _, let path, _, _, _, _): path
        case .directory(_, let path, _): path
        }
    }

    /// Object identifier (`oid`), present on both variants.
    public var oid: String {
        switch self {
        case .file(let oid, _, _, _, _, _, _): oid
        case .directory(let oid, _, _): oid
        }
    }

    /// Last-commit summary attached when the listing was requested with
    /// expanded metadata; `nil` otherwise. Present on both variants.
    public var lastCommit: LastCommitInfo? {
        switch self {
        case .file(_, _, _, _, let lastCommit, _, _): lastCommit
        case .directory(_, _, let lastCommit): lastCommit
        }
    }
}

/// Metadata returned from a HEAD request on a file's resolve URL.
/// Mirrors `hf_hub::FileMetadataInfo`.
public struct FileMetadata: Sendable, Equatable, Hashable {
    /// Path of the file within the repository.
    public let filename: String
    /// ETag of the file content (normalized: weak prefix and quotes stripped).
    public let etag: String
    /// Commit hash the revision resolved to.
    public let commitHash: String
    /// Xet content hash, when the file is Xet-backed.
    public let xetHash: String?
    /// File size in bytes. Falls back to `0` when neither `X-Linked-Size`
    /// nor `Content-Length` is present.
    public let fileSize: UInt64
    /// Final URL the HEAD request resolved to after redirects.
    public let location: String?

    init(_ dto: FileMetadataDto) {
        self.filename = dto.filename
        self.etag = dto.etag
        self.commitHash = dto.commitHash
        self.xetHash = dto.xetHash
        self.fileSize = dto.fileSize
        self.location = dto.location
    }
}
