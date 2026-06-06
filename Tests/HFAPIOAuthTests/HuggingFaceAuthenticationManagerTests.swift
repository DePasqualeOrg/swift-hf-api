// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@testable import HFAPIOAuth
import HFAPIShared

#if swift(>=6.1) && canImport(AuthenticationServices)
    @Suite("HuggingFace Authentication Manager Tests")
    struct OAuthManagerTests {
        @Test("OAuthManager can be initialized with valid parameters")
        @MainActor
        func testManagerInitialization() async throws {
            let manager = try OAuthManager(
                clientID: "test_client_id",
                redirectURL: URL(string: "myapp://oauth/callback")!,
                scope: [.openid, .profile],
                keychainService: "test_service",
                keychainAccount: "test_account"
            )

            #expect(manager.isAuthenticated == false)
            #expect(manager.authToken == nil)
            let configuration = await manager.oauthClient.configuration
            #expect(configuration.baseURL == OAuthManager.defaultBaseURL)
            #expect(configuration.clientID == "test_client_id")
            #expect(configuration.redirectURL == URL(string: "myapp://oauth/callback")!)
            #expect(configuration.scope == "openid profile")
        }

        @Test("OAuthManager validates input parameters")
        @MainActor
        func testManagerValidation() async throws {
            // Test valid initialization
            let validManager = try OAuthManager(
                clientID: "test_client_id",
                redirectURL: URL(string: "myapp://oauth/callback")!,
                scope: [.openid, .profile],
                keychainService: "test_service",
                keychainAccount: "test_account"
            )
            #expect(validManager.isAuthenticated == false)

            // Test invalid client ID
            #expect(throws: OAuthError.invalidConfiguration("Client ID cannot be empty")) {
                try OAuthManager(
                    clientID: "",
                    redirectURL: URL(string: "myapp://oauth/callback")!,
                    scope: [.openid, .profile],
                    keychainService: "test_service",
                    keychainAccount: "test_account"
                )
            }
        }

        @Test("OAuthManager sign out clears state")
        @MainActor
        func testSignOut() async throws {
            let manager = try OAuthManager(
                clientID: "test_client_id",
                redirectURL: URL(string: "myapp://oauth/callback")!,
                scope: [.openid, .profile],
                keychainService: "test_service",
                keychainAccount: "test_account"
            )

            // Initially not authenticated
            #expect(manager.isAuthenticated == false)
            #expect(manager.authToken == nil)

            // Sign out should not throw and should maintain unauthenticated state
            await manager.signOut()

            #expect(manager.isAuthenticated == false)
            #expect(manager.authToken == nil)
        }

        @Test("OAuthManager validToken throws when not authenticated")
        @MainActor
        func testValidTokenWhenNotAuthenticated() async throws {
            let manager = try OAuthManager(
                clientID: "test_client_id",
                redirectURL: URL(string: "myapp://oauth/callback")!,
                scope: [.openid, .profile],
                keychainService: "test_service",
                keychainAccount: "test_account"
            )

            await #expect(throws: OAuthError.authenticationRequired) {
                try await manager.validToken()
            }
        }

        @Test(
            "OAuthManager refreshes an expired token via the OAuth client",
            .mockURLSession
        )
        @MainActor
        func testGetValidTokenRefreshesExpiredToken() async throws {
            // Mock the Hub's /oauth/token endpoint with a successful refresh
            // response. The assertion on `grant_type=refresh_token` locks
            // the contract – a regression that issued an authorization-code
            // grant instead would still get a 200 from the mock and silently
            // pass otherwise.
            await MockURLProtocol.setHandler { request in
                let body: String =
                    if let data = request.httpBody {
                        String(data: data, encoding: .utf8) ?? ""
                    } else if let stream = request.httpBodyStream {
                        readStreamToString(stream)
                    } else {
                        ""
                    }
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("refresh_token=stale_refresh"))

                let json = """
                    {
                      "access_token": "fresh_access",
                      "refresh_token": "fresh_refresh",
                      "expires_in": 3600,
                      "token_type": "Bearer"
                    }
                    """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, json.data(using: .utf8)!)
            }

            let stored = OAuthToken(
                accessToken: "stale_access",
                refreshToken: "stale_refresh",
                expiresAt: Date().addingTimeInterval(-60)  // already expired
            )
            let storage = InMemoryTokenStorage(initial: stored)

            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MockURLProtocol.self]
            let mockSession = URLSession(configuration: sessionConfig)
            let oauthClient = OAuthClient(configuration: config, session: mockSession)

            let manager = OAuthManager(
                client: oauthClient,
                tokenStorage: storage.tokenStorage
            )

            // First call should refresh and return the new access token.
            let token = try await manager.validToken()
            #expect(token == "fresh_access")
            // Manager's in-memory token should be the refreshed one.
            #expect(manager.authToken?.accessToken == "fresh_access")
            #expect(manager.authToken?.refreshToken == "fresh_refresh")
            // Storage should have been updated.
            let persisted = storage.retrieve()
            #expect(persisted?.accessToken == "fresh_access")
        }

        @Test(
            "OAuthManager clears isAuthenticated when refresh fails",
            .mockURLSession
        )
        @MainActor
        func testGetValidTokenClearsAuthOnRefreshFailure() async throws {
            // Mock returns 400 for the refresh request – simulates an
            // expired or revoked refresh token. The manager should mark
            // itself unauthenticated and propagate
            // `authenticationRequired` rather than the underlying
            // `tokenExchangeFailed`.
            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }

            let stored = OAuthToken(
                accessToken: "stale_access",
                refreshToken: "stale_refresh",
                expiresAt: Date().addingTimeInterval(-60)
            )
            let storage = InMemoryTokenStorage(initial: stored)

            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MockURLProtocol.self]
            let mockSession = URLSession(configuration: sessionConfig)
            let oauthClient = OAuthClient(configuration: config, session: mockSession)

            let manager = OAuthManager(
                client: oauthClient,
                tokenStorage: storage.tokenStorage
            )

            // Manager should surface authenticationRequired after the
            // refresh fails – not the underlying tokenExchangeFailed.
            await #expect(throws: OAuthError.authenticationRequired) {
                try await manager.validToken()
            }
            #expect(manager.isAuthenticated == false)
        }
    }

    @Suite("Hugging Face OAuth Scope Tests", .serialized)
    struct HuggingFaceScopeTests {
        typealias Scope = OAuthManager.Scope

        @Test("OAuth Scope sets work correctly")
        func testScopeSets() {
            // Test basic scope set
            let basicScopes = Set<Scope>.basic
            #expect(basicScopes.contains(.openid))
            #expect(basicScopes.contains(.profile))
            #expect(basicScopes.contains(.email))

            // Test read access scope set
            let readScopes = Set<Scope>.readAccess
            #expect(readScopes.contains(.readRepos))

            // Test write access scope set
            let writeScopes = Set<Scope>.writeAccess
            #expect(writeScopes.contains(.writeRepos))

            // Test full access scope set
            let fullScopes = Set<Scope>.fullAccess
            #expect(fullScopes.contains(.manageRepos))
            #expect(fullScopes.contains(.inferenceAPI))

            // Test inference only scope set
            let inferenceScopes = Set<Scope>.inferenceOnly
            #expect(inferenceScopes.contains(.openid))
            #expect(inferenceScopes.contains(.inferenceAPI))

            // Test discussions scope set
            let discussionScopes = Set<Scope>.discussions
            #expect(discussionScopes.contains(.writeDiscussions))
        }

        @Test("OAuth Scope raw values are correct")
        func testScopeRawValues() {
            #expect(Scope.openid.rawValue == "openid")
            #expect(Scope.profile.rawValue == "profile")
            #expect(Scope.email.rawValue == "email")
            #expect(Scope.readBilling.rawValue == "read-billing")
            #expect(Scope.readRepos.rawValue == "read-repos")
            #expect(Scope.writeRepos.rawValue == "write-repos")
            #expect(Scope.manageRepos.rawValue == "manage-repos")
            #expect(Scope.inferenceAPI.rawValue == "inference-api")
            #expect(Scope.writeDiscussions.rawValue == "write-discussions")

            // Test custom scope
            let customScope = Scope.other("custom-scope")
            #expect(customScope.rawValue == "custom-scope")
        }

        @Test("OAuth Scope initialization from raw values")
        func testScopeInitializationFromRawValue() {
            #expect(Scope(rawValue: "openid") == .openid)
            #expect(Scope(rawValue: "profile") == .profile)
            #expect(Scope(rawValue: "email") == .email)
            #expect(Scope(rawValue: "read-billing") == .readBilling)
            #expect(Scope(rawValue: "read-repos") == .readRepos)
            #expect(Scope(rawValue: "write-repos") == .writeRepos)
            #expect(Scope(rawValue: "manage-repos") == .manageRepos)
            #expect(Scope(rawValue: "inference-api") == .inferenceAPI)
            #expect(Scope(rawValue: "write-discussions") == .writeDiscussions)

            // Test custom scope
            let customScope = Scope(rawValue: "custom-scope")
            #expect(customScope == .other("custom-scope"))
        }

        @Test("OAuth Scope display names are correct")
        func testScopeDisplayNames() {
            #expect(Scope.openid.displayName.contains("ID token"))
            #expect(Scope.profile.displayName.contains("profile information"))
            #expect(Scope.email.displayName.contains("email address"))
            #expect(Scope.readBilling.displayName.contains("payment method"))
            #expect(Scope.readRepos.displayName.contains("read access"))
            #expect(Scope.writeRepos.displayName.contains("write/read access"))
            #expect(Scope.manageRepos.displayName.contains("full access"))
            #expect(Scope.inferenceAPI.displayName.contains("Inference API"))
            #expect(Scope.writeDiscussions.displayName.contains("discussions"))

            // Custom scope display falls through to the raw value.
            let customScope = Scope.other("custom-scope")
            #expect(customScope.displayName == "custom-scope")
        }

        @Test("OAuth Scope string literal support")
        func testScopeStringLiteral() {
            let scope: Scope = "openid"
            #expect(scope == .openid)

            let customScope: Scope = "custom-scope"
            #expect(customScope == .other("custom-scope"))
        }
    }

    /// In-memory token storage for the auth-manager refresh-flow tests.
    /// Lock-protected so the storage closures (which the manager invokes
    /// synchronously) are race-free under strict concurrency.
    @available(macOS 14.0, macCatalyst 17.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    private final class InMemoryTokenStorage: @unchecked Sendable {
        // @unchecked: the `OAuthToken?` field is guarded by `lock` on every
        // access. The struct is final and never escapes its lock-checked
        // accessors, so the compiler's Sendable inference (which doesn't
        // model lock-guarded fields) is too conservative here.
        private let lock = NSLock()
        private var token: OAuthToken?

        init(initial: OAuthToken? = nil) {
            self.token = initial
        }

        func store(_ value: OAuthToken) {
            lock.lock()
            defer { lock.unlock() }
            self.token = value
        }

        func retrieve() -> OAuthToken? {
            lock.lock()
            defer { lock.unlock() }
            return self.token
        }

        func delete() {
            lock.lock()
            defer { lock.unlock() }
            self.token = nil
        }

        var tokenStorage: OAuthManager.TokenStorage {
            OAuthManager.TokenStorage(
                store: { [self] in self.store($0) },
                retrieve: { [self] in self.retrieve() },
                delete: { [self] in self.delete() }
            )
        }
    }

    /// Read the request body whether it was passed inline (`httpBody`)
    /// or via a stream (`httpBodyStream`).
    fileprivate func readStreamToString(_ stream: InputStream) -> String {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
#endif  // canImport(AuthenticationServices) && swift(>=6.1)
