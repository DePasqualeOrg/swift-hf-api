// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 4b branch/tag endpoints:
/// ``RepositoryProtocol/createBranch(_:revision:)``,
/// ``RepositoryProtocol/deleteBranch(_:)``,
/// ``RepositoryProtocol/createTag(_:revision:message:)``,
/// ``RepositoryProtocol/deleteTag(_:)``.
///
/// Each test creates an isolated test repo, performs the operation,
/// verifies via ``RepositoryProtocol/listRefs(includePullRequests:)``,
/// and tears the repo down. Tests early-return when no token is
/// configured.

@Suite("Repository branches and tags – live Hub", .enabled(if: integrationTestsEnabled))
struct BranchTagTests {
    @Test("createBranch + deleteBranch round-trip on a model repo")
    func branchRoundTrip() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "refs") else { return }
        let model = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: model.repoID) {

            let branchName = "feature-\(UUID().uuidString.prefix(8).lowercased())"

            try await model.repo.createBranch(branchName)

            let refsAfterCreate = try await model.repo.listRefs()
            #expect(refsAfterCreate.branches.contains { $0.name == branchName })

            try await model.repo.deleteBranch(branchName)

            let refsAfterDelete = try await model.repo.listRefs()
            #expect(!refsAfterDelete.branches.contains { $0.name == branchName })
        }
    }

    @Test("createTag + deleteTag round-trip with annotation message")
    func tagRoundTripAnnotated() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "refs") else { return }
        let model = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: model.repoID) {

            let tagName = "v0.0.\(UUID().uuidString.prefix(6).lowercased())"

            try await model.repo.createTag(
                tagName,
                message: "swift-hf-api tag round-trip test"
            )

            let refsAfterCreate = try await model.repo.listRefs()
            #expect(refsAfterCreate.tags.contains { $0.name == tagName })

            try await model.repo.deleteTag(tagName)

            let refsAfterDelete = try await model.repo.listRefs()
            #expect(!refsAfterDelete.tags.contains { $0.name == tagName })
        }
    }

    @Test("createBranch from an explicit revision points at that commit")
    func branchFromRevision() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "refs") else { return }
        let model = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: model.repoID) {

            // Resolve main's commit so we can branch from it explicitly.
            let mainRefs = try await model.repo.listRefs()
            guard let main = mainRefs.branches.first(where: { $0.name == "main" }) else {
                Issue.record("expected freshly created repo to have a main branch")
                return
            }

            let branchName = "from-rev-\(UUID().uuidString.prefix(8).lowercased())"
            try await model.repo.createBranch(branchName, revision: main.targetCommit)

            let refs = try await model.repo.listRefs()
            let created = refs.branches.first { $0.name == branchName }
            #expect(created != nil)
            #expect(created?.targetCommit == main.targetCommit)

            try await model.repo.deleteBranch(branchName)
        }
    }

    @Test("createTag without a message creates a lightweight tag")
    func tagRoundTripLightweight() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "refs") else { return }
        let model = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: model.repoID) {

            let tagName = "v0.0.lw-\(UUID().uuidString.prefix(6).lowercased())"

            // No annotation message – exercises the path where the
            // builder's `message` is `None`.
            try await model.repo.createTag(tagName)

            let refsAfterCreate = try await model.repo.listRefs()
            #expect(refsAfterCreate.tags.contains { $0.name == tagName })

            try await model.repo.deleteTag(tagName)
        }
    }

    @Test("createTag rejects a duplicate tag name")
    func tagDuplicateRejected() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "refs") else { return }
        let model = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: model.repoID) {

            let tagName = "v0.0.dup-\(UUID().uuidString.prefix(6).lowercased())"

            try await model.repo.createTag(tagName, message: "first")

            // Second create with the same name must fail. The Hub
            // returns 409; the FFI maps to `.conflict` (or `.http` for
            // older paths). Reject `.cancelled` and unrelated variants.
            do {
                try await model.repo.createTag(tagName, message: "second")
                Issue.record("expected duplicate-tag create to throw")
            } catch HFError.conflict, HFError.http, HFError.request {
                // expected – Hub rejects the duplicate
            } catch {
                Issue.record("unexpected error variant: \(error)")
            }

            try await model.repo.deleteTag(tagName)
        }
    }

    @Test("createBranch from an invalid revision is rejected")
    func branchFromInvalidRevisionRejected() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "refs") else { return }
        let model = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: model.repoID) {

            let branchName = "bad-rev-\(UUID().uuidString.prefix(8).lowercased())"
            // 40-char hex string that doesn't resolve to any commit on
            // a freshly created repo.
            let bogus = String(repeating: "0", count: 40)

            do {
                try await model.repo.createBranch(branchName, revision: bogus)
                Issue.record("expected createBranch with bogus revision to throw")
            } catch HFError.revisionNotFound, HFError.entryNotFound, HFError.http,
                HFError.request, HFError.conflict
            {
                // expected – Hub rejects the unresolvable revision
            } catch {
                Issue.record("unexpected error variant: \(error)")
            }
        }
    }
}
