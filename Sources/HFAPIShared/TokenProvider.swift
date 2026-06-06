// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

/// A token provider for Hugging Face API authentication.
///
/// `TokenProvider` provides a flexible, composable way to handle authentication
/// tokens for Hugging Face API requests. You can use it with fixed tokens,
/// environment-based detection, OAuth flows, or custom implementations.
///
/// ## Environment-Based Authentication
///
/// For automatic token detection from environment variables and files:
///
/// ```swift
/// let client = try HFClient(auth: .provider(.environment))
/// ```
///
/// The `.environment` case automatically detects tokens from multiple sources
/// in priority order:
///
/// 1. `HF_TOKEN` environment variable
/// 2. `HUGGING_FACE_HUB_TOKEN` environment variable
/// 3. File at path specified by `HF_TOKEN_PATH` environment variable
/// 4. File at `$HF_HOME/token`
/// 5. File at `~/.cache/huggingface/token` (standard HF CLI location)
/// 6. File at `~/.huggingface/token` (fallback location)
///
/// ## Fixed Token Authentication
///
/// For a fixed token, prefer `Auth.token` directly. The `TokenProvider`
/// `.fixed` case is most useful inside a composite chain:
///
/// ```swift
/// let client = try HFClient(auth: .token("hf_abc123"))
/// ```
///
/// ## OAuth Authentication
///
/// For OAuth-based authentication (requires macOS 14+, iOS 17+), use the `.oauth(manager:)` factory method:
///
/// ```swift
/// let authManager = try OAuthManager(
///     clientID: "your-client-id",
///     redirectURL: URL(string: "myapp://oauth")!,
///     scope: .basic,
///     keychainService: "com.example.app",
///     keychainAccount: "huggingface"
/// )
/// let client = try HFClient(auth: .provider(.oauth(manager: authManager)))
/// ```
///
/// ## Composite Authentication
///
/// Combine multiple authentication strategies. The provider tries each
/// strategy in order until one succeeds:
///
/// ```swift
/// let tokenProvider = TokenProvider.composite([
///     .oauth(manager: authManager),       // Try OAuth first
///     .environment,                       // Fall back to environment detection
///     .fixed(token: "hf_abc123"),         // Final fallback
/// ])
/// let client = try HFClient(auth: .provider(tokenProvider))
/// ```
///
/// ## Custom Token Providers
///
/// For custom authentication logic, use the `.custom` case:
///
/// ```swift
/// let customProvider = TokenProvider.custom {
///     // Your custom token retrieval logic
///     return try await fetchTokenFromKeychain()
/// }
/// let client = try HFClient(auth: .provider(customProvider))
/// ```
///
/// ## No Authentication
///
/// To explicitly disable authentication, prefer `Auth.unauthenticated` directly:
///
/// ```swift
/// let client = try HFClient(auth: .unauthenticated)
/// ```
public indirect enum TokenProvider: Sendable {
    /// A fixed token provider that returns a static token.
    ///
    /// ```swift
    /// let provider = TokenProvider.fixed(token: "hf_abc123")
    /// ```
    ///
    /// To explicitly opt out of authentication, prefer `Auth.unauthenticated`
    /// at the top level.
    ///
    /// - Parameter token: The bearer token to use for authentication.
    case fixed(token: String)

    /// An environment-based token provider that auto-detects tokens from standard locations.
    ///
    /// This provider automatically detects tokens from multiple sources in priority order:
    /// 1. `HF_TOKEN` environment variable
    /// 2. `HUGGING_FACE_HUB_TOKEN` environment variable
    /// 3. File at path specified by `HF_TOKEN_PATH` environment variable
    /// 4. File at `$HF_HOME/token`
    /// 5. File at `~/.cache/huggingface/token` (standard HF CLI location)
    /// 6. File at `~/.huggingface/token` (fallback location)
    ///
    /// This is the default behavior for most Hugging Face clients and follows
    /// the same token detection logic as the Hugging Face CLI.
    ///
    /// > Note: `Auth.env` and `Auth.provider(.environment)` consult the same
    /// > six-source chain – both call `resolveEnvironmentToken()`. Pick
    /// > `Auth.env` for one-shot resolution at `HFClient.init` time;
    /// > pick `Auth.provider(.environment)` when you want the chain to be
    /// > re-run before every Hub request (e.g. so a freshly-written
    /// > `~/.cache/huggingface/token` is picked up without rebuilding the
    /// > client).
    case environment

    /// An OAuth token provider that retrieves tokens asynchronously.
    ///
    /// Use this case for OAuth-based authentication flows. Create instances using
    /// the `TokenProvider.oauth(manager:)` factory method when using `OAuthManager`.
    ///
    /// - Parameter getToken: A closure that retrieves a valid OAuth token.
    case oauth(getToken: @Sendable () async throws -> String)

    /// A composite token provider that tries multiple providers in order.
    ///
    /// ```swift
    /// let client = try HFClient(auth: .provider(
    ///     .composite([
    ///         .oauth(manager: authManager),
    ///         .environment,
    ///         .fixed(token: "fallback"),
    ///     ])
    /// ))
    /// ```
    ///
    /// This provider attempts to get a token from each provider in the array
    /// until one succeeds. If all providers fail, it returns `nil`.
    ///
    /// - Parameter providers: An array of token providers to try in order.
    case composite([TokenProvider])

    /// A custom token provider with a user-defined implementation.
    ///
    /// Use this case when you need custom token retrieval logic, such as
    /// fetching from a keychain, making API calls, or implementing
    /// custom authentication flows.
    ///
    /// - Parameter implementation: A custom token retrieval function that returns a token or `nil`.
    case custom(@Sendable () async throws -> String?)

    /// Resolves a token from the provider.
    ///
    /// Returns whichever token the configured case produces – for
    /// ``composite(_:)``, tries each provider in order until one yields a
    /// non-nil token.
    ///
    /// - Returns: A valid bearer token, or `nil` if no authentication is available.
    /// - Throws: An error if token retrieval fails.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let provider = TokenProvider.fixed(token: "hf_abc123")
    /// let token = try await provider.token()
    /// // Returns: "hf_abc123"
    /// ```
    public func token() async throws -> String? {
        switch self {
        case .fixed(let token):
            return token

        case .environment:
            return resolveEnvironmentToken()

        case .oauth(let getToken):
            return try await getToken()

        case .composite(let providers):
            for provider in providers {
                if let token = try await provider.token() {
                    return token
                }
            }
            return nil

        case .custom(let implementation):
            return try await implementation()
        }
    }
}

// `TokenProvider.oauth(manager:)` lives in `HFAPIOAuth/TokenProvider+OAuth.swift`
// so that `HFAPIShared` does not need to depend on `OAuthManager`.

// MARK: -

/// Reads a token from the specified file path.
///
/// Expands tilde paths and handles file-reading errors gracefully – used by
/// the environment-token detection logic to read tokens from various file
/// locations.
///
/// - Parameter path: The path to the file containing the token. Supports tilde expansion.
/// - Returns: The token read from the file, or `nil` if the file does not exist or cannot be read.
private func readTokenFromPath(_ path: String) -> String? {
    let expandedPath = NSString(string: path).expandingTildeInPath
    return try? String(contentsOfFile: expandedPath, encoding: .utf8)
}

/// Synchronously resolves a token from the Hugging Face environment.
///
/// Matches the HF CLI and Python `huggingface_hub` library's six-source lookup:
///
/// 1. `HF_TOKEN` environment variable
/// 2. `HUGGING_FACE_HUB_TOKEN` environment variable
/// 3. File at path specified by `HF_TOKEN_PATH` environment variable
/// 4. File at `$HF_HOME/token`
/// 5. File at `~/.cache/huggingface/token` (standard HF CLI location)
/// 6. File at `~/.huggingface/token` (fallback location)
///
/// Used by `TokenProvider.environment.token()` and by `HFClient.init` when
/// `auth: .env` (the default) – exposed as `package` so the HFAPI module can
/// resolve once at construction time without going through the async provider.
///
/// - Parameter env: The environment variables to check. Defaults to `ProcessInfo.processInfo.environment`.
/// - Returns: The first valid token found, or `nil` if no token is available.
package func resolveEnvironmentToken(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    let tokenSources: [() -> String?] = [
        { env["HF_TOKEN"] },
        { env["HUGGING_FACE_HUB_TOKEN"] },
        {
            if let tokenPath = env["HF_TOKEN_PATH"] {
                return readTokenFromPath(tokenPath)
            }
            return nil
        },
        {
            if let hfHome = env["HF_HOME"] {
                let expandedPath = NSString(string: hfHome).expandingTildeInPath
                return readTokenFromPath("\(expandedPath)/token")
            }
            return nil
        },
        { readTokenFromPath("~/.cache/huggingface/token") },
        { readTokenFromPath("~/.huggingface/token") },
    ]

    return tokenSources
        .lazy
        .compactMap { $0()?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}
