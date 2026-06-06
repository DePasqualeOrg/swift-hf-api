// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 4f
/// ``RepositoryProtocol/createCommit(operations:commitMessage:…)``
/// endpoint and its streaming sibling.
///
/// Each test creates a fresh isolated repo under the authenticated user's
/// namespace and tears it down afterward. Tests skip cleanly when no token
/// is configured.

@Suite("Repository createCommit – live Hub", .enabled(if: integrationTestsEnabled))
struct CreateCommitTests {
    @Test("createCommit applies a mix of add (path + bytes) and delete in a single commit")
    func mixedOperations() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "commit") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // Seed a remote file that the same commit will delete.
            try await fresh.repo.uploadFileBytes(
                Data("stale\n".utf8),
                pathInRepo: "stale.txt"
            )

            // Local file backing the path-source add operation.
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("hf-commit-\(UUID().uuidString).txt")
            try Data("from-disk\n".utf8).write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let info = try await fresh.repo.createCommit(
                operations: [
                    .file(tempFile, pathInRepo: "from-disk.txt"),
                    .bytes(Data("from-bytes\n".utf8), pathInRepo: "from-bytes.txt"),
                    .delete(pathInRepo: "stale.txt"),
                ],
                commitMessage: "Mixed-op create_commit test"
            )
            #expect(info.commitOID != nil)

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(paths.contains("from-disk.txt"))
            #expect(paths.contains("from-bytes.txt"))
            #expect(!paths.contains("stale.txt"))

            // Verify content round-trips.
            let diskContent = try await fresh.repo.downloadFileToBytes("from-disk.txt")
            #expect(diskContent == Data("from-disk\n".utf8))
            let bytesContent = try await fresh.repo.downloadFileToBytes("from-bytes.txt")
            #expect(bytesContent == Data("from-bytes\n".utf8))
        }
    }

    @Test("createCommit with stale parentCommit fails")
    func staleParentCommitRejected() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "commit") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // Capture the current main SHA, then advance the branch with an
            // unrelated commit so the captured parent is stale.
            let initialRefs = try await fresh.repo.listRefs()
            guard let mainRef = initialRefs.branches.first(where: { $0.name == "main" }) else {
                Issue.record("repo has no main branch")
                return
            }
            let staleParent = mainRef.targetCommit

            try await fresh.repo.uploadFileBytes(
                Data("advance\n".utf8),
                pathInRepo: "advance.txt"
            )

            // The Hub responds 409 (parent revision differs from current HEAD);
            // accept `.conflict` or its generic `.http`/`.request` fallbacks
            // so a future re-mapping doesn't silently widen the contract.
            do {
                _ = try await fresh.repo.createCommit(
                    operations: [
                        .bytes(Data("nope\n".utf8), pathInRepo: "should-fail.txt")
                    ],
                    commitMessage: "Should fail on stale parent",
                    parentCommit: staleParent
                )
                Issue.record("expected stale-parent commit to throw")
            } catch HFError.conflict, HFError.http, HFError.request {
                // expected
            } catch {
                Issue.record("unexpected error variant: \(error)")
            }
        }
    }

    @Test("createCommitStream emits committing/complete and resolves to CommitInfo")
    func streamEvents() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "commit") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let stream = fresh.repo.createCommitStream(
                operations: [
                    .bytes(Data("a\n".utf8), pathInRepo: "a.txt"),
                    .bytes(Data("b\n".utf8), pathInRepo: "b.txt"),
                ],
                commitMessage: "Stream round-trip"
            )

            var sawCommitting = false
            var sawComplete = false
            for try await event in stream {
                switch event {
                case .committing: sawCommitting = true
                case .complete: sawComplete = true
                default: break
                }
            }
            #expect(sawCommitting)
            #expect(sawComplete)

            let info = try await stream.value
            #expect(info.commitOID != nil)
        }
    }
}

private func entryPath(_ entry: RepoTreeEntry) -> String {
    switch entry {
    case .file(_, _, let path, _, _, _, _): return path
    case .directory(_, let path, _): return path
    }
}
