// Copyright © Anthony DePasquale

// `HFAPIHubAuth` glues `HFAPIOAuth.OAuthManager` together
// with the Rust-backed `HFAPI.HFClient` so OAuth refresh propagates into the
// Rust facade transparently. The integration point is `OAuthClientFactory`,
// which builds an `HFClient` whose dynamic-token provider hops to the
// authentication manager's `validToken()` on every Hub request.
//
// The manager is `@MainActor`-isolated (it reaches into the keychain and
// drives `ASWebAuthenticationSession`), so the entire bridge is gated
// behind `#if canImport(AuthenticationServices)` – Linux builds get an
// empty target, matching the per-platform layout of `HFAPIOAuth`.

#if canImport(AuthenticationServices)

    import Foundation
    import HFAPI
    import HFAPIOAuth

    /// Single-call helper that wires ``/HFAPIOAuth/OAuthManager`` into
    /// ``/HFAPI/HFClient``'s dynamic-token provider so OAuth refresh propagates into
    /// the Rust-backed Hub client without consumers rebuilding the client.
    ///
    /// ```swift
    /// let manager = try OAuthManager(
    ///     clientID: "your-client-id",
    ///     redirectURL: URL(string: "myapp://oauth")!,
    ///     scope: .basic,
    ///     keychainService: "com.example.app",
    ///     keychainAccount: "huggingface"
    /// )
    /// let client = try OAuthClientFactory.client(authManager: manager)
    /// let info = try await client.model(owner: "openai-community", name: "gpt2").info()
    /// ```
    ///
    /// On every Hub call, the Rust facade invokes the closure that wraps
    /// `manager.validToken()`. When the manager rotates the token (e.g.,
    /// after a refresh), the next Hub request sees the new value and the
    /// underlying `hf_hub::HFClient` is rebuilt with the new token before
    /// the request runs. Static configuration (endpoint, cache_dir, retry,
    /// user agent) is preserved across rotations.
    @available(macOS 14.0, iOS 17.0, *)
    public enum OAuthClientFactory {
        /// Build an ``/HFAPI/HFClient`` configured to consult `authManager` for every
        /// Hub request.
        ///
        /// The bridge owns the auth slot – the parameters here mirror
        /// ``/HFAPI/HFClient/init(endpoint:auth:userAgent:cacheDirectory:cacheEnabled:retryMaxAttempts:retryBaseDelay:)``
        /// minus `auth`, which is internally wired to the manager.
        ///
        /// ``/HFAPIOAuth/OAuthManager/validToken()`` errors propagate out of the Hub call as
        /// ``/HFAPI/HFError/tokenProviderFailed(message:)``, carrying the original
        /// ``/HFAPIOAuth/OAuthError``'s `localizedDescription`. This lets consumers
        /// distinguish "OAuth session is dead, prompt user to sign in again"
        /// from a generic Hub-side 401.
        ///
        /// Consumers preferring best-effort semantics – transient OAuth
        /// failures degrade to an unauthenticated request rather than
        /// aborting the call – should bypass this helper and configure
        /// ``/HFAPI/HFClient`` directly:
        ///
        /// ```swift
        /// try HFClient(auth: .provider {
        ///     try? await authManager.validToken()
        /// })
        /// ```
        public static func client(
            authManager: OAuthManager,
            endpoint: String? = nil,
            userAgent: String? = nil,
            cacheDirectory: URL? = nil,
            cacheEnabled: Bool? = nil,
            retryMaxAttempts: UInt32? = nil,
            retryBaseDelay: Duration? = nil
        ) throws -> HFClient {
            try HFClient(
                endpoint: endpoint,
                auth: .provider {
                    try await authManager.validToken()
                },
                userAgent: userAgent,
                cacheDirectory: cacheDirectory,
                cacheEnabled: cacheEnabled,
                retryMaxAttempts: retryMaxAttempts,
                retryBaseDelay: retryBaseDelay
            )
        }
    }

#endif
