// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the per-repo tree, paths-info, and file-metadata
/// methods introduced in Phase 3b. The shared `RepositoryProtocol` makes
/// these methods available on every concrete repo type; the tests cover
/// model and dataset paths against long-lived public repos.

@Suite("Repository.listTree – live Hub", .enabled(if: integrationTestsEnabled))
struct RepositoryListTreeTests {
    @Test("listTree() on a model returns files at the root")
    func gpt2ListTree() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let entries = try await fetchOrSkip({ try await model.listTree() })
        else { return }

        #expect(!entries.isEmpty)

        // Root listing should include README.md and config.json. Both are
        // file entries.
        let paths = Set(entries.map(\.path))
        #expect(paths.contains("README.md"))
        #expect(paths.contains("config.json"))

        for entry in entries where entry.path == "config.json" {
            if case .file(_, let size, _, _, _, _, _) = entry {
                #expect(size > 0)
            } else {
                Issue.record("expected config.json to be a file entry")
            }
        }
    }

    @Test("listTree(expand: true) populates lastCommit")
    func gpt2ListTreeExpanded() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let entries = try await fetchOrSkip({
                try await model.listTree(expand: true)
            })
        else { return }

        // At least one entry should carry a last-commit summary when expand
        // is true. The exact entry varies, so just look for any.
        let withCommit = entries.contains { entry in
            switch entry {
            case .file(_, _, _, _, let lastCommit, _, _): lastCommit != nil
            case .directory(_, _, let lastCommit): lastCommit != nil
            }
        }
        #expect(withCommit, "expected at least one entry to have a lastCommit when expand=true")
    }

    @Test("listTree(limit:) caps the number of entries returned")
    func gpt2ListTreeLimit() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let entries = try await fetchOrSkip({
                try await model.listTree(recursive: true, limit: 3)
            })
        else { return }

        #expect(entries.count <= 3)
        #expect(!entries.isEmpty)
    }

    @Test("listTree() works on a dataset")
    func glueListTree() async throws {
        let client = try HFClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard let entries = try await fetchOrSkip({ try await dataset.listTree() })
        else { return }

        #expect(!entries.isEmpty)
        let paths = Set(entries.map(\.path))
        #expect(paths.contains("README.md"))
    }
}

@Suite("Repository.pathsInfo – live Hub", .enabled(if: integrationTestsEnabled))
struct RepositoryPathsInfoTests {
    @Test("pathsInfo() returns the requested entries")
    func gpt2PathsInfo() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let entries = try await fetchOrSkip({
                try await model.pathsInfo(["config.json", "README.md"])
            })
        else { return }

        // The Hub returns an entry per requested path that exists. Both
        // paths should resolve.
        let returnedPaths = Set(entries.map(\.path))
        #expect(returnedPaths.contains("config.json"))
        #expect(returnedPaths.contains("README.md"))
    }

    @Test("pathsInfo() returns valid paths when mixed with unknown paths")
    func gpt2PathsInfoMixed() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Mix one valid path with one made-up path. Either the Hub returns
        // only the valid entry, or it 404s the request – test both branches.
        // Track which branch fired so the test fails noisily if neither
        // does (a regression in error mapping could otherwise return an
        // empty success result silently).
        enum Outcome { case validReturned, entryNotFound }
        var outcome: Outcome?
        do {
            let entries = try await model.pathsInfo(
                ["config.json", "this-file-does-not-exist-\(UUID().uuidString).bin"]
            )
            let paths = Set(entries.map(\.path))
            #expect(paths.contains("config.json"))
            outcome = .validReturned
        } catch let error as HFError where error.isTransient {
            return
        } catch let error as HFError {
            if case .entryNotFound = error {
                outcome = .entryNotFound
            } else {
                Issue.record("unexpected error variant: \(error)")
                return
            }
        }
        #expect(outcome != nil, "neither the valid-entries nor the entry-not-found branch ran")
    }
}

@Suite("Repository.fileMetadata – live Hub", .enabled(if: integrationTestsEnabled))
struct RepositoryFileMetadataTests {
    @Test("fileMetadata() returns commit hash, etag, and size")
    func gpt2ConfigMetadata() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let metadata = try await fetchOrSkip({
                try await model.fileMetadata("config.json")
            })
        else { return }

        #expect(metadata.filename == "config.json")
        #expect(!metadata.etag.isEmpty)
        #expect(!metadata.commitHash.isEmpty)
        #expect(metadata.fileSize > 0)
    }

    @Test("fileMetadata(revision:) resolves an explicit revision")
    func gpt2ConfigMetadataAtRevision() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // First resolve main's commit, then refetch metadata with that
        // explicit revision. The returned commit hash must match the
        // resolved one – proves the revision parameter actually flows
        // through the FFI rather than being ignored.
        guard
            let baseline = try await fetchOrSkip({
                try await model.fileMetadata("config.json")
            })
        else { return }

        guard
            let pinned = try await fetchOrSkip({
                try await model.fileMetadata(
                    "config.json",
                    revision: baseline.commitHash
                )
            })
        else { return }

        #expect(pinned.commitHash == baseline.commitHash)
        #expect(pinned.fileSize == baseline.fileSize)
        #expect(pinned.etag == baseline.etag)
    }

    @Test("fileMetadata() throws .entryNotFound for a missing file")
    func gpt2MissingFileMetadata() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")
        let missing = "this-file-does-not-exist-\(UUID().uuidString).bin"

        do {
            _ = try await model.fileMetadata(missing)
            Issue.record("expected fileMetadata for a nonexistent path to throw")
        } catch let error as HFError {
            if error.isTransient { return }
            switch error {
            case .entryNotFound(let path, _, _):
                #expect(path == missing)
            default:
                Issue.record("unexpected error variant: \(error)")
            }
        }
    }
}
