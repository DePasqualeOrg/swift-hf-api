// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the top-level listing endpoints (`listModels`,
/// `listDatasets`). Each test caps the result count via `.limit()` so a
/// Hub-load swing cannot skew the assertion. Transient transport errors
/// early-return rather than fail.

@Suite("HFClient.listModels – live Hub", .enabled(if: integrationTestsEnabled))
struct ListModelsTests {
    @Test("listModels(author: openai-community).limit(5) returns matching models")
    func listByAuthor() async throws {
        let client = try HFClient()

        guard
            let models = try await fetchOrSkip({
                try await client.listModels(author: "openai-community", limit: 5)
            })
        else { return }

        #expect(!models.isEmpty)
        #expect(models.count <= 5)
        for model in models {
            #expect(model.id.hasPrefix("openai-community/"))
        }
    }

    @Test("listModels(search:).limit(3) finds gpt2-shaped IDs")
    func listBySearch() async throws {
        let client = try HFClient()

        guard
            let models = try await fetchOrSkip({
                try await client.listModels(search: "gpt2", limit: 3)
            })
        else { return }

        #expect(!models.isEmpty)
        #expect(models.count <= 3)
        // The Hub matches `search` substring-style against `id` and the
        // card description, so at least one result should mention gpt2 in
        // its id. Don't assert every result contains it (description hits
        // count too).
        #expect(models.contains { $0.id.lowercased().contains("gpt2") })
    }

    @Test("listModels(filter: pipelineTag).limit(2) populates pipelineTag")
    func listWithPipelineTag() async throws {
        let client = try HFClient()

        guard
            let models = try await fetchOrSkip({
                try await client.listModels(pipelineTag: "text-generation", limit: 2)
            })
        else { return }

        #expect(!models.isEmpty)
        #expect(models.count <= 2)
        // The default response shape includes pipelineTag. The Hub may
        // omit it for very stale repos, so assert at least one entry has
        // the value rather than every entry.
        #expect(models.contains { $0.pipelineTag == "text-generation" })
    }

    @Test("listModels(sort: .downloads, limit: 2) returns results ordered by Hub")
    func listSortByDownloads() async throws {
        let client = try HFClient()

        guard
            let models = try await fetchOrSkip({
                try await client.listModels(sort: .downloads, limit: 2)
            })
        else { return }

        #expect(!models.isEmpty)
        #expect(models.count <= 2)
        // Verify the Hub actually ordered by downloads. Without this the
        // test would pass even if `.sort(.downloads)` were a no-op. The
        // default-listing response includes `downloads` only when the
        // Hub returns it; skip the order check if the field is absent
        // for either result rather than asserting a false negative.
        if models.count == 2,
            let lhs = models[0].downloads,
            let rhs = models[1].downloads
        {
            #expect(lhs >= rhs)
        }
    }
}

@Suite("HFClient.listDatasets – live Hub", .enabled(if: integrationTestsEnabled))
struct ListDatasetsTests {
    @Test("listDatasets(author: nyu-mll).limit(5) returns matching datasets")
    func listByAuthor() async throws {
        let client = try HFClient()

        guard
            let datasets = try await fetchOrSkip({
                try await client.listDatasets(author: "nyu-mll", limit: 5)
            })
        else { return }

        #expect(!datasets.isEmpty)
        #expect(datasets.count <= 5)
        for dataset in datasets {
            #expect(dataset.id.hasPrefix("nyu-mll/"))
        }
    }

    @Test("listDatasets(search:).limit(3) returns relevant datasets")
    func listBySearch() async throws {
        let client = try HFClient()

        guard
            let datasets = try await fetchOrSkip({
                try await client.listDatasets(search: "glue", limit: 3)
            })
        else { return }

        #expect(!datasets.isEmpty)
        #expect(datasets.count <= 3)
        #expect(datasets.contains { $0.id.lowercased().contains("glue") })
    }
}

@Suite("HFClient.listModelsStream – live Hub", .enabled(if: integrationTestsEnabled))
struct ListModelsStreamTests {
    @Test("listModelsStream lets the consumer break out after the Nth match")
    func breakEarly() async throws {
        let client = try HFClient()
        do {
            let stream = try await client.listModelsStream(author: "openai-community")
            var ids: [String] = []
            for try await model in stream {
                ids.append(model.id)
                if ids.count == 3 { break }
            }
            #expect(ids.count == 3)
            for id in ids {
                #expect(id.hasPrefix("openai-community/"))
            }
        } catch let error as HFError where error.isTransient {
            return
        }
    }

    @Test("listModelsStream surfaces explicit cancel() during iteration")
    func cancellation() async throws {
        let client = try HFClient()
        do {
            let stream = try await client.listModelsStream(author: "openai-community")
            var ids: [String] = []
            for try await model in stream {
                ids.append(model.id)
                if ids.count == 1 { stream.cancel() }
            }
            // The stream returns whatever it pulled before cancellation
            // landed – at least the one entry that triggered cancel().
            #expect(ids.count >= 1)
            #expect(stream.isCancelled)
        } catch let error as HFError where error.isTransient {
            return
        }
    }

    @Test("Task.cancel() on the consumer propagates to the Rust drain task")
    func taskCancellationPropagates() async throws {
        let client = try HFClient()
        let stream: ModelInfoListing
        do {
            stream = try await client.listModelsStream(author: "openai-community")
        } catch let error as HFError where error.isTransient {
            return
        }

        // Consume in a child Task that holds the listing reference.
        // Cancelling the Task from outside should propagate through
        // `withTaskCancellationHandler` and fire `stream.cancel()`,
        // unblocking the awaiting `ffi.next()` and ending iteration.
        let consumerTask = Task<Int, Error> {
            var seen = 0
            for try await _ in stream {
                seen += 1
            }
            return seen
        }

        // Give the consumer time to pull at least one item.
        try await Task.sleep(for: .milliseconds(200))
        consumerTask.cancel()

        // The task should return promptly (iteration ends when the Rust
        // drain task drops `tx`). If `withTaskCancellationHandler` wasn't
        // wired up the consumer would keep pulling pages until the Hub
        // ran out of `openai-community` models.
        do {
            _ = try await consumerTask.value
        } catch let error as HFError where error.isTransient {
            return
        }
        #expect(stream.isCancelled)
    }
}
