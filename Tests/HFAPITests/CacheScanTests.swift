// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for `scanCache()` introduced in Phase 3f. Each test
/// uses an isolated cache dir so it doesn't depend on or pollute the
/// user's real cache, then downloads a tiny file and re-scans to verify
/// the cache was discovered correctly.
@Suite("HFClient.scanCache – local")
struct CacheScanTests {
    @Test("scanCache() on an empty cache returns no repos and zero size")
    func emptyCache() async throws {
        let (client, cacheDir) = try makeIsolatedClient()

        let info = try await client.scanCache()

        #expect(info.cacheDirectory.path == cacheDir.path)
        #expect(info.repos.isEmpty)
        #expect(info.sizeOnDisk == 0)
        // No warnings on an empty / nonexistent cache.
        #expect(info.warnings.isEmpty)
    }

    @Test("scanCache() surfaces a warning for a dangling snapshot symlink")
    func danglingSnapshotProducesWarning() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Build a minimal `models--owner--name/snapshots/<sha>/<file>` layout
        // where `<file>` is a symlink to a blob that does not exist. The
        // upstream walker's `resolve_blob_info` will fail to canonicalize
        // the missing target and push a `"Cannot resolve …"` entry into
        // `warnings`. The exact wording is not part of the stable API – the
        // matching below substring-checks for one of the documented
        // categories.
        let repoDir = cacheDir.appendingPathComponent("models--owner--name")
        let snapshotDir =
            repoDir
            .appendingPathComponent("snapshots")
            .appendingPathComponent("0000000000000000000000000000000000000000")
        let blobsDir = repoDir.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let pointer = snapshotDir.appendingPathComponent("dangling.txt")
        let missingBlob = blobsDir.appendingPathComponent("deadbeef")
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: missingBlob)

        let client = try HFClient(cacheDirectory: cacheDir)
        let info = try await client.scanCache()

        #expect(!info.warnings.isEmpty, "expected a warning for the dangling symlink")
        // The walker emits either `Cannot resolve` (canonicalize failed) or
        // `Cannot read blob for` (metadata failed), parsed into the typed
        // enum cases. Lock the classification rather than substring-match
        // the raw string.
        let classified = info.warnings.contains { warning in
            switch warning {
            case .danglingSnapshot, .unreadableBlob: true
            case .other: false
            }
        }
        #expect(
            classified,
            "expected a danglingSnapshot or unreadableBlob warning, got: \(info.warnings)"
        )
    }

    @Test("scanCache() yields an empty-revisions entry for a malformed repo dir")
    func malformedRepoYieldsEmptyEntry() async throws {
        // hf-hub's scan walks `models--<owner>--<name>` directories looking
        // for `refs/`, `snapshots/`, and `blobs/`. A directory matching the
        // name shape but missing those subdirs is parsed as a repo entry
        // with zero revisions and zero size – neither a hard error nor an
        // omission. Lock in this contract so a future hf-hub change that
        // started returning bogus revision data, or that silently dropped
        // the entry, is caught.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let bogusRepo = cacheDir.appendingPathComponent("models--bogus--brokenrepo")
        try FileManager.default.createDirectory(
            at: bogusRepo,
            withIntermediateDirectories: true
        )

        let client = try HFClient(cacheDirectory: cacheDir)
        let info = try await client.scanCache()

        let entry = info.repos.first { $0.repoID.contains("brokenrepo") }
        let broken = try #require(entry, "expected malformed dir to surface as a CachedRepoInfo")
        // A malformed entry is empty of revisions, files, and bytes —
        // anything else is a regression hiding cache corruption.
        #expect(broken.revisions.isEmpty)
        #expect(broken.nbFiles == 0)
        #expect(broken.sizeOnDisk == 0)
    }

    @Test("scanCache() after a download lists the downloaded repo and revision")
    func populatedCache() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let downloaded = try await fetchOrSkip({
                try await model.downloadFile("config.json")
            })
        else { return }
        #expect(FileManager.default.fileExists(atPath: downloaded.path))

        let info = try await client.scanCache()

        #expect(info.repos.count == 1)
        let repo = try #require(info.repos.first)

        #expect(repo.repoID == "openai-community/gpt2")
        #expect(repo.type == .model)
        #expect(repo.nbFiles >= 1)
        #expect(repo.sizeOnDisk > 0)
        #expect(info.sizeOnDisk >= repo.sizeOnDisk)

        // The downloaded revision should carry the resolved commit and
        // expose the file we just pulled.
        #expect(!repo.revisions.isEmpty)
        let revision = try #require(repo.revisions.first)
        #expect(!revision.commitHash.isEmpty)
        #expect(revision.files.contains { $0.fileName == "config.json" })
    }
}

private func makeIsolatedClient() throws -> (HFClient, URL) {
    let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-test-\(UUID().uuidString)")
    // The Rust crate creates the cache lazily, so the dir doesn't need
    // to exist up front.
    let client = try HFClient(cacheDirectory: cacheDir)
    return (client, cacheDir)
}
