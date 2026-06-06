// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI
import HFAPIShared

/// Coverage for the dynamic-token bridge: ``Auth/provider(_:)-(_)`` and the
/// underlying Rust-side rebuild-on-rotate logic.
///
/// These tests exercise the FFI plumbing end-to-end (Swift closure →
/// `FfiTokenProvider` adapter → Rust `active_client()` → `hf_hub::HFClient`
/// rebuild). Wherever possible we hit `currentUser()` rather than a public read,
/// because `whoami-v2` actually requires auth – a public endpoint succeeds
/// regardless of whether the token reached the request, masking broken
/// token wiring.
///
/// Mutual exclusion between static and dynamic auth modes is now encoded
/// in the type system via the ``Auth`` enum, so no runtime test asserts
/// the rejected combination – it cannot be expressed.
@Suite("Auth dynamic token provider")
struct TokenProviderTests {
    @Test("provider is invoked once per Hub call")
    func providerInvokedPerCall() async throws {
        guard let token = tokenOrLogsSkip() else { return }
        let counter = CallCounter()
        let client = try HFClient(
            auth: .provider {
                await counter.increment()
                return token
            }
        )

        // Two whoami calls – both should consult the provider exactly once.
        // whoami requires auth, so this also confirms the token actually
        // reached the request.
        _ = try await client.currentUser()
        _ = try await client.currentUser()
        let count = await counter.value
        // Strict equality, not `>= 2`. A loose bound would silently accept
        // a regression where the provider is invoked multiple times per
        // request (e.g., once in `active_client()` plus once in a header
        // builder) and defeat the per-call cache contract.
        #expect(count == 2)
    }

    @Test("rotating tokens rebuilds the inner client")
    func rotationRebuildsInner() async throws {
        guard let token = tokenOrLogsSkip() else { return }

        // Provider sequence: junk → valid. First whoami should throw
        // (junk is rejected by the Hub); second should succeed (valid
        // token triggers a rebuild). Anything else means the inner
        // client wasn't rebuilt.
        let provider = SequenceTokenProvider(tokens: ["hf_junk_token_will_fail", token])
        let client = try HFClient(
            auth: .provider {
                await provider.next()
            }
        )

        do {
            _ = try await client.currentUser()
            Issue.record("first whoami should have failed with junk token")
        } catch is HFError {
            // expected – Hub rejects the bogus bearer
        }

        let user = try await client.currentUser()
        #expect(!user.username.isEmpty)
    }

    @Test("static .token mode still works after the bridge refactor")
    func staticTokenModeRegression() async throws {
        // Regression cover: the bridge refactor split HFClient construction
        // into two paths (static via `HfClientFfi.init`, dynamic via
        // `HfClientFfi.withTokenProvider`). Confirm the static path still
        // delivers the token to the request.
        guard let token = tokenOrLogsSkip() else { return }
        let client = try HFClient(auth: .token(token))
        let user = try await client.currentUser()
        #expect(!user.username.isEmpty)
    }

    @Test("nil from provider produces an unauthenticated request")
    func nilProviderReturnsUnauthenticated() async throws {
        // A provider returning `nil` should not crash and should produce
        // an unauthenticated request. Verify by hitting `whoami` – which
        // requires auth – and confirming the Hub rejects it.
        //
        // Dynamic-token mode passes `disable_implicit_token: true` to the
        // hf-hub builder, so ambient sources (`HF_TOKEN` env, token file)
        // can no longer leak through when the provider returns nil —
        // making the unauthenticated path testable regardless of the
        // host's token state.
        let client = try HFClient(auth: .provider { nil })
        do {
            _ = try await client.currentUser()
            Issue.record("expected whoami without a token to throw an auth error")
        } catch HFError.authRequired, HFError.http {
            // expected – Hub rejects the unauthenticated request
        } catch HFError.request {
            // some hf_hub code paths surface 401 as a generic request error;
            // accept that too rather than masking it as a different bug
        } catch HFError.rateLimited {
            // 429 means the request never reached the auth check, so this
            // run can't prove anything about the unauthenticated path.
            // Early-return rather than accept – treating 429 as success
            // would let an "accidentally sent a token" regression pass.
            return
        }
    }

    @Test("Auth.unauthenticated disables the env fallback and runs unauthenticated")
    func unauthenticatedAuthDisablesEnvFallback() async throws {
        // `.unauthenticated` is the explicit opt-out: env fallback skipped,
        // no provider logic to forget. Same end-to-end shape as a
        // `.provider { nil }` call.
        let client = try HFClient(auth: .unauthenticated)
        do {
            _ = try await client.currentUser()
            Issue.record("expected .unauthenticated to produce an unauthenticated whoami")
        } catch HFError.authRequired, HFError.http, HFError.request {
            // expected – request reached the Hub without auth and was rejected
        } catch HFError.rateLimited {
            // 429 means the request never reached the auth check, so this
            // run can't prove anything about the unauthenticated path.
            // Early-return rather than accept – treating 429 as success
            // would let an "accidentally sent a token" regression pass.
            return
        }
    }

    @Test("provider error propagates as HFError.tokenProviderFailed with the original message")
    func providerErrorPropagates() async throws {
        // A throwing provider should fail the Hub call before the request
        // is dispatched. The caller sees the original error's
        // `localizedDescription` via HFError.tokenProviderFailed.
        let client = try HFClient(
            auth: .provider {
                throw FakeAuthError.refreshExpired
            }
        )
        do {
            _ = try await client.currentUser()
            Issue.record("expected provider throw to abort the Hub call")
        } catch let HFError.tokenProviderFailed(message) {
            #expect(message.contains("refresh token expired"))
        } catch {
            Issue.record("expected HFError.tokenProviderFailed, got: \(error)")
        }
    }

    @Test("transient provider error in best-effort mode degrades to unauthenticated")
    func bestEffortClosureSwallowsError() async throws {
        // Consumers wanting best-effort semantics wrap their own provider
        // in `try?`. Verify the contract still holds: the Hub call runs
        // (against an unauthenticated client) and then fails the
        // auth-required check at the Hub.
        //
        // Dynamic-token mode disables the implicit-token chain on the
        // hf-hub builder, so ambient sources can no longer mask the
        // unauthenticated path.
        let client = try HFClient(
            auth: .provider {
                try? await throwingTokenSource()
            }
        )
        do {
            _ = try await client.currentUser()
            Issue.record("expected unauthenticated whoami to throw an auth error")
        } catch HFError.authRequired, HFError.http, HFError.request {
            // expected – request reached the Hub without auth and was rejected
        } catch HFError.rateLimited {
            // 429 means the request never reached the auth check, so this
            // run can't prove anything about the unauthenticated path.
            // Early-return rather than accept – treating 429 as success
            // would let an "accidentally sent a token" regression pass.
            return
        }
    }

    @Test("Auth.provider(TokenProvider) composes a multi-source chain")
    func tokenProviderEnumOverload() async throws {
        // The TokenProvider bridge is the value-typed counterpart to the
        // closure form – useful for composing multiple sources without
        // hand-writing the fallback ladder in a closure.
        guard let token = tokenOrLogsSkip() else { return }
        let provider: TokenProvider = .composite([
            .custom { token },
            .environment,
        ])
        let client = try HFClient(auth: .provider(provider))
        // The composite must resolve to the env token via the .custom branch
        // so whoami can authenticate.
        let user = try await client.currentUser()
        #expect(!user.username.isEmpty)
    }

    @Test("concurrent whoami calls invoke the provider once per call without races")
    func providerInvokedPerConcurrentCall() async throws {
        // Regression cover for the active_client rotation race: when N
        // concurrent calls hit `whoami`, each one should query the provider
        // exactly once. The Rust side serializes provider invocations
        // through the rotation lock, so even with concurrency the
        // invocation count must equal the number of calls.
        guard let token = tokenOrLogsSkip() else { return }
        let counter = CallCounter()
        let client = try HFClient(
            auth: .provider {
                await counter.increment()
                return token
            }
        )

        let concurrency = 8
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< concurrency {
                group.addTask {
                    _ = try await client.currentUser()
                }
            }
            try await group.waitForAll()
        }
        let count = await counter.value
        #expect(count == concurrency, "expected exactly \(concurrency) provider invocations, got \(count)")
    }

    @Test("TokenProvider bridge propagates errors via HFError.tokenProviderFailed")
    func tokenProviderEnumOverloadPropagatesErrors() async throws {
        // A `.custom` provider that throws should surface the original
        // error message at the Hub-call site, mirroring the closure-form
        // behavior.
        let provider = TokenProvider.custom {
            throw FakeAuthError.refreshExpired
        }
        let client = try HFClient(auth: .provider(provider))
        do {
            _ = try await client.currentUser()
            Issue.record("expected throwing custom provider to abort the Hub call")
        } catch let HFError.tokenProviderFailed(message) {
            #expect(message.contains("refresh token expired"))
        } catch {
            Issue.record("expected HFError.tokenProviderFailed, got: \(error)")
        }
    }
}

private func throwingTokenSource() async throws -> String? {
    throw FakeAuthError.refreshExpired
}

private enum FakeAuthError: LocalizedError {
    case refreshExpired

    var errorDescription: String? {
        switch self {
        case .refreshExpired: return "OAuth refresh token expired"
        }
    }
}

private actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// Token provider that hands out a pre-recorded sequence of values.
/// Returns the last value once the sequence is exhausted, so callers don't
/// see different behavior depending on extra in-flight calls (e.g.,
/// retries) the FFI layer might make on top of the explicit Hub call.
private actor SequenceTokenProvider {
    private var tokens: [String?]
    private var index: Int = 0

    init(tokens: [String?]) {
        self.tokens = tokens
    }

    func next() -> String? {
        let value = tokens[min(index, tokens.count - 1)]
        if index < tokens.count - 1 { index += 1 }
        return value
    }
}
