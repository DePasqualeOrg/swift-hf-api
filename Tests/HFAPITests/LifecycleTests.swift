// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 4a lifecycle endpoints:
/// `createRepository`, `deleteRepository`, `moveRepository`, and
/// `updateSettings`. Each test creates a unique repo under the
/// authenticated user's namespace so concurrent runs do not collide,
/// and always tears down what it created.
///
/// These tests require a valid `HF_TOKEN` (or one of the alternative
/// token sources `hf-hub` consults). When no token is available, the
/// suite early-returns from `whoami` and the test is skipped.

@Suite("HFClient lifecycle – live Hub", .enabled(if: integrationTestsEnabled))
struct LifecycleTests {
    @Test("create + delete round-trip on a model repo")
    func createDeleteModel() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }

        let repoID = ctx.uniqueRepoID()
        let url = try await ctx.client.createRepository(
            type: .model,
            repoID: repoID,
            private: true
        )
        #expect(!url.absoluteString.isEmpty)
        // The returned URL should reference the new repo.
        #expect(url.absoluteString.contains(repoID))

        // Verify it now exists.
        let existsAfterCreate = try await ctx.client.model(
            owner: ctx.username,
            name: ctx.shortName(repoID)
        ).exists()
        #expect(existsAfterCreate)

        try await ctx.client.deleteRepository(type: .model, repoID: repoID)

        // Verify it no longer exists.
        let existsAfterDelete = try await ctx.client.model(
            owner: ctx.username,
            name: ctx.shortName(repoID)
        ).exists()
        #expect(!existsAfterDelete)
    }

    @Test("createRepository(existOk: true) does not throw on duplicate")
    func createWithExistOk() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }
        let repoID = ctx.uniqueRepoID()

        try await ctx.runWithCleanup(repoID: repoID, type: .model) {
            try await ctx.client.createRepository(
                type: .model,
                repoID: repoID,
                private: true
            )
            // Second call with existOk=true should succeed and return the same URL.
            let url = try await ctx.client.createRepository(
                type: .model,
                repoID: repoID,
                private: true,
                existOk: true
            )
            #expect(url.absoluteString.contains(repoID))
        }
    }

    @Test("deleteRepository(missingOk: true) does not throw on missing repo")
    func deleteWithMissingOk() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }
        let repoID = ctx.uniqueRepoID()

        // Repo never existed; missingOk=true must swallow the 404.
        try await ctx.client.deleteRepository(
            type: .model,
            repoID: repoID,
            missingOk: true
        )
    }

    @Test("moveRepository renames a model repo")
    func moveModel() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }
        let fromID = ctx.uniqueRepoID()
        let toID = ctx.uniqueRepoID()

        // After the move, only `toID` exists; if the move fails, only
        // `fromID` exists. Pass both – `missingOk: true` skips the absent
        // one without erroring.
        try await ctx.runWithCleanup(repoIDs: [fromID, toID], type: .model) {
            try await ctx.client.createRepository(
                type: .model,
                repoID: fromID,
                private: true
            )

            let movedURL = try await ctx.client.moveRepository(
                type: .model,
                from: fromID,
                to: toID
            )
            #expect(movedURL.absoluteString.contains(toID))

            let toName = ctx.shortName(toID)
            // The Hub returns a redirect from the old name to the new – exists()
            // can return true for the old slug for a short time. Only assert
            // the destination definitely exists.
            let movedExists = try await ctx.client.model(
                owner: ctx.username,
                name: toName
            ).exists()
            #expect(movedExists)
        }
    }

    @Test("create + delete round-trip on a dataset repo")
    func createDeleteDataset() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }

        let repoID = ctx.uniqueRepoID()
        try await ctx.runWithCleanup(repoID: repoID, type: .dataset) {
            let url = try await ctx.client.createRepository(
                type: .dataset,
                repoID: repoID,
                private: true
            )
            #expect(url.absoluteString.contains(repoID))

            let existsAfterCreate = try await ctx.client.dataset(
                owner: ctx.username,
                name: ctx.shortName(repoID)
            ).exists()
            #expect(existsAfterCreate)
        }

        // After cleanup the repo should be gone.
        let existsAfterDelete = try await ctx.client.dataset(
            owner: ctx.username,
            name: ctx.shortName(repoID)
        ).exists()
        #expect(!existsAfterDelete)
    }

    @Test("moveRepository renames a dataset repo")
    func moveDataset() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }
        let fromID = ctx.uniqueRepoID()
        let toID = ctx.uniqueRepoID()

        try await ctx.runWithCleanup(repoIDs: [fromID, toID], type: .dataset) {
            try await ctx.client.createRepository(
                type: .dataset,
                repoID: fromID,
                private: true
            )

            let movedURL = try await ctx.client.moveRepository(
                type: .dataset,
                from: fromID,
                to: toID
            )
            #expect(movedURL.absoluteString.contains(toID))

            let movedExists = try await ctx.client.dataset(
                owner: ctx.username,
                name: ctx.shortName(toID)
            ).exists()
            #expect(movedExists)
        }
    }

    @Test("updateSettings(gated:) round-trips a typed gating mode")
    func updateSettingsGatedRoundTrip() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }
        let repoID = ctx.uniqueRepoID()

        try await ctx.runWithCleanup(repoID: repoID, type: .model) {
            try await ctx.client.createRepository(
                type: .model,
                repoID: repoID,
                private: true
            )

            let model = ctx.client.model(
                owner: ctx.username,
                name: ctx.shortName(repoID)
            )

            // Flip gating to `auto` and confirm the typed `info().gated`
            // round-trips to ``GatedMode/auto``. Then flip to
            // `disabled` and confirm we read back ``GatedMode/disabled``.
            try await model.updateSettings(gated: .auto)
            let afterAuto = try await model.info()
            #expect(afterAuto.gated == .auto)

            try await model.updateSettings(gated: .disabled)
            let afterDisabled = try await model.info()
            #expect(afterDisabled.gated == .disabled)
        }
    }

    @Test("updateSettings flips the private flag")
    func updateSettingsTogglesPrivacy() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "lifecycle") else { return }
        let repoID = ctx.uniqueRepoID()

        try await ctx.runWithCleanup(repoID: repoID, type: .model) {
            try await ctx.client.createRepository(
                type: .model,
                repoID: repoID,
                private: true
            )

            let model = ctx.client.model(
                owner: ctx.username,
                name: ctx.shortName(repoID)
            )

            let initial = try await model.info()
            #expect(initial.isPrivate == true)

            try await model.updateSettings(private: false)

            let afterToggle = try await model.info()
            #expect(afterToggle.isPrivate == false)
        }
    }
}
