// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// A handle to a specific model repository on the Hub. Built via
/// ``HFClient/model(owner:name:)``.
///
/// Mirrors `hf_hub::HFRepository<RepoTypeModel>`. The Swift wrapper exposes
/// per-kind concrete types (``ModelRepository``, ``DatasetRepository``, …) so
/// kind-specific methods are reachable only on the right type – the FFI handle
/// underneath is the same shape, tagged with a runtime `RepoTypeDto`.
public struct ModelRepository: Sendable {
    /// Underlying FFI handle. Internal — used by ``FFIBackedRepository``'s
    /// default implementations to forward the shared `repoXxx` dispatch
    /// to `hf_hub` without per-kind duplication. Use the typed public
    /// methods instead.
    let ffi: HfRepositoryFfi

    init(ffi: HfRepositoryFfi) {
        self.ffi = ffi
    }

    /// Fetch metadata for this model repository.
    ///
    /// - Parameters:
    ///   - revision: Git revision (branch, tag, or commit SHA). Defaults to
    ///     the main branch.
    ///   - expand: List of properties to expand in the response (e.g.,
    ///     `"trendingScore"`, `"cardData"`).
    /// - Returns: A ``ModelInfo`` populated with the fields the Hub returned.
    /// - Throws: ``HFError`` – typically `.repoNotFound`, `.authRequired`,
    ///   or `.revisionNotFound` for the obvious cases.
    public func info(revision: String? = nil, expand: [String]? = nil) async throws -> ModelInfo {
        try await mapHFError {
            ModelInfo(try await ffi.infoModel(revision: revision, expand: expand))
        }
    }
}
