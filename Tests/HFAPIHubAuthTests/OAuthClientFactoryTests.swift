// Copyright © Anthony DePasquale

#if canImport(AuthenticationServices)

    import Foundation
    import Testing
    @testable import HFAPIHubAuth
    @testable import HFAPI
    @testable import HFAPIOAuth

    /// Coverage for `OAuthClientFactory` – the OAuth↔HFClient bridge.
    ///
    /// `OAuthManager` requires a keychain to be
    /// available (the `keychainService` / `keychainAccount` constructor
    /// args drive the secrets backing store). On CI / non-interactive
    /// builds the keychain is typically not available, so we wrap manager
    /// construction in a try/catch and skip cleanly when it fails.
    @Suite("OAuthClientFactory")
    struct OAuthClientFactoryTests {
        @Test("client(authManager:) returns an HFClient that propagates OAuth errors")
        @MainActor
        func clientPropagatesOAuthErrors() async throws {
            // We can't run a real OAuth flow in a unit test, but we can
            // exercise the propagation contract: with no stored token,
            // `manager.validToken()` throws
            // `OAuthError.authenticationRequired`, which the bridge maps to
            // `HFError.tokenProviderFailed(message:)` carrying the original
            // error's `localizedDescription`. This verifies the closure
            // path, the FFI error channel, and the Swift-side mapping in
            // one round-trip.
            let manager: OAuthManager
            do {
                manager = try OAuthManager(
                    clientID: "test-client-id",
                    redirectURL: URL(string: "https://example.com/oauth")!,
                    scope: .basic,
                    keychainService: "swift-hf-api.tests.OAuthClientFactory",
                    keychainAccount: "huggingface-test"
                )
            } catch {
                // Keychain unavailable on this runner – skip the test, but
                // surface the skip as a warning so the OAuth bridge silently
                // not running on a CI host is visible in the test report.
                Issue.record(
                    "OAuthClientFactory test skipped: keychain unavailable (\(error.localizedDescription))"
                )
                return
            }
            let client = try OAuthClientFactory.client(authManager: manager)
            // Cross-check: the manager's own validToken() throws when no
            // token is stored. Capture its localizedDescription so the test
            // can verify the same string round-trips through the bridge.
            let expectedMessage: String
            do {
                _ = try await manager.validToken()
                Issue.record(
                    "expected manager.validToken() to throw with no stored token"
                )
                return
            } catch {
                expectedMessage = error.localizedDescription
            }
            do {
                _ = try await client.currentUser()
                Issue.record(
                    "expected currentUser to throw tokenProviderFailed when manager has no stored token"
                )
            } catch let HFError.tokenProviderFailed(message) {
                // The OAuth-side error message must round-trip through the
                // FFI verbatim – that's the entire point of the bridge.
                #expect(message == expectedMessage)
            }
        }

        @Test("OAuthClientFactory.client forwards non-auth configuration")
        @MainActor
        func configurationFlowsThrough() async throws {
            let manager: OAuthManager
            do {
                manager = try OAuthManager(
                    clientID: "test-client-id",
                    redirectURL: URL(string: "https://example.com/oauth")!,
                    scope: .basic,
                    keychainService: "swift-hf-api.tests.OAuthClientFactory",
                    keychainAccount: "huggingface-test-2"
                )
            } catch {
                Issue.record(
                    "OAuthClientFactory test skipped: keychain unavailable (\(error.localizedDescription))"
                )
                return
            }
            // A non-default endpoint and user-agent flow through to the
            // built client. Both are exposed as Swift-side getters now, so
            // assert on both rather than only the endpoint.
            let customEndpoint = "https://huggingface.co"
            let customUserAgent = "OAuthClientFactoryTests/1.0"
            let client = try OAuthClientFactory.client(
                authManager: manager,
                endpoint: customEndpoint,
                userAgent: customUserAgent
            )
            #expect(client.endpoint.absoluteString == customEndpoint)
            #expect(client.userAgent == customUserAgent)
        }

        // Auth mode is now owned by the bridge – there is no `auth`
        // parameter on `OAuthClientFactory.client`, so a caller cannot pass a
        // conflicting mode. The previous runtime check is gone; the type
        // system enforces it.
    }

#endif
