// Copyright © Anthony DePasquale

import Foundation
import HFAPIShared

/// Authentication mode for ``HFClient``.
///
/// The four cases are mutually exclusive by construction – the previous
/// builder-based API enforced this at runtime, but the type system encodes
/// it directly.
public enum Auth: Sendable {
    /// Default. Resolves a bearer token from the environment at
    /// `HFClient.init` time, checking these sources in priority order:
    ///
    /// 1. `HF_TOKEN` env var
    /// 2. `HUGGING_FACE_HUB_TOKEN` env var
    /// 3. File at `HF_TOKEN_PATH`
    /// 4. `$HF_HOME/token`
    /// 5. `~/.cache/huggingface/token`
    /// 6. `~/.huggingface/token`
    ///
    /// Matches the HF CLI and Python `huggingface_hub` library. When no
    /// token is found, the resulting client runs unauthenticated.
    ///
    /// Resolution is one-shot: the chain runs synchronously inside
    /// `HFClient.init` and the result is then fixed for the life of the
    /// client. For dynamic-token flows (OAuth, custom stores), use
    /// ``Auth/provider(_:)-(_)`` instead.
    case env

    /// Explicitly unauthenticated. Skips env detection – useful in CI
    /// where a stray `HF_TOKEN` would silently change the request.
    case unauthenticated

    /// Static bearer token.
    case token(String)

    /// Dynamic token provider. The closure runs before every Hub request;
    /// when its return value differs from the last seen token, the underlying
    /// Rust client is rebuilt with the new value. Returning `nil` produces an
    /// unauthenticated request for that call. Throwing aborts the Hub call
    /// with ``HFError/tokenProviderFailed(message:)``.
    ///
    /// **Performance:** every Hub call awaits the closure under an internal
    /// mutex, so the closure body must be cheap in the common cached path.
    /// The OAuth bridge (`OAuthClientFactory`) and the in-tree
    /// ``/HFAPIShared/TokenProvider`` cases all return from an in-memory
    /// cache in microseconds and refresh on the side; bespoke providers
    /// should match that shape. For workloads that loop tight on small
    /// files (`snapshotDownload` with many parallel workers, batched HEAD
    /// requests) and whose token is genuinely static for the loop's
    /// duration, prefer ``token(_:)`` to skip the per-call hop entirely.
    case provider(@Sendable () async throws -> String?)
}

extension Auth {
    /// Bridge a value-typed `HFAPIShared.TokenProvider` chain into the enum.
    /// ``/HFAPIShared/TokenProvider`` is the composable form for multi-source flows
    /// (`.composite([.oauth(manager: m), .environment, .fixed(token: "fallback")])`, etc.).
    /// Semantically identical to wrapping the closure form by hand
    /// (`Auth.provider { try await provider.token() }`); pick whichever
    /// reads better at the call site.
    public static func provider(_ provider: TokenProvider) -> Auth {
        .provider {
            try await provider.token()
        }
    }
}
