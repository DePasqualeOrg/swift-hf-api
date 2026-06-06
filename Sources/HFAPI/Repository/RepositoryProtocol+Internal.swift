// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Internal dispatch helpers used by the concrete repo facades.
/// Centralized here so the kind-uniform method bodies on
/// ``FFIBackedRepository`` are written once.

func repoExists(_ ffi: HfRepositoryFfi) async throws -> Bool {
    try await mapHFError { try await ffi.exists() }
}

func repoListTree(
    _ ffi: HfRepositoryFfi,
    revision: String?,
    recursive: Bool,
    expand: Bool,
    limit: Int?
) async throws -> [RepoTreeEntry] {
    try await mapHFError {
        let dtos = try await ffi.listTree(
            revision: revision,
            recursive: recursive,
            expand: expand,
            limit: limit.map(UInt64.init)
        )
        return dtos.map(RepoTreeEntry.init)
    }
}

func repoPathsInfo(
    _ ffi: HfRepositoryFfi,
    paths: [String],
    revision: String?
) async throws -> [RepoTreeEntry] {
    try await mapHFError {
        let dtos = try await ffi.getPathsInfo(paths: paths, revision: revision)
        return dtos.map(RepoTreeEntry.init)
    }
}

func repoFileMetadata(
    _ ffi: HfRepositoryFfi,
    filePath: String,
    revision: String?
) async throws -> FileMetadata {
    try await mapHFError {
        let dto = try await ffi.getFileMetadata(filepath: filePath, revision: revision)
        return FileMetadata(dto)
    }
}

func repoListCommits(
    _ ffi: HfRepositoryFfi,
    revision: String?,
    limit: Int?
) async throws -> [GitCommitInfo] {
    try await mapHFError {
        let dtos = try await ffi.listCommits(
            revision: revision,
            limit: limit.map(UInt64.init)
        )
        return dtos.map(GitCommitInfo.init)
    }
}

func repoListRefs(_ ffi: HfRepositoryFfi, includePullRequests: Bool) async throws -> GitRefs {
    try await mapHFError {
        GitRefs(try await ffi.listRefs(includePullRequests: includePullRequests))
    }
}

func repoCommitDiff(_ ffi: HfRepositoryFfi, compare: String) async throws -> String {
    try await mapHFError { try await ffi.getCommitDiff(compare: compare) }
}

func repoRawDiff(_ ffi: HfRepositoryFfi, compare: String) async throws -> String {
    try await mapHFError { try await ffi.getRawDiff(compare: compare) }
}

func repoRawDiffStream(
    _ ffi: HfRepositoryFfi,
    compare: String
) async throws -> [FileDiff] {
    try await mapHFError {
        try await ffi.getRawDiffStream(compare: compare).map(FileDiff.init)
    }
}

func repoUpdateSettings(
    _ ffi: HfRepositoryFfi,
    private: Bool?,
    gated: GatedApprovalMode?,
    description: String?,
    discussionsDisabled: Bool?,
    gatedNotifications: GatedNotifications?
) async throws {
    try await mapHFError {
        try await ffi.updateSettings(
            private: `private`,
            gated: gated?.ffi,
            description: description,
            discussionsDisabled: discussionsDisabled,
            gatedNotifications: gatedNotifications?.ffi
        )
    }
}

func repoCreateBranch(_ ffi: HfRepositoryFfi, branch: String, revision: String?) async throws {
    try await mapHFError {
        try await ffi.createBranch(branch: branch, revision: revision)
    }
}

func repoDeleteBranch(_ ffi: HfRepositoryFfi, branch: String) async throws {
    try await mapHFError { try await ffi.deleteBranch(branch: branch) }
}

func repoCreateTag(
    _ ffi: HfRepositoryFfi,
    tag: String,
    revision: String?,
    message: String?
) async throws {
    try await mapHFError {
        try await ffi.createTag(tag: tag, revision: revision, message: message)
    }
}

func repoDeleteTag(_ ffi: HfRepositoryFfi, tag: String) async throws {
    try await mapHFError { try await ffi.deleteTag(tag: tag) }
}

func repoDeleteFile(
    _ ffi: HfRepositoryFfi,
    pathInRepo: String,
    revision: String?,
    commitMessage: String?,
    createPR: Bool
) async throws -> CommitInfo {
    try await mapHFError {
        let dto = try await ffi.deleteFile(
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            createPr: createPR
        )
        return CommitInfo(dto)
    }
}

func repoDeleteFolder(
    _ ffi: HfRepositoryFfi,
    pathInRepo: String,
    revision: String?,
    commitMessage: String?,
    createPR: Bool
) async throws -> CommitInfo {
    try await mapHFError {
        let dto = try await ffi.deleteFolder(
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            createPr: createPR
        )
        return CommitInfo(dto)
    }
}

func repoUploadFile(
    _ ffi: HfRepositoryFfi,
    source: UploadSourceDto,
    pathInRepo: String,
    revision: String?,
    commitMessage: String?,
    commitDescription: String?,
    createPR: Bool,
    parentCommit: String?,
    progress: (@Sendable (UploadEvent) -> Void)?
) async throws -> CommitInfo {
    let handler: FfiUploadProgressHandler? = progress.map { ClosureUploadHandler(closure: $0) }
    return try await withCancellableHFOperation { handle in
        let dto = try await ffi.uploadFile(
            source: source,
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPr: createPR,
            parentCommit: parentCommit,
            handle: handle,
            progress: handler
        )
        return CommitInfo(dto)
    }
}

func repoUploadFileStream(
    _ ffi: HfRepositoryFfi,
    source: UploadSourceDto,
    pathInRepo: String,
    revision: String?,
    commitMessage: String?,
    commitDescription: String?,
    createPR: Bool,
    parentCommit: String?
) -> UploadStream {
    makeOperationStream(
        handler: StreamingUploadHandler.init,
        operation: { handle, handler in
            let dto = try await ffi.uploadFile(
                source: source,
                pathInRepo: pathInRepo,
                revision: revision,
                commitMessage: commitMessage,
                commitDescription: commitDescription,
                createPr: createPR,
                parentCommit: parentCommit,
                handle: handle,
                progress: handler
            )
            return CommitInfo(dto)
        },
        wrap: UploadStream.init
    )
}

func repoUploadFolder(
    _ ffi: HfRepositoryFfi,
    folderPath: String,
    pathInRepo: String?,
    revision: String?,
    commitMessage: String?,
    commitDescription: String?,
    createPR: Bool,
    allowPatterns: [String]?,
    ignorePatterns: [String]?,
    deletePatterns: [String]?,
    progress: (@Sendable (UploadEvent) -> Void)?
) async throws -> CommitInfo {
    let handler: FfiUploadProgressHandler? = progress.map { ClosureUploadHandler(closure: $0) }
    return try await withCancellableHFOperation { handle in
        let dto = try await ffi.uploadFolder(
            folderPath: folderPath,
            pathInRepo: pathInRepo,
            revision: revision,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            createPr: createPR,
            allowPatterns: allowPatterns,
            ignorePatterns: ignorePatterns,
            deletePatterns: deletePatterns,
            handle: handle,
            progress: handler
        )
        return CommitInfo(dto)
    }
}

func repoUploadFolderStream(
    _ ffi: HfRepositoryFfi,
    folderPath: String,
    pathInRepo: String?,
    revision: String?,
    commitMessage: String?,
    commitDescription: String?,
    createPR: Bool,
    allowPatterns: [String]?,
    ignorePatterns: [String]?,
    deletePatterns: [String]?
) -> UploadStream {
    makeOperationStream(
        handler: StreamingUploadHandler.init,
        operation: { handle, handler in
            let dto = try await ffi.uploadFolder(
                folderPath: folderPath,
                pathInRepo: pathInRepo,
                revision: revision,
                commitMessage: commitMessage,
                commitDescription: commitDescription,
                createPr: createPR,
                allowPatterns: allowPatterns,
                ignorePatterns: ignorePatterns,
                deletePatterns: deletePatterns,
                handle: handle,
                progress: handler
            )
            return CommitInfo(dto)
        },
        wrap: UploadStream.init
    )
}

func repoCreateCommit(
    _ ffi: HfRepositoryFfi,
    operations: [CommitOperation],
    commitMessage: String,
    commitDescription: String?,
    revision: String?,
    createPR: Bool,
    parentCommit: String?,
    progress: (@Sendable (UploadEvent) -> Void)?
) async throws -> CommitInfo {
    let handler: FfiUploadProgressHandler? = progress.map { ClosureUploadHandler(closure: $0) }
    let operationDTOs = operations.map(\.ffi)
    return try await withCancellableHFOperation { handle in
        let dto = try await ffi.createCommit(
            operations: operationDTOs,
            commitMessage: commitMessage,
            commitDescription: commitDescription,
            revision: revision,
            createPr: createPR,
            parentCommit: parentCommit,
            handle: handle,
            progress: handler
        )
        return CommitInfo(dto)
    }
}

func repoCreateCommitStream(
    _ ffi: HfRepositoryFfi,
    operations: [CommitOperation],
    commitMessage: String,
    commitDescription: String?,
    revision: String?,
    createPR: Bool,
    parentCommit: String?
) -> UploadStream {
    let operationDTOs = operations.map(\.ffi)
    return makeOperationStream(
        handler: StreamingUploadHandler.init,
        operation: { handle, handler in
            let dto = try await ffi.createCommit(
                operations: operationDTOs,
                commitMessage: commitMessage,
                commitDescription: commitDescription,
                revision: revision,
                createPr: createPR,
                parentCommit: parentCommit,
                handle: handle,
                progress: handler
            )
            return CommitInfo(dto)
        },
        wrap: UploadStream.init
    )
}

// `@unchecked Sendable` on these upload handlers is structurally safe – see
// the matching note on the download handlers in `HFRepositoryDownload.swift`.
// The `@unchecked` is required only because the FFI-generated
// `FfiUploadProgressHandler` protocol inherits `AnyObject + Sendable` and
// Swift cannot infer the conformance from a `final class` with `let`-only
// `@Sendable` storage.
private final class ClosureUploadHandler: FfiUploadProgressHandler, @unchecked Sendable {
    private let closure: @Sendable (UploadEvent) -> Void

    init(closure: @escaping @Sendable (UploadEvent) -> Void) {
        self.closure = closure
    }

    func onEvent(event: UploadEventDto) {
        closure(UploadEvent(event))
    }
}

/// Bridges the upload `with_foreign` callback into an
/// `AsyncThrowingStream`. Same threading contract as
/// `StreamingProgressHandler` on the download side.
private final class StreamingUploadHandler: FfiUploadProgressHandler, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<UploadEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<UploadEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(event: UploadEventDto) {
        continuation.yield(UploadEvent(event))
    }
}

/// Internal seam that carries the underlying FFI handle. Used to share
/// default implementations across the concrete repo handles
/// (``ModelRepository``, ``DatasetRepository``) without leaking the
/// `HfRepositoryFfi` type onto the public ``RepositoryProtocol``.
///
/// External callers cannot conform to this protocol – `HfRepositoryFfi` is
/// not part of the public product surface.
protocol FFIBackedRepository: RepositoryProtocol {
    var ffi: HfRepositoryFfi { get }
}

extension ModelRepository: FFIBackedRepository {}
extension DatasetRepository: FFIBackedRepository {}
