// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// A handle to a specific dataset repository on the Hub. Built via
/// ``HFClient/dataset(owner:name:)``.
///
/// Mirrors `hf_hub::HFRepository<RepoTypeDataset>`. The Swift wrapper exposes
/// per-kind concrete types so kind-specific methods are reachable only on
/// the right type.
public struct DatasetRepository: Sendable {
    /// Underlying FFI handle. Internal — used by ``FFIBackedRepository``'s
    /// default implementations to forward the shared `repoXxx` dispatch
    /// to `hf_hub` without per-kind duplication. Use the typed public
    /// methods instead.
    let ffi: HfRepositoryFfi

    init(ffi: HfRepositoryFfi) {
        self.ffi = ffi
    }

    /// Fetch metadata for this dataset repository.
    ///
    /// - Parameters:
    ///   - revision: Git revision (branch, tag, or commit SHA). Defaults to
    ///     the main branch.
    ///   - expand: List of properties to expand in the response.
    /// - Returns: A ``DatasetInfo`` populated with the fields the Hub returned.
    /// - Throws: ``HFError`` – typically `.repoNotFound`, `.authRequired`,
    ///   or `.revisionNotFound` for the obvious cases.
    public func info(revision: String? = nil, expand: [String]? = nil) async throws -> DatasetInfo {
        try await mapHFError {
            DatasetInfo(try await ffi.infoDataset(revision: revision, expand: expand))
        }
    }
}
