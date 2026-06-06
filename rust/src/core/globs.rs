// Copyright © Anthony DePasquale

//! `FFIGlobMatcher` – UniFFI Object wrapping `hf_hub::repository::GlobMatcher`.
//!
//! The Swift wrapper `GlobMatcher` constructs one of these per pattern, then
//! calls `is_match` for each candidate path. Compilation errors surface as
//! `nil` from the Swift `init?`, mirroring the original behavior of the
//! Swift-only implementation that this replaces.

use std::sync::Arc;

use hf_hub::repository::GlobMatcher;

#[derive(uniffi::Object)]
pub struct FFIGlobMatcher {
    inner: GlobMatcher,
}

/// Compilation error from [`FFIGlobMatcher::try_new`]. Carries the underlying
/// `globset` message so the Swift wrapper can log it if needed; the public
/// Swift `init?` still surfaces only `nil` for the malformed-pattern case.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum GlobMatcherErrorFFI {
    #[error("invalid glob pattern: {message}")]
    InvalidPattern { message: String },
}

#[uniffi::export]
impl FFIGlobMatcher {
    /// Compile a glob pattern.
    ///
    /// Uses the same semantics as `hf_hub::repository::GlobMatcher`:
    /// `literal_separator(true)` (so `*` and `?` do not cross `/`), and the
    /// trailing-`/` shorthand that auto-appends `*`.
    #[uniffi::constructor]
    pub fn try_new(pattern: String) -> Result<Arc<Self>, GlobMatcherErrorFFI> {
        match GlobMatcher::new(&pattern) {
            Ok(inner) => Ok(Arc::new(Self { inner })),
            Err(err) => Err(GlobMatcherErrorFFI::InvalidPattern {
                message: err.to_string(),
            }),
        }
    }

    /// Check whether a repo-relative path matches the compiled pattern.
    pub fn is_match(&self, path: String) -> bool {
        self.inner.is_match(&path)
    }
}
