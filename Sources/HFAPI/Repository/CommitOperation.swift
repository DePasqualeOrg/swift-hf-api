// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// One operation inside a multi-op commit. Mirrors
/// `hf_hub::repository::CommitOperation`.
///
/// Use ``RepositoryProtocol/createCommit(operations:commitMessage:commitDescription:revision:createPR:parentCommit:progress:)``
/// when you need an explicit mix of add and delete operations in one
/// commit. For one-shot workflows, prefer the higher-level
/// `uploadFile`/`uploadFolder`/`deleteFile`/`deleteFolder` methods.
public enum CommitOperation: Sendable {
    /// Add or replace a file at `pathInRepo`. The content source is either
    /// a local file path (read at commit time) or in-memory bytes (held by
    /// the operation until the commit runs).
    case add(pathInRepo: String, source: ContentSource)
    /// Delete a file at `pathInRepo`.
    case delete(pathInRepo: String)

    /// Content source for an [`add`](CommitOperation/add(pathInRepo:source:))
    /// operation. Mirrors `hf_hub::repository::AddSource`.
    public enum ContentSource: Sendable {
        /// File at this URL is read when the commit runs. Cheap to
        /// construct; the file must still exist at commit time.
        case path(URL)
        /// In-memory bytes owned by the operation. Suitable for small
        /// payloads or content generated at runtime.
        case bytes(Data)
    }

    /// Convenience factory: add a file from a local path. Equivalent to
    /// `.add(pathInRepo: pathInRepo, source: .path(file))`.
    public static func file(_ file: URL, pathInRepo: String) -> CommitOperation {
        .add(pathInRepo: pathInRepo, source: .path(file))
    }

    /// Convenience factory: add a file from in-memory bytes. Equivalent to
    /// `.add(pathInRepo: pathInRepo, source: .bytes(bytes))`.
    public static func bytes(_ bytes: Data, pathInRepo: String) -> CommitOperation {
        .add(pathInRepo: pathInRepo, source: .bytes(bytes))
    }

    var ffi: CommitOperationDto {
        switch self {
        case .add(let pathInRepo, let source):
            return .add(pathInRepo: pathInRepo, source: source.ffi)
        case .delete(let pathInRepo):
            return .delete(pathInRepo: pathInRepo)
        }
    }
}

extension CommitOperation.ContentSource {
    fileprivate var ffi: UploadSourceDto {
        switch self {
        case .path(let url): .path(path: url.path(percentEncoded: false))
        case .bytes(let data): .bytes(bytes: data)
        }
    }
}
