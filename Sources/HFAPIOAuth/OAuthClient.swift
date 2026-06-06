// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An OAuth 2.0 client for handling authentication flows
/// with support for token caching, refresh, and secure code exchange
/// using PKCE (Proof Key for Code Exchange).
public actor OAuthClient: Sendable {
    /// The OAuth client configuration.
    public let configuration: OAuthClientConfiguration

    /// The URL session to use for network requests.
    let urlSession: URLSession

    /// In-flight token refresh, deduplicated across callers so a second
    /// concurrent caller awaits the first refresh's result rather than
    /// starting a duplicate exchange.
    private var refreshTask: Task<OAuthToken, Error>?
    private var codeVerifier: String?

    /// The opaque `state` value attached to the most recent in-flight
    /// authorization request. Compared against the value returned in the
    /// callback URL to defend against login-CSRF/session-fixation
    /// (RFC 6749 §10.12).
    private var expectedState: String?

    /// Initializes a new OAuth client with the specified configuration.
    /// - Parameters:
    ///   - configuration: The OAuth configuration containing client credentials and endpoints.
    ///   - session: The URL session to use for network requests. Defaults to `.shared`.
    public init(configuration: OAuthClientConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = session
    }

    /// Initiates the OAuth authentication flow using PKCE (Proof Key for Code Exchange).
    ///
    /// This method generates PKCE values plus a CSRF `state` token, constructs the
    /// authorization URL, and hands it to `handler` to drive the web session. The
    /// handler returns the full callback URL it received from the provider;
    /// `authenticate` then parses and validates `state`, `error`, and `code` from
    /// the callback.
    ///
    /// - Parameter handler: A closure that presents the authorization URL and
    ///   returns the callback URL the provider redirected to.
    /// - Returns: The authorization code from the OAuth callback.
    /// - Throws: ``OAuthError/sessionFailedToStart`` if the URL cannot be built.
    /// - Throws: ``OAuthError/providerError(code:description:)`` if the callback
    ///   carries `error=…&error_description=…` instead of a code.
    /// - Throws: ``OAuthError/stateMismatch`` if the callback's `state` does not
    ///   match the value we attached to the authorization request.
    /// - Throws: ``OAuthError/invalidCallback`` if the callback URL is missing
    ///   the `code` parameter.
    public func authenticate(handler: @escaping (URL, String) async throws -> URL)
        async throws -> String
    {
        // Generate PKCE values plus a CSRF state token bound to this
        // authorization request.
        let (verifier, challenge) = Self.generatePKCEValues()
        let state = Self.generateState()
        self.codeVerifier = verifier
        self.expectedState = state

        // Build authorization URL
        let authURL = configuration.baseURL.appendingPathComponent("oauth/authorize")
        guard var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.sessionFailedToStart
        }
        components.queryItems = [
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: configuration.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]

        guard let finalAuthURL = components.url,
            let scheme = configuration.redirectURL.scheme
        else {
            throw OAuthError.sessionFailedToStart
        }

        let callbackURL = try await handler(finalAuthURL, scheme)

        // Always consume the expected state, even on failure paths, so a
        // replayed or stale callback cannot succeed against a future
        // authorization attempt.
        let expected = expectedState
        self.expectedState = nil

        let callbackItems =
            URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems ?? []

        // Provider error path first: if `error` is present, the provider
        // rejected the request. Surface code + description verbatim.
        if let errorCode = callbackItems.first(where: { $0.name == "error" })?.value,
            !errorCode.isEmpty
        {
            let description = callbackItems.first(where: { $0.name == "error_description" })?.value
            throw OAuthError.providerError(code: errorCode, description: description)
        }

        // Validate state before trusting any other query parameter. Constant-
        // time compare is overkill for a UUID-shaped token but cheap and
        // unambiguous about intent.
        let returnedState = callbackItems.first(where: { $0.name == "state" })?.value
        guard let expected, let returnedState,
            Self.constantTimeEquals(expected, returnedState)
        else {
            throw OAuthError.stateMismatch
        }

        guard let code = callbackItems.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else {
            throw OAuthError.invalidCallback
        }

        return code
    }

    /// Exchanges an authorization code for an OAuth token using PKCE.
    ///
    /// This method takes the authorization code received from the OAuth callback and exchanges
    /// it for an access token and refresh token. The code verifier generated during authentication
    /// is used to complete the PKCE flow for security.
    ///
    /// - Parameter code: The authorization code from the OAuth callback.
    /// - Returns: An OAuth token containing access and refresh tokens.
    /// - Throws: ``OAuthError/missingCodeVerifier`` if no code verifier is available.
    /// - Throws: ``OAuthError/tokenExchangeFailed(statusCode:error:description:)`` if the token exchange request fails.
    public func exchangeCode(_ code: String) async throws -> OAuthToken {
        guard let verifier = codeVerifier else {
            throw OAuthError.missingCodeVerifier
        }

        let tokenURL = configuration.baseURL.appendingPathComponent("oauth/token")
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "code_verifier", value: verifier),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
            !(200 ... 299).contains(httpResponse.statusCode)
        {
            throw Self.makeExchangeFailure(statusCode: httpResponse.statusCode, body: data)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let token = OAuthToken(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )

        self.codeVerifier = nil

        return token
    }

    /// Refreshes an OAuth token using a refresh token.
    ///
    /// This method prevents multiple concurrent refresh operations by tracking an active refresh task.
    /// If a refresh is already in progress, it waits for that refresh to complete rather than
    /// starting a new one.
    ///
    /// - Parameter refreshToken: The refresh token to use for obtaining a new access token.
    /// - Returns: A new OAuth token with updated access and refresh tokens.
    /// - Throws: ``OAuthError/tokenExchangeFailed(statusCode:error:description:)`` if the refresh request fails.
    public func refreshToken(using refreshToken: String) async throws -> OAuthToken {
        // Start refresh task if not already running
        if let task = refreshTask {
            return try await task.value
        }

        let task = Task<OAuthToken, Error> {
            try await performRefresh(refreshToken: refreshToken)
        }
        refreshTask = task

        // `defer` runs on the actor (this whole function is actor-isolated),
        // so the clear is synchronous. The previous `Task { … }` form
        // deferred the clear to a future actor-hop, briefly leaving the
        // completed task observable to a concurrent caller – which would
        // either dogpile on the stale handle or skip starting a new
        // refresh because it found a stale-but-non-nil entry.
        defer { refreshTask = nil }

        return try await task.value
    }

    private func performRefresh(refreshToken: String) async throws -> OAuthToken {
        let tokenURL = configuration.baseURL.appendingPathComponent("oauth/token")
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: configuration.clientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
            !(200 ... 299).contains(httpResponse.statusCode)
        {
            throw Self.makeExchangeFailure(statusCode: httpResponse.statusCode, body: data)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let token = OAuthToken(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )

        return token
    }

    /// Builds a ``OAuthError/tokenExchangeFailed(statusCode:error:description:)``
    /// case from a non-2xx response, decoding the RFC 6749 §5.2 error body
    /// when one is present. Falls back to status code only when the body is
    /// empty, non-JSON, or otherwise unparseable.
    private static func makeExchangeFailure(statusCode: Int, body: Data) -> OAuthError {
        guard !body.isEmpty,
            let decoded = try? JSONDecoder().decode(TokenErrorResponse.self, from: body)
        else {
            return .tokenExchangeFailed(statusCode: statusCode, error: nil, description: nil)
        }
        return .tokenExchangeFailed(
            statusCode: statusCode,
            error: decoded.error,
            description: decoded.errorDescription
        )
    }

    /// Generates an opaque `state` token suitable for binding an authorization
    /// request to its callback. 32 bytes of CSPRNG → url-safe base64 → 43
    /// characters. Same entropy source as the PKCE verifier.
    private static func generateState() -> String {
        Data(secureRandomBytes(count: 32)).urlSafeBase64EncodedString()
    }

    /// Returns `count` cryptographically secure random bytes. On Apple
    /// platforms we prefer Security.framework's CSPRNG; if that ever fails
    /// we fall back to `SystemRandomNumberGenerator`, which is also
    /// documented as cryptographically secure. Checking the
    /// `SecRandomCopyBytes` status is essential – the previous implementation
    /// discarded it, which would leave `buffer` as all-zero bytes on failure
    /// and defeat PKCE entirely.
    private static func secureRandomBytes(count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = false
        #if os(macOS) || os(iOS)
            filled = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess
        #endif
        if !filled {
            var generator = SystemRandomNumberGenerator()
            buffer = buffer.map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
        }
        return buffer
    }

    /// Length-independent constant-time string compare for short opaque
    /// tokens. The state value is not strictly secret (it's visible in the
    /// callback URL), but constant-time compare avoids early-exit signals
    /// on partial-prefix matches and is cheap.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count {
            return false
        }
        var diff: UInt8 = 0
        for i in 0 ..< aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    /// Generates PKCE code verifier and challenge values as a tuple.
    /// - Returns: A tuple containing the code verifier and its corresponding challenge.
    private static func generatePKCEValues() -> (verifier: String, challenge: String) {
        let verifier = Data(secureRandomBytes(count: 32)).urlSafeBase64EncodedString()
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hashed).urlSafeBase64EncodedString()
        return (verifier, challenge)
    }
}

// MARK: -

/// Configuration for OAuth authentication client
public struct OAuthClientConfiguration: Sendable {
    /// The base URL for OAuth endpoints
    public let baseURL: URL

    /// The redirect URL for OAuth callbacks
    public let redirectURL: URL

    /// The OAuth client ID
    public let clientID: String

    /// The scopes for OAuth requests as a space-separated string
    public let scope: String

    /// Initializes a new OAuth configuration with the specified parameters.
    /// - Parameters:
    ///   - baseURL: The base URL for OAuth endpoints.
    ///   - redirectURL: The redirect URL for OAuth callbacks.
    ///   - clientID: The OAuth client ID.
    ///   - scope: The scopes for OAuth requests.
    public init(
        baseURL: URL,
        redirectURL: URL,
        clientID: String,
        scope: String
    ) {
        self.baseURL = baseURL
        self.redirectURL = redirectURL
        self.clientID = clientID
        self.scope = scope
    }
}

// MARK: -

/// OAuth token containing access and refresh tokens
public struct OAuthToken: Sendable, Codable {
    /// The access token
    public let accessToken: String

    /// The refresh token
    public let refreshToken: String?

    /// The expiration date of the token
    public let expiresAt: Date

    /// Margin subtracted from ``expiresAt`` so requests fired near the
    /// expiration boundary don't race the server's clock.
    private static let expirationSkew: TimeInterval = 5 * 60

    /// Whether the token is valid
    public var isValid: Bool {
        Date() < expiresAt.addingTimeInterval(-Self.expirationSkew)
    }

    /// Initializes a new OAuth token with the specified parameters.
    /// - Parameters:
    ///   - accessToken: The access token.
    ///   - refreshToken: The refresh token.
    ///   - expiresAt: The expiration date of the token.
    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

/// The token-storage operation that produced an ``OAuthError/tokenStorageError(operation:status:)``.
public enum TokenStorageOperation: String, Sendable, Equatable {
    case store
    case retrieve
    case delete
}

/// OAuth error enum
public enum OAuthError: LocalizedError, Equatable, Sendable {
    /// The user needs to sign in (no stored token, or refresh failed).
    case authenticationRequired

    /// The callback URL was missing the `code` query item or otherwise malformed.
    case invalidCallback

    /// The `state` query item in the callback URL did not match the value
    /// the client attached to the authorization request. RFC 6749 §10.12
    /// requires rejecting such callbacks: they typically indicate a
    /// login-CSRF/session-fixation attempt.
    case stateMismatch

    /// The OAuth provider returned an error in the callback URL
    /// (`?error=…&error_description=…`). The `code` is the machine-readable
    /// reason from the provider (e.g., `"access_denied"`,
    /// `"consent_required"`); `description` is the human-readable text the
    /// provider attached, if any.
    case providerError(code: String, description: String?)

    /// [`ASWebAuthenticationSession`](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
    /// could not be started, or the authorization URL could not be built.
    case sessionFailedToStart

    /// `exchangeCode(_:)` was called before `authenticate(handler:)`
    /// completed, so no PKCE verifier is available.
    case missingCodeVerifier

    /// The token endpoint returned a non-2xx status. RFC 6749 §5.2 specifies
    /// the body shape `{ "error": "...", "error_description": "..." }`;
    /// `error` and `description` are decoded from that body when present.
    case tokenExchangeFailed(statusCode: Int, error: String?, description: String?)

    /// A keychain operation backing the manager's token storage failed.
    /// The `status` is the underlying `OSStatus` (typed as `Int32` for
    /// cross-platform compatibility); on Apple platforms callers can pass it
    /// to `SecCopyErrorMessageString` to render a human-readable description.
    /// Non-keychain storage backends bubble their own typed errors through
    /// the closure-based ``OAuthManager/TokenStorage`` API instead.
    case tokenStorageError(operation: TokenStorageOperation, status: Int32)

    /// Configuration validation failed (empty client ID, empty scope, etc.).
    case invalidConfiguration(String)

    /// The user cancelled the web-authentication session before the
    /// provider redirected back to the app. Distinct from
    /// ``sessionFailed(underlying:)`` (transport / system error) so callers
    /// can drop the user back to a "sign in" entry point rather than
    /// showing an error alert.
    case signInCanceled

    /// The web-authentication session failed for a reason other than
    /// user cancellation. `underlying` is the system error's
    /// `localizedDescription` rather than the raw `NSError`, so the
    /// payload stays `Equatable` and `Sendable` without leaking
    /// framework-specific types across the boundary.
    case sessionFailed(underlying: String)

    /// The error description
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Sign in is required to continue."
        case .invalidCallback:
            return "The OAuth callback was malformed or missing required data."
        case .stateMismatch:
            return "The OAuth callback did not match the authorization request and was rejected."
        case .providerError(let code, let description):
            if let description, !description.isEmpty {
                return "OAuth provider error (\(code)): \(description)"
            }
            return "OAuth provider error: \(code)"
        case .sessionFailedToStart:
            return "Could not start the sign-in session."
        case .missingCodeVerifier:
            return "OAuth code exchange was attempted without first authorizing."
        case .tokenExchangeFailed(let statusCode, let error, let description):
            var pieces: [String] = ["Token exchange failed (HTTP \(statusCode))"]
            if let error, !error.isEmpty {
                pieces.append(error)
            }
            if let description, !description.isEmpty {
                pieces.append(description)
            }
            return pieces.joined(separator: ": ")
        case .tokenStorageError(let operation, let status):
            return "Token storage \(operation.rawValue) failed (status \(status))"
        case .invalidConfiguration(let error):
            return "Invalid OAuth configuration: \(error)"
        case .signInCanceled:
            return "Sign in was cancelled."
        case .sessionFailed(let underlying):
            return "Sign in failed: \(underlying)"
        }
    }
}

/// Server-side error body returned by the OAuth token endpoint on non-2xx
/// responses, per RFC 6749 §5.2.
private struct TokenErrorResponse: Sendable, Codable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct TokenResponse: Sendable, Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: -

private extension Data {
    /// Returns a URL-safe Base64 encoded string suitable for use in URLs and OAuth flows.
    ///
    /// This method applies the standard Base64 encoding and then replaces characters
    /// that are not URL-safe (+ becomes -, / becomes _, = padding is removed).
    /// - Returns: A URL-safe Base64 encoded string.
    func urlSafeBase64EncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
