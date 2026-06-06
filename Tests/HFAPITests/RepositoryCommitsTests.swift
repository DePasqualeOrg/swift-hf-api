// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the commits/refs/diffs methods introduced in
/// Phase 3e. The shared `RepositoryProtocol` exposes these on every
/// concrete repo type; tests target long-lived public model and dataset
/// repos. Transient transport errors early-return rather than fail.

@Suite("Repository.listCommits – live Hub", .enabled(if: integrationTestsEnabled))
struct RepositoryListCommitsTests {
    @Test("listCommits(limit: 5) returns up to 5 commits with valid metadata")
    func gpt2ListCommits() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let commits = try await fetchOrSkip({
                try await model.listCommits(limit: 5)
            })
        else { return }

        #expect(!commits.isEmpty)
        #expect(commits.count <= 5)
        for commit in commits {
            // Commit SHAs are 40-char hex (or longer for some Hub-internal
            // shapes). Just check non-empty + non-empty title.
            #expect(!commit.id.isEmpty)
            #expect(!commit.title.isEmpty)
        }
    }

    @Test("listCommits() works on a dataset")
    func glueListCommits() async throws {
        let client = try HFClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard
            let commits = try await fetchOrSkip({
                try await dataset.listCommits(limit: 3)
            })
        else { return }

        #expect(!commits.isEmpty)
        #expect(commits.count <= 3)
    }
}

@Suite("Repository.listRefs – live Hub", .enabled(if: integrationTestsEnabled))
struct RepositoryListRefsTests {
    @Test("listRefs() returns a populated branches list")
    func gpt2ListRefs() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let refs = try await fetchOrSkip({ try await model.listRefs() })
        else { return }

        // Public model repos always have at least the default branch.
        #expect(!refs.branches.isEmpty)
        // PR refs are excluded by default.
        #expect(refs.pullRequests.isEmpty)

        let branchNames = Set(refs.branches.map(\.name))
        #expect(branchNames.contains("main"))

        for ref in refs.branches {
            #expect(!ref.targetCommit.isEmpty)
            #expect(ref.ref.hasPrefix("refs/"))
        }
    }

    @Test("listRefs(includePullRequests: true) populates pullRequests when present")
    func gpt2ListRefsWithPullRequests() async throws {
        let client = try HFClient()
        // `bert-base-uncased` is a long-lived public repo with an active
        // discussion / PR history, so it's a stable target for covering
        // the includePullRequests=true path.
        let model = client.model(owner: "google-bert", name: "bert-base-uncased")

        guard
            let refs = try await fetchOrSkip({
                try await model.listRefs(includePullRequests: true)
            })
        else { return }

        // The repo always has at least one PR ref over its lifetime; the
        // refs/pr/* shape is what the includePullRequests branch is
        // supposed to surface.
        #expect(!refs.branches.isEmpty)
        // Without asserting an exact count (PRs come and go), assert at
        // least one PR ref exists OR the call shape was honored – the
        // ref.ref strings carry `refs/pr/` for PR refs.
        if !refs.pullRequests.isEmpty {
            for ref in refs.pullRequests {
                #expect(ref.ref.contains("refs/pr/"))
            }
        }
    }
}

@Suite("Repository.commitDiff / rawDiff – live Hub", .enabled(if: integrationTestsEnabled))
struct RepositoryDiffTests {
    /// The Hub's `/compare` endpoint requires `<base>..<head>` form (two
    /// dots between two refs). Resolve two commits from the live history
    /// so the diff request is well-formed.
    static func resolveCompareRange(
        _ model: ModelRepository
    ) async throws -> String? {
        let commits = try await model.listCommits(limit: 5)
        guard commits.count >= 2 else { return nil }
        return "\(commits[1].id)..\(commits[0].id)"
    }

    @Test("rawDiff(compare:) returns text for a real commit range")
    func gpt2RawDiff() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let compare = try await fetchOrSkip({ try await Self.resolveCompareRange(model) })
        else { return }
        guard let range = compare else { return }

        guard
            let text = try await fetchOrSkip({
                try await model.rawDiff(range)
            })
        else { return }

        // Raw diff text from a real range is always non-empty (even an
        // empty diff has a header line).
        #expect(!text.isEmpty)
    }

    @Test("rawDiffEntries(_:) returns parsed file entries")
    func gpt2RawDiffEntries() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let compare = try await fetchOrSkip({ try await Self.resolveCompareRange(model) })
        else { return }
        guard let range = compare else { return }

        guard
            let entries = try await fetchOrSkip({
                try await model.rawDiffEntries(range)
            })
        else { return }

        // A real commit range between two consecutive commits must yield
        // at least one parsed entry – every commit on this Hub repo
        // touches at least one file. An empty list silently passes the
        // for-loop below otherwise, masking a regression in the parser.
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(!entry.filePath.isEmpty)
        }
    }

    @Test("commitDiff(_:) returns the unified diff payload for a real range")
    func gpt2CommitDiff() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard let compare = try await fetchOrSkip({ try await Self.resolveCompareRange(model) })
        else { return }
        guard let range = compare else { return }

        guard
            let payload = try await fetchOrSkip({
                try await model.commitDiff(range)
            })
        else { return }

        #expect(!payload.isEmpty)
        // The Hub's `/compare/{base..head}` endpoint returns unified-diff
        // text (not JSON). Every non-empty diff between two commits on
        // gpt2 starts with a `diff --git` header – assert the payload
        // contains that marker to catch regressions that return HTML
        // error pages or unrelated content.
        #expect(
            payload.contains("diff --git"),
            "expected unified-diff payload, got: \(payload.prefix(200))"
        )
    }
}
