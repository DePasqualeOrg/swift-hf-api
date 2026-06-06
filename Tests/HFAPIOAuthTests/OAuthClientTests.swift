// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import HFAPIOAuth
import HFAPIShared

#if swift(>=6.1)
    @Suite("OAuth Client Tests", .serialized)
    struct OAuthClientTests {
        @Test("OAuthClient can be initialized with valid configuration")
        func testOAuthClientInitialization() async throws {
            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let client = OAuthClient(configuration: config)
            let configuration = await client.configuration
            #expect(configuration.baseURL == config.baseURL)
            #expect(configuration.clientID == config.clientID)
        }

        @Test("OAuthClient generates valid authorization URL and round-trips state")
        func testAuthorizationURLGeneration() async throws {
            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let client = OAuthClient(configuration: config)

            let code = try await client.authenticate { url, _ in
                // Verify the URL components
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                #expect(
                    components?.queryItems?.contains { $0.name == "client_id" && $0.value == "test_client_id" } == true
                )
                #expect(
                    components?.queryItems?.contains {
                        $0.name == "redirect_uri" && $0.value == "myapp://oauth/callback"
                    } == true
                )
                #expect(components?.queryItems?.contains { $0.name == "response_type" && $0.value == "code" } == true)
                #expect(components?.queryItems?.contains { $0.name == "scope" && $0.value == "openid profile" } == true)
                #expect(components?.queryItems?.contains { $0.name == "code_challenge" } == true)
                #expect(
                    components?.queryItems?.contains { $0.name == "code_challenge_method" && $0.value == "S256" }
                        == true
                )
                let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
                #expect(state != nil)
                #expect(!(state ?? "").isEmpty)

                // Echo state back in the callback URL as a well-behaved provider would.
                return makeCallbackURL(state: state, code: "mock_auth_code")
            }

            #expect(code == "mock_auth_code")
        }

        @Test("OAuthClient rejects callback with mismatched state")
        func testAuthorizationRejectsMismatchedState() async throws {
            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let client = OAuthClient(configuration: config)

            await #expect(throws: OAuthError.stateMismatch) {
                try await client.authenticate { _, _ in
                    // Attacker-supplied state: anything other than the value
                    // the client attached to the authorization URL.
                    return makeCallbackURL(state: "attacker-controlled-state", code: "mock_auth_code")
                }
            }
        }

        @Test("OAuthClient surfaces provider error from callback URL")
        func testAuthorizationSurfacesProviderError() async throws {
            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let client = OAuthClient(configuration: config)

            await #expect(
                throws: OAuthError.providerError(code: "access_denied", description: "User declined")
            ) {
                try await client.authenticate { _, _ in
                    return URL(
                        string:
                            "myapp://oauth/callback?error=access_denied&error_description=User%20declined"
                    )!
                }
            }
        }

        @Test("OAuthClient handles token exchange with mocked response", .mockURLSession)
        func testTokenExchange() async throws {
            // Set up mock response
            await MockURLProtocol.setHandler { request in
                // Verify request method and content type
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

                // Verify the request body actually contains the expected
                // grant_type and authorization code. Otherwise a regression
                // that sent the refresh-grant payload here would still
                // produce a 200 (because the mock doesn't care about
                // request shape) and the test would silently pass.
                let body = requestBodyString(request)
                #expect(body.contains("grant_type=authorization_code"))
                #expect(body.contains("code=mock_auth_code"))
                #expect(body.contains("code_verifier="))

                // Return mock token response
                let tokenResponse = """
                    {
                        "access_token": "mock_access_token",
                        "refresh_token": "mock_refresh_token",
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

                return (response, tokenResponse.data(using: .utf8)!)
            }

            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            // Create a custom URLSession that uses the mock protocol
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MockURLProtocol.self]
            let mockSession = URLSession(configuration: sessionConfig)

            let client = OAuthClient(configuration: config, session: mockSession)

            // First authenticate to set up the code verifier (state must
            // round-trip to satisfy the new CSRF guard).
            _ = try await client.authenticate { url, _ in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "state" })?
                    .value
                return makeCallbackURL(state: state, code: "mock_auth_code")
            }

            // Then exchange the code for a token
            let token = try await client.exchangeCode("mock_auth_code")

            #expect(token.accessToken == "mock_access_token")
            #expect(token.refreshToken == "mock_refresh_token")
            #expect(token.isValid == true)
        }

        @Test("OAuthClient handles token refresh with mocked response", .mockURLSession)
        func testTokenRefresh() async throws {
            // Set up mock response for token refresh
            await MockURLProtocol.setHandler { request in
                // Verify request method and content type
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

                // Verify the request body carries the refresh_token grant
                // and the supplied refresh token. Without these the test
                // would still pass on a regression that sent an
                // authorization_code grant by mistake.
                let body = requestBodyString(request)
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("refresh_token=mock_refresh_token"))

                // Return mock token response
                let tokenResponse = """
                    {
                        "access_token": "new_access_token",
                        "refresh_token": "new_refresh_token",
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

                return (response, tokenResponse.data(using: .utf8)!)
            }

            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            // Create a custom URLSession that uses the mock protocol
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MockURLProtocol.self]
            let mockSession = URLSession(configuration: sessionConfig)

            let client = OAuthClient(configuration: config, session: mockSession)

            // Test token refresh
            let newToken = try await client.refreshToken(using: "mock_refresh_token")

            #expect(newToken.accessToken == "new_access_token")
            #expect(newToken.refreshToken == "new_refresh_token")
            #expect(newToken.isValid == true)
        }

        @Test("OAuthClient surfaces RFC 6749 §5.2 error body on token exchange failure", .mockURLSession)
        func testTokenExchangeFailure() async throws {
            // RFC 6749 §5.2 specifies non-2xx error bodies as
            // `{ "error": "...", "error_description": "..." }` – return one
            // and verify the client decodes it into the typed associated
            // values of `OAuthError.tokenExchangeFailed`.
            let body = #"{"error":"invalid_grant","error_description":"code reuse"}"#
            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, body.data(using: .utf8)!)
            }

            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MockURLProtocol.self]
            let mockSession = URLSession(configuration: sessionConfig)

            let client = OAuthClient(configuration: config, session: mockSession)

            _ = try await client.authenticate { url, _ in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "state" })?
                    .value
                return makeCallbackURL(state: state, code: "mock_auth_code")
            }

            let expected = OAuthError.tokenExchangeFailed(
                statusCode: 400,
                error: "invalid_grant",
                description: "code reuse"
            )
            await #expect(throws: expected) {
                try await client.exchangeCode("mock_auth_code")
            }
        }

        @Test("OAuthClient surfaces status code when token exchange body is empty", .mockURLSession)
        func testTokenExchangeFailureEmptyBody() async throws {
            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }

            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [MockURLProtocol.self]
            let mockSession = URLSession(configuration: sessionConfig)

            let client = OAuthClient(configuration: config, session: mockSession)

            _ = try await client.authenticate { url, _ in
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "state" })?
                    .value
                return makeCallbackURL(state: state, code: "mock_auth_code")
            }

            let expected = OAuthError.tokenExchangeFailed(
                statusCode: 503,
                error: nil,
                description: nil
            )
            await #expect(throws: expected) {
                try await client.exchangeCode("mock_auth_code")
            }
        }

        @Test("OAuthClient handles missing code verifier")
        func testMissingCodeVerifier() async throws {
            let config = OAuthClientConfiguration(
                baseURL: URL(string: "https://huggingface.co")!,
                redirectURL: URL(string: "myapp://oauth/callback")!,
                clientID: "test_client_id",
                scope: "openid profile"
            )

            let client = OAuthClient(configuration: config)

            // Test that exchangeCode throws error when no code verifier is set
            await #expect(throws: OAuthError.missingCodeVerifier) {
                try await client.exchangeCode("mock_auth_code")
            }
        }

        @Test("OAuthToken validates expiration correctly")
        func testTokenValidation() {
            let now = Date()
            let validToken = OAuthToken(
                accessToken: "test_token",
                refreshToken: "test_refresh",
                expiresAt: now.addingTimeInterval(3600)  // 1 hour from now
            )

            let expiredToken = OAuthToken(
                accessToken: "test_token",
                refreshToken: "test_refresh",
                expiresAt: now.addingTimeInterval(-3600)  // 1 hour ago
            )

            #expect(validToken.isValid == true)
            #expect(expiredToken.isValid == false)
        }
    }

    /// Build the well-formed callback URL a compliant OAuth provider would
    /// redirect to after the user authorizes. Echoes the request `state`
    /// back so `OAuthClient.authenticate` accepts it.
    fileprivate func makeCallbackURL(state: String?, code: String) -> URL {
        var components = URLComponents(string: "myapp://oauth/callback")!
        var items: [URLQueryItem] = [.init(name: "code", value: code)]
        if let state {
            items.append(.init(name: "state", value: state))
        }
        components.queryItems = items
        return components.url!
    }

    /// Read the request body whether it was passed inline (`httpBody`)
    /// or via a stream (`httpBodyStream`, which is what `URLRequest` uses
    /// once the request crosses `URLProtocol`'s internal copy boundary).
    /// Top-level so the `MockURLProtocol.setHandler { … }` closure can
    /// call it without dragging `self` into the @Sendable closure.
    fileprivate func requestBodyString(_ request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
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
#endif  // swift(>=6.1)
