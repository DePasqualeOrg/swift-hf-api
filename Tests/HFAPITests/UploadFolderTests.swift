// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 4e
/// ``RepositoryProtocol/uploadFolder(_:pathInRepo:revision:commitMessage:commitDescription:createPR:allowPatterns:ignorePatterns:deletePatterns:progress:)`` endpoint
/// and its ``RepositoryProtocol/uploadFolderStream(_:pathInRepo:revision:commitMessage:commitDescription:createPR:allowPatterns:ignorePatterns:deletePatterns:)`` sibling.
///
/// Each test creates a fresh isolated repo under the authenticated user's
/// namespace and tears it down afterward. Tests skip cleanly when no token
/// is configured.

@Suite("Repository uploadFolder – live Hub", .enabled(if: integrationTestsEnabled))
struct UploadFolderTests {
    @Test("uploadFolder uploads every file under a local directory")
    func roundTrip() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "folder") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let folder = try makeTempFolder(files: [
                "alpha.txt": Data("alpha\n".utf8),
                "beta.txt": Data("beta\n".utf8),
                "nested/gamma.txt": Data("gamma\n".utf8),
            ])
            defer { try? FileManager.default.removeItem(at: folder) }

            let info = try await fresh.repo.uploadFolder(
                folder,
                commitMessage: "Phase 4e folder round-trip"
            )
            #expect(info.commitOID != nil)

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(paths.contains("alpha.txt"))
            #expect(paths.contains("beta.txt"))
            #expect(paths.contains("nested/gamma.txt"))
        }
    }

    @Test("uploadFolder respects allowPatterns")
    func allowPatternsFilter() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "folder") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let folder = try makeTempFolder(files: [
                "keep.txt": Data("keep\n".utf8),
                "skip.bin": Data("skip\n".utf8),
                "nested/keep.txt": Data("keep nested\n".utf8),
                "nested/skip.bin": Data("skip nested\n".utf8),
            ])
            defer { try? FileManager.default.removeItem(at: folder) }

            try await fresh.repo.uploadFolder(
                folder,
                commitMessage: "Filtered folder upload",
                allowPatterns: ["**/*.txt"]
            )

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(paths.contains("keep.txt"))
            #expect(paths.contains("nested/keep.txt"))
            #expect(!paths.contains("skip.bin"))
            #expect(!paths.contains("nested/skip.bin"))
        }
    }

    @Test("uploadFolder respects deletePatterns to remove existing remote files")
    func deletePatternsWipe() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "folder") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // Seed two files on the remote first.
            try await fresh.repo.uploadFileBytes(
                Data("stale\n".utf8),
                pathInRepo: "old/stale.txt"
            )
            try await fresh.repo.uploadFileBytes(
                Data("survivor\n".utf8),
                pathInRepo: "keepme.txt"
            )

            // Local folder adds one new file and triggers a delete on `old/*`.
            let folder = try makeTempFolder(files: [
                "fresh.txt": Data("fresh\n".utf8)
            ])
            defer { try? FileManager.default.removeItem(at: folder) }

            try await fresh.repo.uploadFolder(
                folder,
                commitMessage: "Replace old/* with fresh content",
                deletePatterns: ["old/*"]
            )

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(paths.contains("fresh.txt"))
            #expect(paths.contains("keepme.txt"))
            #expect(!paths.contains("old/stale.txt"))
        }
    }

    @Test("uploadFolder respects ignorePatterns")
    func ignorePatternsFilter() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "folder") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let folder = try makeTempFolder(files: [
                "include.txt": Data("include\n".utf8),
                "exclude.tmp": Data("exclude\n".utf8),
                "nested/include.txt": Data("nested include\n".utf8),
                "nested/exclude.tmp": Data("nested exclude\n".utf8),
            ])
            defer { try? FileManager.default.removeItem(at: folder) }

            try await fresh.repo.uploadFolder(
                folder,
                commitMessage: "Folder upload with ignorePatterns",
                ignorePatterns: ["**/*.tmp"]
            )

            let entries = try await fresh.repo.listTree(recursive: true)
            let paths = Set(entries.map(entryPath))
            #expect(paths.contains("include.txt"))
            #expect(paths.contains("nested/include.txt"))
            #expect(!paths.contains("exclude.tmp"))
            #expect(!paths.contains("nested/exclude.tmp"))
        }
    }

    @Test("uploadFolder targets a non-main revision via the revision parameter")
    func uploadToNonMainRevision() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "folder") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // Create a `feature` branch off the freshly created repo's
            // main, then upload only into that branch. main must remain
            // empty of the new files.
            let branchName = "feature-\(UUID().uuidString.prefix(8).lowercased())"
            try await fresh.repo.createBranch(branchName)

            let folder = try makeTempFolder(files: [
                "branch-only.txt": Data("only on the branch\n".utf8)
            ])
            defer { try? FileManager.default.removeItem(at: folder) }

            try await fresh.repo.uploadFolder(
                folder,
                revision: branchName,
                commitMessage: "Upload only on \(branchName)"
            )

            let onBranch = try await fresh.repo.listTree(revision: branchName, recursive: true)
            let onBranchPaths = Set(onBranch.map(entryPath))
            #expect(onBranchPaths.contains("branch-only.txt"))

            let onMain = try await fresh.repo.listTree(recursive: true)
            let onMainPaths = Set(onMain.map(entryPath))
            #expect(!onMainPaths.contains("branch-only.txt"))
        }
    }

    @Test("uploadFolderStream emits UploadEvents and resolves with CommitInfo")
    func streamEvents() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "folder") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let folder = try makeTempFolder(files: [
                "a.txt": Data("a\n".utf8),
                "b.txt": Data("b\n".utf8),
            ])
            defer { try? FileManager.default.removeItem(at: folder) }

            let stream = fresh.repo.uploadFolderStream(
                folder,
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

/// Creates a temporary directory and writes the given files into it.
/// Keys are folder-relative paths; nested folders are created as needed.
private func makeTempFolder(files: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-upload-folder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (relPath, data) in files {
        let fileURL = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }
    return root
}
