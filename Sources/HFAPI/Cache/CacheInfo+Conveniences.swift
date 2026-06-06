// Copyright © Anthony DePasquale

import Foundation

extension CacheInfo {
    /// Returns the cached repositories that match a given ``RepoType``.
    ///
    /// Equivalent to `repos.filter { $0.type == .model }` for
    /// ``RepoType/model``. ``CachedRepoType/other(_:)`` entries are never
    /// returned (the client doesn't expose typed handles for them).
    public func cachedRepos(ofType type: RepoType) -> [CachedRepoInfo] {
        let target = type.cachedRepoType
        return repos.filter { $0.type == target }
    }

    /// Returns the cached repository matching `id` and `type`, or `nil`
    /// if no such repo is present in the cache.
    ///
    /// Useful for "is this model downloaded?" UX without parsing
    /// `models--owner--name` directory names manually.
    public func cachedRepo(_ id: RepositoryID, type: RepoType) -> CachedRepoInfo? {
        let target = type.cachedRepoType
        return repos.first { $0.type == target && $0.repoID == id.rawValue }
    }

    /// Returns the URL of a cached snapshot only if every supplied pattern
    /// matches at least one file in that snapshot. Returns `nil` if the repo
    /// is not cached, the revision is not present, or at least one pattern
    /// fails to match.
    ///
    /// Unlike `snapshotDownload(localFilesOnly: true)`, which mirrors
    /// upstream "best-effort directory exists" semantics and ignores patterns
    /// offline, this method enforces that every supplied pattern matches at
    /// least one cached file. Useful when "is this revision usable?" depends
    /// on the presence of specific files (e.g., `*.safetensors`,
    /// `tokenizer.json`) and the caller wants to gate behavior on that.
    ///
    /// Patterns are matched against repo-relative paths with
    /// `GlobMatcher` (`globset` semantics: `*` does not cross `/`, `**`
    /// recurses, trailing `/` auto-appends `*`).
    ///
    /// `revision` may be either a 40-character commit hash or a ref name
    /// (e.g., `"main"`, a tag). For ref names, the first cached revision
    /// whose ``CachedRevisionInfo/refs`` list contains the name wins.
    ///
    /// Passing an empty `patterns` array degrades to "does this snapshot
    /// exist?" – the snapshot URL is returned as long as `repoId` is cached
    /// and the revision resolves.
    public func cachedSnapshot(
        repoId: RepositoryID,
        type: RepoType,
        revision: String,
        containing patterns: [String]
    ) -> URL? {
        guard let repo = cachedRepo(repoId, type: type) else { return nil }
        let resolved: CachedRevisionInfo? = {
            if let byHash = repo.revisions.first(where: { $0.commitHash == revision }) {
                return byHash
            }
            return repo.revisions.first { $0.refs.contains(revision) }
        }()
        guard let revisionInfo = resolved else { return nil }
        guard Self.snapshotContains(revisionInfo, patterns: patterns) else { return nil }
        return revisionInfo.snapshotPath
    }

    private static func snapshotContains(
        _ revision: CachedRevisionInfo,
        patterns: [String]
    ) -> Bool {
        if patterns.isEmpty { return true }
        let filenames = revision.files.map(\.fileName)
        for pattern in patterns {
            guard let matcher = GlobMatcher(pattern) else { return false }
            if !filenames.contains(where: { matcher.matches($0) }) {
                return false
            }
        }
        return true
    }
}

extension RepoType {
    /// Project a ``RepoType`` into the broader ``CachedRepoType`` namespace
    /// for comparisons against scan results. Internal because callers should
    /// not need to deal with the forward-compatible ``CachedRepoType/other(_:)``
    /// case from the public conveniences above.
    var cachedRepoType: CachedRepoType {
        switch self {
        case .model: .model
        case .dataset: .dataset
        }
    }
}
