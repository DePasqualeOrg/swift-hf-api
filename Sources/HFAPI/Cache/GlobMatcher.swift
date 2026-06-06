// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Minimal glob matcher used by ``HFClient/cachedSnapshot(repoId:type:revision:containing:)``
/// for repo-relative path matching. Thin wrapper over the Rust
/// `hf_hub::repository::GlobMatcher` so semantics stay in lockstep with the
/// rest of the Hub crate:
///
/// - `*` matches any characters except `/` — does **not** cross path segment
///   boundaries.
/// - `?` matches a single character except `/`.
/// - `**` matches any number of full path segments. Must be a full path
///   component (surrounded by `/` or at start/end of the pattern); a `**`
///   that is not a full component (`foo**bar`) degrades to a single `*`.
/// - A trailing `/` on a pattern is shorthand for "match anything inside this
///   directory" — it auto-appends `*`.
///
/// Patterns are matched against the full repo-relative path (e.g.,
/// `subdir/file.json`), not just the basename.
struct GlobMatcher: Sendable {
    let pattern: String
    private let inner: FfiGlobMatcher

    /// Compile a pattern. Returns `nil` if the pattern is malformed.
    init?(_ pattern: String) {
        guard let inner = try? FfiGlobMatcher.tryNew(pattern: pattern) else { return nil }
        self.pattern = pattern
        self.inner = inner
    }

    /// Whether `path` (a repo-relative path) is matched by the glob.
    func matches(_ path: String) -> Bool {
        inner.isMatch(path: path)
    }
}
