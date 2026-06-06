// Copyright © Anthony DePasquale

import Foundation
import HFAPIShared

#if canImport(AuthenticationServices)
    import Observation

    extension TokenProvider {
        /// Creates an OAuth token provider using ``OAuthManager``.
        ///
        /// Use this factory method for OAuth-based authentication flows. The authentication
        /// manager handles the complete OAuth flow including token refresh.
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
        /// - Parameter manager: The OAuth authentication manager that handles token retrieval and refresh.
        /// - Returns: A token provider that retrieves tokens from the authentication manager.
        @available(macOS 14.0, iOS 17.0, *)
        public static func oauth(manager: OAuthManager) -> TokenProvider {
            return .oauth(getToken: { @MainActor in
                try await manager.validToken()
            })
        }
    }
#endif
