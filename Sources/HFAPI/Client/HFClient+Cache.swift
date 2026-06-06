// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

extension HFClient {
    /// Scan the configured cache directory and return a summary of every
    /// cached repository, revision, and file.
    ///
    /// If the cache directory does not exist, returns an empty
    /// ``CacheInfo`` (no repos, zero size) – not an error. Unreadable
    /// blobs and dangling snapshot pointers surface in
    /// ``CacheInfo/warnings`` rather than failing the scan.
    public func scanCache() async throws -> CacheInfo {
        try await mapHFError { CacheInfo(try await ffi.scanCache()) }
    }

    /// Returns the URL of a cached snapshot only if every supplied pattern
    /// matches at least one file in that snapshot. Convenience that scans
    /// the cache and forwards to
    /// ``CacheInfo/cachedSnapshot(repoId:type:revision:containing:)``.
    ///
    /// Callers performing many lookups should call ``scanCache()`` once and
    /// reuse the resulting ``CacheInfo`` rather than re-scanning per call.
    public func cachedSnapshot(
        repoId: RepositoryID,
        type: RepoType,
        revision: String,
        containing patterns: [String]
    ) async throws -> URL? {
        let info = try await scanCache()
        return info.cachedSnapshot(
            repoId: repoId,
            type: type,
            revision: revision,
            containing: patterns
        )
    }
}
