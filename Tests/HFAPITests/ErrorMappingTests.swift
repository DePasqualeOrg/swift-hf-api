// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Rust-to-Swift error-mapping path. Most error
/// variants are exercised incidentally by the read-only and mutation
/// tests, but `.forbidden` requires an authenticated request that fails
/// authorization (not authentication), and the easiest reliable way to
/// trigger that is to try to mutate a repo you don't own.

@Suite("HFError mapping – live Hub", .enabled(if: integrationTestsEnabled))
struct ErrorMappingTests {
    @Test("mutating someone else's repo surfaces .forbidden or .http")
    func forbiddenOnUnownedRepo() async throws {
        // This test exercises the 403 path. It needs a token (so the request
        // isn't 401), but the Hub-side authorization check rejects it. Skip
        // cleanly if no token is configured or whoami fails.
        guard tokenOrLogsSkip() != nil else { return }
        let client = try HFClient()
        do {
            _ = try await client.currentUser()
        } catch {
            // Token present but whoami failed (revoked, network blip, etc.) –
            // we can't reach the 403 path, so early-return rather than fail.
            return
        }

        let model = client.model(owner: "openai-community", name: "gpt2")
        do {
            try await model.updateSettings(private: false)
            Issue.record("expected updateSettings on unowned public repo to fail authorization")
        } catch let error as HFError where error.isTransient {
            // Network blip; don't fail the test.
            return
        } catch let error as HFError {
            switch error {
            case .forbidden:
                // Ideal: classified as 403 explicitly.
                break
            case .http(let context) where context.status == 403:
                // Acceptable: mapped as a generic HTTP variant with 403 status.
                break
            case .http(let context):
                Issue.record(
                    "expected 403 mapping; got HTTP \(context.status) – \(context.url)"
                )
            default:
                Issue.record("expected .forbidden or .http(403), got: \(error)")
            }
        }
    }
}
