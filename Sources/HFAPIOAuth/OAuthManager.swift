// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation
import HFAPIShared

#if canImport(AuthenticationServices)
    import AuthenticationServices
    import Observation

    /// A manager for handling Hugging Face OAuth authentication.
    ///
    /// - SeeAlso: [Hugging Face OAuth Documentation](https://huggingface.co/docs/api-inference/authentication)
    @available(macOS 14.0, iOS 17.0, *)
    @Observable
    @MainActor
    public final class OAuthManager {
        /// The default base URL for Hugging Face OAuth endpoints
        public static let defaultBaseURL = URL(string: "https://huggingface.co")!

        /// Whether the user is authenticated.
        public var isAuthenticated = false

        /// The authentication token.
        public var authToken: OAuthToken?

        let oauthClient: OAuthClient
        let tokenStorage: TokenStorage

        /// Whether ``loadStoredToken()`` has run to completion at least once
        /// since this manager was constructed. Allows ``validToken()`` to
        /// detect the "init has run but the stored-token probe has not"
        /// startup window and complete the load synchronously.
        private var hasLoadedStoredToken = false

        private static let logger = HFLog(
            subsystem: "co.huggingface.swift-hf-api",
            category: "OAuthManager"
        )

        /// Initializes a new authentication manager with the specified client and token storage.
        /// - Parameters:
        ///   - client: The OAuth client carrying the configured endpoints, redirect URL, and scopes.
        ///   - tokenStorage: The token storage to use for storing and retrieving tokens.
        /// - Returns: A new authentication manager.
        ///
        /// The manager begins loading any stored token in the background. If
        /// you need to read ``authToken`` or ``isAuthenticated`` synchronously
        /// right after construction, call ``loadStoredToken()`` once and await
        /// the result; ``validToken()`` also performs an on-demand load if
        /// the stored-token probe has not yet completed.
        public init(client: OAuthClient, tokenStorage: TokenStorage) {
            self.oauthClient = client
            self.tokenStorage = tokenStorage

            // Eagerly attempt to load an existing token. Callers that need a
            // deterministic load can `await loadStoredToken()` from a known
            // entry point; the fire-and-forget path here just covers the
            // common case where a UI binds to `authToken` and observes the
            // load completing.
            Task {
                await loadStoredToken()
            }
        }

        /// Initializes a new authentication manager with the specified configuration.
        /// - Parameters:
        ///   - baseURL: The base URL of the OAuth provider. Defaults to HuggingFace OAuth endpoint.
        ///   - clientID: The client ID.
        ///   - redirectURL: The redirect URL.
        ///   - scope: The scopes to request.
        ///   - keychainService: The service name for the keychain.
        ///   - keychainAccount: The account name for the keychain.
        /// - Throws: `OAuthError.invalidConfiguration` if any parameter is invalid.
        public convenience init(
            baseURL: URL = OAuthManager.defaultBaseURL,
            clientID: String,
            redirectURL: URL,
            scope: Set<Scope>,
            keychainService: String,
            keychainAccount: String
        ) throws {
            // Validate parameters at call site
            guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OAuthError.invalidConfiguration("Client ID cannot be empty")
            }

            guard !scope.isEmpty else {
                throw OAuthError.invalidConfiguration("Scope cannot be empty")
            }

            let configuration = OAuthClientConfiguration(
                baseURL: baseURL,
                redirectURL: redirectURL,
                clientID: clientID,
                scope: scope.map { $0.rawValue }.sorted().joined(separator: " ")
            )

            self.init(
                client: OAuthClient(configuration: configuration),
                tokenStorage: .keychain(service: keychainService, account: keychainAccount)
            )
        }

        /// Signs the user in by presenting [`ASWebAuthenticationSession`](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).
        ///
        /// - Parameter prefersEphemeralWebBrowserSession: When `true`, the
        ///   web session runs in a private mode and does not share cookies
        ///   or other browsing data with the user's regular browser. Use
        ///   this to force a fresh login each time rather than reusing an
        ///   existing Hub session. Defaults to `false`, matching the
        ///   previous (pure-Swift) behavior.
        public func signIn(prefersEphemeralWebBrowserSession: Bool = false) async throws {
            let ephemeral = prefersEphemeralWebBrowserSession
            let code = try await oauthClient.authenticate { @Sendable url, scheme in
                return try await withCheckedThrowingContinuation { continuation in
                    let authSession = ASWebAuthenticationSession(
                        url: url,
                        callbackURLScheme: scheme
                    ) { callbackURL, error in
                        if let error {
                            // `ASWebAuthenticationSession` returns
                            // framework-typed errors. Classify the
                            // user-cancel case (the common one) so
                            // consumers don't have to substring-match on
                            // "error 1" to spot it, and wrap everything
                            // else with the underlying message preserved
                            // for diagnostics. Matches the project's
                            // `swift-error-handling-ui.md` rule.
                            let nsError = error as NSError
                            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                                nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                            {
                                continuation.resume(throwing: OAuthError.signInCanceled)
                            } else {
                                continuation.resume(
                                    throwing: OAuthError.sessionFailed(
                                        underlying: error.localizedDescription
                                    )
                                )
                            }
                            return
                        }

                        guard let url = callbackURL else {
                            continuation.resume(throwing: OAuthError.invalidCallback)
                            return
                        }

                        // Hand the full callback URL back to `authenticate`.
                        // State validation, provider-error extraction, and
                        // code parsing all happen there in one place.
                        continuation.resume(returning: url)
                    }

                    Task { @MainActor in
                        authSession.prefersEphemeralWebBrowserSession = ephemeral
                        authSession.presentationContextProvider =
                            OAuthPresentationContextProvider.shared

                        if !authSession.start() {
                            continuation.resume(throwing: OAuthError.sessionFailedToStart)
                        }
                    }
                }
            }

            let token = try await oauthClient.exchangeCode(code)
            // Commit the in-memory session before persisting so a transient
            // storage failure (e.g., keychain locked) doesn't discard a
            // successfully exchanged token. The current process still has a
            // usable session; the user re-signs in on next launch if
            // persistence keeps failing.
            self.authToken = token
            self.isAuthenticated = true
            do {
                try tokenStorage.store(token)
            } catch {
                logStorageWriteFailure(error)
            }
        }

        /// Signs the user out.
        public func signOut() async {
            do {
                try tokenStorage.delete()
            } catch {
                // Sign out should always succeed from the caller's perspective;
                // a storage deletion failure is logged but never thrown.
                logStorageDeletionFailure(error)
            }

            self.isAuthenticated = false
            self.authToken = nil
        }

        /// Returns the current valid access token, refreshing via the
        /// stored refresh token if the cached access token has expired.
        ///
        /// - Returns: The valid access token.
        /// - Throws: ``OAuthError/authenticationRequired`` if no valid
        ///   token is available and refresh fails.
        public func validToken() async throws -> String {
            // If the manager was constructed but `loadStoredToken()` from
            // `init` has not finished yet, drive it to completion here so
            // the caller sees the persisted token rather than the
            // not-yet-loaded `nil`. `@MainActor` re-entrancy means the
            // `await` here serializes against the in-flight load – the
            // second arrival waits on `hasLoadedStoredToken` flipping.
            if !hasLoadedStoredToken {
                await loadStoredToken()
            }

            if let token = authToken, token.isValid {
                return token.accessToken
            }

            // Token expired, try refresh
            guard let token = authToken,
                let refreshToken = token.refreshToken
            else {
                throw OAuthError.authenticationRequired
            }

            let newToken: OAuthToken
            do {
                newToken = try await oauthClient.refreshToken(using: refreshToken)
            } catch {
                // Refresh failed: require re-authentication.
                self.isAuthenticated = false
                throw OAuthError.authenticationRequired
            }

            // Commit the refreshed token in-memory before persisting. A
            // storage failure shouldn't invalidate a token the server has
            // already minted – the next call returns immediately from the
            // valid cache; persistence retries naturally on the next
            // refresh.
            self.authToken = newToken
            do {
                try tokenStorage.store(newToken)
            } catch {
                logStorageWriteFailure(error)
            }
            return newToken.accessToken
        }

        /// Load any persisted token from storage. Safe to call multiple times
        /// – second and subsequent calls return immediately.
        ///
        /// Normally callers don't need this; the manager's `init` already
        /// spawns a load in the background. Use it when you need a
        /// deterministic point at which `authToken`/`isAuthenticated` reflect
        /// the persisted state – e.g., right after constructing the manager
        /// in an app launch path that immediately gates UI on
        /// `isAuthenticated`.
        public func loadStoredToken() async {
            // Concurrent callers are safe without explicit Task memoization:
            // `OAuthManager` is `@MainActor`, and the body below contains no
            // `await` points (`tokenStorage.retrieve()` is synchronous). Two
            // tasks calling `loadStoredToken()` serialize on the actor; the
            // first runs the entire body atomically and flips
            // `hasLoadedStoredToken`, the second short-circuits at the guard.
            // If `TokenStorage.retrieve()` ever becomes `async`, revisit –
            // an await between the guard and the flag flip would reopen the
            // race.
            guard !hasLoadedStoredToken else { return }
            defer { hasLoadedStoredToken = true }

            do {
                guard let token = try tokenStorage.retrieve() else {
                    return
                }

                // Load the token even if `token.isValid` is false. An
                // expired token with a refresh token is exactly the input
                // `validToken()` needs to drive the refresh path –
                // dropping it here would force the user to sign in again
                // on every app launch.
                self.authToken = token
                self.isAuthenticated = token.isValid
            } catch {
                logStoredTokenLoadFailure(error)
                do {
                    try tokenStorage.delete()
                } catch {
                    logStorageDeletionFailure(error)
                }
            }
        }

        private func logStorageDeletionFailure(_ error: Error) {
            Self.logger.error("Token storage deletion failed: \(error.localizedDescription)")
        }

        private func logStorageWriteFailure(_ error: Error) {
            Self.logger.error("Token storage write failed: \(error.localizedDescription)")
        }

        private func logStoredTokenLoadFailure(_ error: Error) {
            Self.logger.error("Failed to load stored token: \(error.localizedDescription)")
        }
    }

    // MARK: -

    @available(macOS 14.0, iOS 17.0, *)
    extension OAuthManager {
        /// OAuth scopes supported by HuggingFace
        public enum Scope: Hashable, Sendable {
            /// Get the ID token in addition to the access token
            case openid

            /// Get the user's profile information (username, avatar, etc.)
            case profile

            /// Get the user's email address
            case email

            /// Know whether the user has a payment method set up
            case readBilling

            /// Get read access to the user's personal repos
            case readRepos

            /// Get write/read access to the user's personal repos
            case writeRepos

            /// Get full access to the user's personal repos. Also grants repo creation and deletion
            case manageRepos

            /// Get access to the Inference API, you will be able to make inference requests on behalf of the user
            case inferenceAPI

            /// Open discussions and Pull Requests on behalf of the user as well as interact with discussions
            case writeDiscussions

            /// A custom or unknown scope
            case other(String)

            /// Human-readable display name for the scope. Suitable for
            /// consent prompts or UI that asks the user to authorize a
            /// scope. The raw OAuth wire value is available via
            /// ``rawValue``.
            public var displayName: String {
                switch self {
                case .openid:
                    return "Get the ID token in addition to the access token"
                case .profile:
                    return "Get the user's profile information (username, avatar, etc.)"
                case .email:
                    return "Get the user's email address"
                case .readBilling:
                    return "Know whether the user has a payment method set up"
                case .readRepos:
                    return "Get read access to the user's personal repos"
                case .writeRepos:
                    return "Get write/read access to the user's personal repos"
                case .manageRepos:
                    return "Get full access to the user's personal repos. Also grants repo creation and deletion"
                case .inferenceAPI:
                    return
                        "Get access to the Inference API, you will be able to make inference requests on behalf of the user"
                case .writeDiscussions:
                    return
                        "Open discussions and Pull Requests on behalf of the user as well as interact with discussions"
                case .other(let value):
                    return value
                }
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    extension OAuthManager.Scope: RawRepresentable {
        public init(rawValue: String) {
            switch rawValue {
            case "openid":
                self = .openid
            case "profile":
                self = .profile
            case "email":
                self = .email
            case "read-billing":
                self = .readBilling
            case "read-repos":
                self = .readRepos
            case "write-repos":
                self = .writeRepos
            case "manage-repos":
                self = .manageRepos
            case "inference-api":
                self = .inferenceAPI
            case "write-discussions":
                self = .writeDiscussions
            default:
                self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .openid:
                return "openid"
            case .profile:
                return "profile"
            case .email:
                return "email"
            case .readBilling:
                return "read-billing"
            case .readRepos:
                return "read-repos"
            case .writeRepos:
                return "write-repos"
            case .manageRepos:
                return "manage-repos"
            case .inferenceAPI:
                return "inference-api"
            case .writeDiscussions:
                return "write-discussions"
            case .other(let value):
                return value
            }
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    extension OAuthManager.Scope: Codable {
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self.init(rawValue: rawValue)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    extension OAuthManager.Scope: ExpressibleByStringLiteral {
        public init(stringLiteral value: String) {
            self = Self(rawValue: value)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    extension Set<OAuthManager.Scope> {
        public static var basic: Self { [.openid, .profile, .email] }
        public static var readAccess: Self { [.openid, .profile, .email, .readRepos] }
        public static var writeAccess: Self { [.openid, .profile, .email, .writeRepos] }
        public static var fullAccess: Self { [.openid, .profile, .email, .manageRepos, .inferenceAPI] }
        public static var inferenceOnly: Self { [.openid, .inferenceAPI] }
        public static var discussions: Self { [.openid, .profile, .email, .writeDiscussions] }
    }

    // MARK: -

    @available(macOS 14.0, iOS 17.0, *)
    extension OAuthManager {
        /// A mechanism for storing and retrieving OAuth tokens.
        public struct TokenStorage: Sendable {
            /// A function for storing an OAuth token.
            public var store: @Sendable (OAuthToken) throws -> Void

            /// A function for retrieving an OAuth token.
            public var retrieve: @Sendable () throws -> OAuthToken?

            /// A function for deleting an OAuth token.
            public var delete: @Sendable () throws -> Void

            public init(
                store: @escaping @Sendable (OAuthToken) throws -> Void,
                retrieve: @escaping @Sendable () throws -> OAuthToken?,
                delete: @escaping @Sendable () throws -> Void
            ) {
                self.store = store
                self.retrieve = retrieve
                self.delete = delete
            }

            /// A mechanism for storing and retrieving OAuth tokens using the keychain.
            /// - Parameters:
            ///   - service: The service name for the keychain item.
            ///   - account: The account name for the keychain item.
            /// - Returns: A new token storage mechanism.
            public static func keychain(service: String, account: String) -> TokenStorage {
                return TokenStorage(
                    store: { token in
                        let encoder = JSONEncoder()
                        let data = try encoder.encode(token)

                        let query: [String: Any] = [
                            kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account,
                            kSecValueData as String: data,
                            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                        ]

                        // Delete existing item if present
                        SecItemDelete(query as CFDictionary)

                        let status = SecItemAdd(query as CFDictionary, nil)
                        guard status == errSecSuccess else {
                            throw OAuthError.tokenStorageError(operation: .store, status: status)
                        }
                    },
                    retrieve: {
                        let query: [String: Any] = [
                            kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account,
                            kSecReturnData as String: true,
                            kSecMatchLimit as String: kSecMatchLimitOne,
                        ]

                        var item: CFTypeRef?
                        let status = SecItemCopyMatching(query as CFDictionary, &item)

                        guard status != errSecItemNotFound else {
                            return nil
                        }

                        guard status == errSecSuccess,
                            let data = item as? Data
                        else {
                            throw OAuthError.tokenStorageError(operation: .retrieve, status: status)
                        }

                        let decoder = JSONDecoder()
                        return try decoder.decode(OAuthToken.self, from: data)
                    },
                    delete: {
                        let query: [String: Any] = [
                            kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account,
                        ]

                        let status = SecItemDelete(query as CFDictionary)
                        guard status == errSecSuccess || status == errSecItemNotFound else {
                            throw OAuthError.tokenStorageError(operation: .delete, status: status)
                        }
                    }
                )
            }

            /// Bridges a ``FileTokenStorage`` (the cross-platform on-disk
            /// implementation in this module) into the manager's closure-based
            /// ``TokenStorage`` value. Use this on Linux or anywhere keychain
            /// isn't available, then pass the result to the
            /// ``OAuthManager/init(client:tokenStorage:)``
            /// initializer.
            public static func file(_ storage: FileTokenStorage) -> TokenStorage {
                TokenStorage(
                    store: { try storage.store($0) },
                    retrieve: { try storage.retrieve() },
                    delete: { try storage.delete() }
                )
            }
        }
    }
#endif  // canImport(AuthenticationServices)

// MARK: -

// `OAuthPresentationContextProvider` is an internal implementation detail
// of ``OAuthManager/signIn()``. It satisfies
// `ASWebAuthenticationPresentationContextProviding` against the current
// key window. Consumers cannot substitute their own provider because
// `signIn()` doesn't take one – exposing the type publicly would imply an
// extension point that doesn't exist. If we ever surface a hook for
// custom presentation, flip this back to `public`.

#if canImport(AppKit) && canImport(AuthenticationServices)
    import AppKit

    @MainActor
    final class OAuthPresentationContextProvider: NSObject,
        ASWebAuthenticationPresentationContextProviding
    {
        static let shared: OAuthPresentationContextProvider = .init()

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            // Return the first window or the key window, or a default anchor if no windows are available.
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
#endif  // canImport(AppKit) && canImport(AuthenticationServices)

#if canImport(UIKit) && canImport(AuthenticationServices)
    import UIKit

    @MainActor
    final class OAuthPresentationContextProvider: NSObject,
        ASWebAuthenticationPresentationContextProviding
    {
        static let shared: OAuthPresentationContextProvider = .init()

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            // Return the key window's root view controller, or the first window's root view controller
            if let keyWindow = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })
            {
                return keyWindow
            }

            // Fallback to the first window
            if let firstWindow = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first
            {
                return firstWindow
            }

            // Last resort - return a default anchor
            return ASPresentationAnchor()
        }
    }
#endif  // canImport(UIKit) && canImport(AuthenticationServices)
