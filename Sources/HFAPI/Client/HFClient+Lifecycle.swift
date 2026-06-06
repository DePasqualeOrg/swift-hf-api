// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

extension HFClient {
    /// Create a new repository on the Hub.
    ///
    /// - Parameters:
    ///   - type: The repository type to create.
    ///   - repoID: The repo ID, either `"owner/name"` or just `"name"` (in
    ///     which case the authenticated user's namespace is used).
    ///   - private: Whether the repository should be private. Defaults to `false`.
    ///     Mirrors the Hub's JSON field name; the read-side property is
    ///     exposed as `isPrivate` (Swift Bool-property convention).
    ///   - existOk: When `true`, a 409 from the Hub (repository already
    ///     exists) is treated as success and the canonical URL is returned.
    ///     Defaults to `false`.
    /// - Returns: The canonical Hub URL of the new (or existing) repository.
    /// - Throws: ``HFError/malformedResponse(what:url:)`` if the Hub returns
    ///   a `url` field that fails to parse as a URL (not expected in practice);
    ///   other ``HFError`` variants for transport / authorization failures.
    @discardableResult
    public func createRepository(
        type: RepoType,
        repoID: String,
        private: Bool? = nil,
        existOk: Bool = false
    ) async throws -> URL {
        try await mapHFError {
            let dto = try await ffi.createRepository(
                repoId: repoID,
                kind: type.ffi,
                private: `private`,
                existOk: existOk,
                spaceSdk: nil
            )
            return try repoURL(from: dto)
        }
    }

    /// Create a new repository on the Hub addressed by `(owner, name)` —
    /// matches the vocabulary used everywhere else on ``HFClient``. Equivalent
    /// to calling ``createRepository(type:repoID:private:existOk:)`` with
    /// `repoID: "\(owner)/\(name)"`.
    @discardableResult
    public func createRepository(
        type: RepoType,
        owner: String,
        name: String,
        private: Bool? = nil,
        existOk: Bool = false
    ) async throws -> URL {
        try await createRepository(
            type: type,
            repoID: "\(owner)/\(name)",
            private: `private`,
            existOk: existOk
        )
    }

    /// Delete a repository on the Hub.
    ///
    /// - Parameters:
    ///   - type: The repository type to delete.
    ///   - repoID: The repo ID, either `"owner/name"` or just `"name"`.
    ///   - missingOk: When `true`, a 404 from the Hub (repository does not
    ///     exist) is treated as success. Defaults to `false`.
    public func deleteRepository(
        type: RepoType,
        repoID: String,
        missingOk: Bool = false
    ) async throws {
        try await mapHFError {
            try await ffi.deleteRepository(
                repoId: repoID,
                kind: type.ffi,
                missingOk: missingOk
            )
        }
    }

    /// Delete a repository on the Hub addressed by `(owner, name)`.
    /// Equivalent to calling ``deleteRepository(type:repoID:missingOk:)``
    /// with `repoID: "\(owner)/\(name)"`.
    public func deleteRepository(
        type: RepoType,
        owner: String,
        name: String,
        missingOk: Bool = false
    ) async throws {
        try await deleteRepository(
            type: type,
            repoID: "\(owner)/\(name)",
            missingOk: missingOk
        )
    }

    /// Rename a repository on the Hub.
    ///
    /// - Parameters:
    ///   - type: The repository type being moved.
    ///   - from: Current repo ID, in `"owner/name"` form.
    ///   - to: New repo ID, in `"owner/name"` form.
    /// - Returns: The canonical Hub URL of the moved repository.
    /// - Throws: ``HFError/malformedResponse(what:url:)`` if the Hub returns
    ///   a `url` field that fails to parse as a URL (not expected in practice);
    ///   other ``HFError`` variants for transport / authorization failures.
    @discardableResult
    public func moveRepository(
        type: RepoType,
        from: String,
        to: String
    ) async throws -> URL {
        try await mapHFError {
            let dto = try await ffi.moveRepository(
                fromId: from,
                toId: to,
                kind: type.ffi
            )
            return try repoURL(from: dto)
        }
    }
}

private func repoURL(from dto: RepoUrlDto) throws -> URL {
    guard let url = URL(string: dto.url) else {
        throw HFError.malformedResponse(what: "repo URL", url: dto.url)
    }
    return url
}
