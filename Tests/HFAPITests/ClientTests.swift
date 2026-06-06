// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Unit-shaped tests covering construction, configuration round-trip, and
/// error mapping. No live Hub calls.
@Suite("HFClient construction")
struct ClientConstructionTests {
    @Test("default init resolves an endpoint and a cache directory")
    func defaultInitResolves() throws {
        let client = try HFClient()

        #expect(client.endpoint.scheme == "https")

        let cache = client.cacheDirectory.path
        #expect(!cache.isEmpty)
        #expect(client.isCacheEnabled)
    }

    @Test("options forward endpoint, token, and cache settings")
    func optionsForwardConfiguration() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-test-cache-\(UUID().uuidString)")

        let client = try HFClient(
            endpoint: "https://example.invalid",
            auth: .token("hf_test_token"),
            cacheDirectory: tmp,
            cacheEnabled: false
        )

        #expect(client.endpoint.absoluteString == "https://example.invalid")
        #expect(client.cacheDirectory == tmp)
        #expect(client.isCacheEnabled == false)
    }

    @Test("init rejects malformed endpoint URLs")
    func rejectsBadEndpoint() {
        do {
            _ = try HFClient(endpoint: "not a url")
            Issue.record("expected HFClient(endpoint:) to throw")
        } catch let error as HFError {
            // Expect a URL-shaped error variant.
            switch error {
            case .urlParse, .invalidParameter, .other:
                break
            default:
                Issue.record("unexpected error variant: \(error)")
            }
        } catch {
            Issue.record("expected HFError, got: \(error)")
        }
    }
}

/// Live-Hub tests. Each test pings a public model on `huggingface.co` so they
/// run without `HF_TOKEN`. Network failures (offline, DNS unreachable) early-
/// return rather than fail; this matches `hf-hub`'s integration-test policy.
/// Swift Testing 6.2 has no first-class `XCTSkip`, so silent early-return is
/// the closest we can get – the trade-off is a "pass" report when the network
/// is offline. Real assertion failures still surface normally.
@Suite("HFClient model.info – live Hub", .enabled(if: integrationTestsEnabled))
struct ClientModelInfoTests {
    @Test("info() for openai-community/gpt2 returns metadata")
    func gpt2InfoReturns() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let info = try await fetchOrSkip({ try await model.info() }) else { return }

        #expect(info.id == "openai-community/gpt2")
        #expect(info.author == "openai-community")
        #expect(info.sha != nil && !info.sha!.isEmpty)

        // The Hub always returns siblings on info(); we expect at least the
        // README and config.
        let siblings = try #require(info.siblings)
        let names = Set(siblings.map(\.relativeFilename))
        #expect(names.contains("README.md"))
        #expect(names.contains("config.json"))
    }

    @Test("info() expand=cardData populates the JSON payload")
    func gpt2InfoExpandCardData() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let info = try await fetchOrSkip({ try await model.info(expand: ["cardData"]) })
        else { return }

        let cardData = try #require(info.cardData)
        #expect(!cardData.isEmpty)

        // The payload is a JSON object – round-trip it through JSONSerialization
        // to confirm.
        let bytes = try #require(cardData.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: bytes)
        #expect(parsed is [String: Any])
    }

    @Test("info() on a missing repo throws .repoNotFound")
    func missingRepoThrowsRepoNotFound() async throws {
        let client = try HFClient()
        let owner = "openai-community"
        let name = "this-repo-does-not-exist-\(UUID().uuidString)"
        let model = client.model(owner: owner, name: name)

        do {
            _ = try await model.info()
            Issue.record("expected info() on nonexistent repo to throw")
        } catch let error as HFError {
            if error.isTransient { return }
            switch error {
            case .repoNotFound(let repoID, _):
                #expect(repoID == "\(owner)/\(name)")
            default:
                Issue.record("unexpected error variant: \(error)")
            }
        }
    }
}
