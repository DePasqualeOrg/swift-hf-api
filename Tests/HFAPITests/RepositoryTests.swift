// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the per-kind repository handles introduced in Phase 3a.
/// Each fixture targets a long-lived public repo so the tests run without a token.
/// Transient transport errors early-return rather than fail (matches the policy
/// in `ClientTests.swift`).

@Suite("DatasetRepository – live Hub", .enabled(if: integrationTestsEnabled))
struct DatasetRepositoryTests {
    @Test("info() for nyu-mll/glue returns metadata")
    func glueInfoReturns() async throws {
        let client = try HFClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard let info = try await fetchOrSkip({ try await dataset.info() }) else { return }

        #expect(info.id == "nyu-mll/glue")
        #expect(info.author == "nyu-mll")
        #expect(info.sha != nil && !info.sha!.isEmpty)

        let siblings = try #require(info.siblings)
        let names = Set(siblings.map(\.relativeFilename))
        #expect(names.contains("README.md"))
    }

    @Test("info() expand=cardData populates the JSON payload")
    func glueInfoExpandCardData() async throws {
        let client = try HFClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard
            let info = try await fetchOrSkip({
                try await dataset.info(expand: ["cardData"])
            })
        else { return }

        let cardData = try #require(info.cardData)
        #expect(!cardData.isEmpty)

        let bytes = try #require(cardData.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: bytes)
        #expect(parsed is [String: Any])
    }

    @Test("exists() returns true for an existing dataset")
    func glueExistsTrue() async throws {
        let client = try HFClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard let exists = try await fetchOrSkip({ try await dataset.exists() }) else { return }

        #expect(exists)
    }

    @Test("exists() returns false for a missing dataset")
    func missingDatasetExistsFalse() async throws {
        let client = try HFClient()
        let dataset = client.dataset(
            owner: "nyu-mll",
            name: "this-dataset-does-not-exist-\(UUID().uuidString)"
        )

        guard let exists = try await fetchOrSkip({ try await dataset.exists() }) else { return }

        #expect(!exists)
    }
}

@Suite("Cross-kind exists() – live Hub", .enabled(if: integrationTestsEnabled))
struct CrossKindExistsTests {
    @Test("exists() returns true for an existing model")
    func modelExistsTrue() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let exists = try await fetchOrSkip({ try await model.exists() }) else { return }

        #expect(exists)
    }

    @Test("exists() returns false for a missing model")
    func missingModelExistsFalse() async throws {
        let client = try HFClient()
        let model = client.model(
            owner: "openai-community",
            name: "this-model-does-not-exist-\(UUID().uuidString)"
        )

        guard let exists = try await fetchOrSkip({ try await model.exists() }) else { return }

        #expect(!exists)
    }
}
