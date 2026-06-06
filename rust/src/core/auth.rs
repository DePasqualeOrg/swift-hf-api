// Copyright © Anthony DePasquale

//! Foreign-callback bridge for dynamic Hub authentication tokens.
//!
//! `HFClient` (the upstream `hf-hub` type) bakes the token in at build time
//! and stores it as a private static field. To support refresh – e.g., OAuth
//! tokens that rotate hourly – the FFI exposes [`FFITokenProvider`], a foreign
//! callback the Rust facade calls before each Hub request to fetch the
//! current token. When the value the provider returns differs from the last
//! seen token, the facade rebuilds the inner `HFClient`. See
//! [`crate::core::client::HFClientFFI::active_client`] for the rebuild loop.
//!
//! The trait is async because Swift's OAuth managers (e.g.
//! `HuggingFaceAuthenticationManager.getValidToken()`) consult the keychain
//! and may trigger a refresh roundtrip. The trait method also returns a
//! `Result` so OAuth errors (refresh failure, expired refresh token,
//! keychain unavailable) propagate to the Hub call site instead of
//! silently degrading the request to unauthenticated mode.
//!
//! # Threading and non-blocking contract
//!
//! `get_token` runs on a tokio worker thread. Per UniFFI's standard contract
//! for `with_foreign` callbacks, the Swift implementation must not block —
//! a blocking `URLSession` call from inside the callback would deadlock the
//! tokio runtime. The expected implementation hops through Swift's structured
//! concurrency machinery (the OAuth manager's existing async API) and
//! returns.

use std::sync::Arc;

/// Wraps any error raised by the foreign-language token provider. Carries a
/// single `message` field – the foreign side stringifies the original error
/// via `localizedDescription` (or equivalent) before crossing the FFI.
///
/// The Rust facade re-raises this as
/// [`crate::core::error::HFErrorFFI::TokenProviderFailed`] so the same
/// message is visible at the Hub-call site.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum TokenProviderErrorFFI {
    #[error("{message}")]
    Failed { message: String },
}

/// Foreign-implemented async callback that returns the current Hub token.
///
/// Returning `Ok(None)` is allowed – the resulting client behaves as an
/// unauthenticated client for that request. The next request will call
/// `get_token` again, so transient `Ok(None)` answers don't permanently
/// demote the client.
///
/// Returning `Err(TokenProviderErrorFFI::Failed { message })` aborts the
/// Hub call, which surfaces as
/// [`crate::core::error::HFErrorFFI::TokenProviderFailed`] on the Swift
/// side. Use this path for unrecoverable cases (refresh-token expired,
/// keychain inaccessible) where the consumer should see a precise OAuth
/// error rather than a generic Hub 401.
///
/// The `#[async_trait]` attribute is required: pure `async fn` in trait
/// isn't dyn-compatible (no vtable can be built), and UniFFI's foreign-
/// callback bridge needs to hold an `Arc<dyn FFITokenProvider>`. The
/// attribute desugars `async fn` to a `Pin<Box<dyn Future>>` return type,
/// which is dyn-compatible.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait FFITokenProvider: Send + Sync {
    async fn get_token(&self) -> Result<Option<String>, TokenProviderErrorFFI>;
}

/// Type alias used across the facade. Optional – `None` means static-token
/// mode (the legacy path).
pub(crate) type DynTokenProvider = Arc<dyn FFITokenProvider>;
