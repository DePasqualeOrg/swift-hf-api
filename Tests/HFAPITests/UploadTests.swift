// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 4d upload endpoints:
/// ``RepositoryProtocol/uploadFile(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:progress:)``,
/// ``RepositoryProtocol/uploadFileBytes(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:progress:)``, and
/// ``RepositoryProtocol/uploadFileStream(_:pathInRepo:revision:commitMessage:commitDescription:createPR:parentCommit:)``.
/// Also covers the ``RepositoryProtocol/deleteFolder(_:revision:commitMessage:createPR:)``
/// round-trip that was deferred from Phase 4c – uploadFile populates a
/// nested folder and deleteFolder tears it down.
///
/// Each test creates a fresh isolated repo under the authenticated
/// user's namespace and tears it down afterward. Tests skip cleanly
/// when no token is configured.

@Suite("Repository upload – live Hub", .enabled(if: integrationTestsEnabled))
struct UploadTests {
    @Test("uploadFileBytes round-trip: upload + download round-trips the same content")
    func uploadBytesRoundTrip() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "upload") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let payload = Data("hello from swift-hf-api\n".utf8)
            let info = try await fresh.repo.uploadFileBytes(
                payload,
                pathInRepo: "hello.txt",
                commitMessage: "Upload hello.txt"
            )
            #expect(info.commitOID != nil)

            let downloaded = try await fresh.repo.downloadFileToBytes("hello.txt")
            #expect(downloaded == payload)
        }
    }

    @Test("uploadFile round-trip from a local file path")
    func uploadFromPath() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "upload") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("hf-upload-\(UUID().uuidString).txt")
            let payload = Data("file uploaded via local path\n".utf8)
            try payload.write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let info = try await fresh.repo.uploadFile(
                tempFile,
                pathInRepo: "from-disk.txt"
            )
            #expect(info.commitOID != nil)

            let downloaded = try await fresh.repo.downloadFileToBytes("from-disk.txt")
            #expect(downloaded == payload)
        }
    }

    @Test("uploadFileStream emits UploadEvents and returns CommitInfo")
    func uploadStreamEvents() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "upload") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("hf-upload-stream-\(UUID().uuidString).bin")
            // 256 KiB random bytes – enough to potentially trigger xet path
            // events but small enough to upload fast.
            var rng = SystemRandomNumberGenerator()
            var bytes = Data(count: 256 * 1024)
            bytes.withUnsafeMutableBytes { buf in
                let ptr = buf.bindMemory(to: UInt64.self)
                for i in 0 ..< ptr.count {
                    ptr[i] = rng.next()
                }
            }
            try bytes.write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let stream = fresh.repo.uploadFileStream(
                tempFile,
                pathInRepo: "random.bin"
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

            // The upstream contract guarantees `committing` and `complete`
            // for a successful upload. `start` and `progress` may be elided
            // for small inline files – don't assert on them.
            #expect(sawCommitting)
            #expect(sawComplete)

            let info = try await stream.value
            #expect(info.commitOID != nil)
        }
    }

    @Test("uploadFileBytesStream emits UploadEvents and round-trips the same bytes")
    func uploadBytesStreamEvents() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "upload") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // 256 KiB random bytes – distinct FFI path from
            // `uploadFileStream` (which reads from a path) so the round
            // trip needs its own coverage.
            var rng = SystemRandomNumberGenerator()
            var bytes = Data(count: 256 * 1024)
            bytes.withUnsafeMutableBytes { buf in
                let ptr = buf.bindMemory(to: UInt64.self)
                for i in 0 ..< ptr.count {
                    ptr[i] = rng.next()
                }
            }

            let stream = fresh.repo.uploadFileBytesStream(
                bytes,
                pathInRepo: "bytes-stream.bin"
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

            // Round-trip: download the same bytes back and confirm they
            // match exactly. Catches data-corruption regressions in the
            // bytes-stream FFI path.
            let downloaded = try await fresh.repo.downloadFileToBytes(
                "bytes-stream.bin"
            )
            #expect(downloaded == bytes)
        }
    }

    @Test("uploadFile populates a folder; deleteFolder removes it")
    func uploadThenDeleteFolder() async throws {
        guard let ctx = try await MutationTestContext.makeOrSkip(prefix: "upload") else { return }
        let fresh = try await ctx.makeFreshModelRepo()
        try await ctx.runWithCleanup(repoID: fresh.repoID) {

            // Upload two files inside `nested/` so deleteFolder("nested")
            // has work to do.
            try await fresh.repo.uploadFileBytes(
                Data("a\n".utf8),
                pathInRepo: "nested/a.txt"
            )
            try await fresh.repo.uploadFileBytes(
                Data("b\n".utf8),
                pathInRepo: "nested/b.txt"
            )

            // Verify both files exist.
            let beforeEntries = try await fresh.repo.listTree(recursive: true)
            let beforePaths = beforeEntries.map(entryPath)
            #expect(beforePaths.contains("nested/a.txt"))
            #expect(beforePaths.contains("nested/b.txt"))

            // Delete the folder.
            let info = try await fresh.repo.deleteFolder("nested")
            #expect(info.commitOID != nil)

            // Verify both files are gone.
            let afterEntries = try await fresh.repo.listTree(recursive: true)
            let afterPaths = afterEntries.map(entryPath)
            #expect(!afterPaths.contains("nested/a.txt"))
            #expect(!afterPaths.contains("nested/b.txt"))
        }
    }
}

private func entryPath(_ entry: RepoTreeEntry) -> String {
    switch entry {
    case .file(_, _, let path, _, _, _, _): return path
    case .directory(_, let path, _): return path
    }
}
