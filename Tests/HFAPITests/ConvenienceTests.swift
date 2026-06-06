// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the protocol-default convenience methods on
/// ``RepositoryProtocol``: ``fileExists(_:revision:)``,
/// ``uploadFiles(files:revision:commitMessage:commitDescription:createPR:parentCommit:progress:)``,
/// and ``deleteFiles(pathsInRepo:revision:commitMessage:createPR:)``.
///
/// ``fileExists`` is read-only and covered against a stable public repo;
/// the upload/delete pair are mutation tests gated on
/// `HFAPI_RUN_HUB_MUTATION_TESTS=1`.

@Suite("Repository.fileExists – live Hub", .enabled(if: integrationTestsEnabled))
struct FileExistsTests {
    @Test("fileExists returns true for a known-present file in a public repo")
    func presentFile() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")
        do {
            let exists = try await model.fileExists("config.json")
            #expect(exists)
        } catch let error as HFError where error.isTransient {
            return
        }
    }

    @Test("fileExists returns false for an absent file in a public repo")
    func absentFile() async throws {
        let client = try HFClient()
        let model = client.model(owner: "openai-community", name: "gpt2")
        do {
            let exists = try await model.fileExists("definitely-not-a-real-file.txt")
            #expect(!exists)
        } catch let error as HFError where error.isTransient {
            return
        }
    }

}

@Suite("Repository.uploadFiles / deleteFiles – live Hub", .enabled(if: integrationTestsEnabled))
struct ConvenienceMutationTests {
    @Test("uploadFiles lands two files in a single commit")
    func uploadFilesRoundTrip() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "uploadfiles") else {
            return
        }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("hf-uploadfiles-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fileA = tempDir.appendingPathComponent("a.txt")
            let fileB = tempDir.appendingPathComponent("b.txt")
            try Data("alpha\n".utf8).write(to: fileA)
            try Data("beta\n".utf8).write(to: fileB)

            let info = try await fresh.repo.uploadFiles(files: [
                "first/a.txt": fileA,
                "second/b.txt": fileB,
            ])
            #expect(info.commitOID != nil)

            // Both should land in one commit – not two – so the commit
            // count after the create should be exactly 2 (initial + ours).
            let commits = try await fresh.repo.listCommits()
            #expect(commits.count == 2)

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(paths.contains("first/a.txt"))
            #expect(paths.contains("second/b.txt"))

            let bytesA = try await fresh.repo.downloadFileToBytes("first/a.txt")
            #expect(bytesA == Data("alpha\n".utf8))
            let bytesB = try await fresh.repo.downloadFileToBytes("second/b.txt")
            #expect(bytesB == Data("beta\n".utf8))
        }
    }

    @Test("deleteFiles removes two files in a single commit")
    func deleteFilesRoundTrip() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "deletefiles") else {
            return
        }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {
            // Seed three files; delete two; the third must survive.
            _ = try await fresh.repo.createCommit(
                operations: [
                    .bytes(Data("first\n".utf8), pathInRepo: "one.txt"),
                    .bytes(Data("second\n".utf8), pathInRepo: "two.txt"),
                    .bytes(Data("survives\n".utf8), pathInRepo: "keep.txt"),
                ],
                commitMessage: "seed"
            )

            let info = try await fresh.repo.deleteFiles(
                pathsInRepo: ["one.txt", "two.txt"]
            )
            #expect(info.commitOID != nil)

            // After-state: only `keep.txt` remains. The deletion must be
            // a single commit; commit count after seed+delete should be 3
            // (initial + seed + delete), not 4.
            let commits = try await fresh.repo.listCommits()
            #expect(commits.count == 3)

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(!paths.contains("one.txt"))
            #expect(!paths.contains("two.txt"))
            #expect(paths.contains("keep.txt"))
        }
    }
}

private func entryPath(_ entry: RepoTreeEntry) -> String {
    switch entry {
    case .file(_, _, let path, _, _, _, _): return path
    case .directory(_, let path, _): return path
    }
}
