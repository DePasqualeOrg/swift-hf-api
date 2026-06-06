// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 4c delete endpoints. `delete_file`
/// is exercised against a freshly created repo's auto-generated
/// `.gitattributes`. `delete_folder` is wired but not tested live in
/// this sub-phase: a fresh repo has no nested folder to operate on,
/// and uploads land in Phase 4d/4e where the round-trip becomes
/// natural.

@Suite("Repository delete_file – live Hub", .enabled(if: integrationTestsEnabled))
struct DeleteFileTests {
    @Test("deleteFile removes .gitattributes from a freshly created repo")
    func deleteAutoCreatedGitattributes() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "delete") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // The Hub seeds new repos with a `.gitattributes` file. Verify
            // it's there before deleting.
            let initialEntries = try await fresh.repo.listTree()
            let initialPaths = initialEntries.map(entryPath)
            guard initialPaths.contains(".gitattributes") else {
                // Hub behavior changed; nothing to delete.
                Issue.record(
                    "expected freshly created repo to seed .gitattributes; got \(initialPaths)"
                )
                return
            }

            let info = try await fresh.repo.deleteFile(
                ".gitattributes",
                commitMessage: "Test delete via swift-hf-api"
            )
            #expect(info.commitOID != nil)

            let afterEntries = try await fresh.repo.listTree()
            let afterPaths = afterEntries.map(entryPath)
            #expect(!afterPaths.contains(".gitattributes"))
        }
    }

    @Test("deleteFile of a nonexistent path raises an error")
    func deleteMissingFile() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "delete") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // hf-hub maps a "no such entry" deletion to `.entryNotFound`;
            // accept the generic HTTP/request fallbacks so a future re-mapping
            // doesn't silently widen the contract.
            do {
                _ = try await fresh.repo.deleteFile(
                    "this-file-was-never-created.bin"
                )
                Issue.record("expected deleteFile of a missing path to throw")
            } catch HFError.entryNotFound, HFError.http, HFError.request {
                // expected
            } catch {
                Issue.record("unexpected error variant: \(error)")
            }
        }
    }
}

private func entryPath(_ entry: RepoTreeEntry) -> String {
    switch entry {
    case .file(_, _, let path, _, _, _, _): return path
    case .directory(_, let path, _): return path
    }
}
