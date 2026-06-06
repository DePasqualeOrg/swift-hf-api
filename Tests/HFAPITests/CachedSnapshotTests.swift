// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

@Suite("CacheInfo.cachedSnapshot(containing:)")
struct CachedSnapshotTests {
    @Test("Returns snapshot URL when every pattern is satisfied")
    func returnsSnapshotForFullMatch() async throws {
        let (info, repoLayout) = try await buildSampleCache(filenames: [
            "config.json",
            "tokenizer.json",
            "weights.safetensors",
        ])
        defer { repoLayout.cleanup() }

        let url = info.cachedSnapshot(
            repoId: repoLayout.repoId,
            type: .model,
            revision: repoLayout.commitHash,
            containing: ["config.json", "tokenizer.json", "*.safetensors"]
        )
        #expect(url?.standardizedFileURL.path == repoLayout.snapshotURL.standardizedFileURL.path)
    }

    @Test("Returns nil when a pattern is unsatisfied")
    func nilOnMissingPattern() async throws {
        let (info, repoLayout) = try await buildSampleCache(filenames: [
            "config.json",
            "tokenizer.json",
        ])
        defer { repoLayout.cleanup() }

        let url = info.cachedSnapshot(
            repoId: repoLayout.repoId,
            type: .model,
            revision: repoLayout.commitHash,
            containing: ["config.json", "*.safetensors"]
        )
        #expect(url == nil)
    }

    @Test("Empty patterns degrades to dir-existence check")
    func emptyPatternsDirExistence() async throws {
        let (info, repoLayout) = try await buildSampleCache(filenames: ["only.json"])
        defer { repoLayout.cleanup() }

        let url = info.cachedSnapshot(
            repoId: repoLayout.repoId,
            type: .model,
            revision: repoLayout.commitHash,
            containing: []
        )
        #expect(url?.standardizedFileURL.path == repoLayout.snapshotURL.standardizedFileURL.path)
    }

    @Test("Returns nil for an uncached repo")
    func nilForUncachedRepo() async throws {
        let (info, repoLayout) = try await buildSampleCache(filenames: ["config.json"])
        defer { repoLayout.cleanup() }

        let absent = try RepositoryID(owner: "owner", name: "absent-model")
        let url = info.cachedSnapshot(
            repoId: absent,
            type: .model,
            revision: repoLayout.commitHash,
            containing: ["config.json"]
        )
        #expect(url == nil)
    }

    @Test("Returns nil when the revision is not cached")
    func nilForUnknownRevision() async throws {
        let (info, repoLayout) = try await buildSampleCache(filenames: ["config.json"])
        defer { repoLayout.cleanup() }

        let url = info.cachedSnapshot(
            repoId: repoLayout.repoId,
            type: .model,
            revision: "1111111111111111111111111111111111111111",
            containing: ["config.json"]
        )
        #expect(url == nil)
    }

    @Test("Returns nil for the wrong RepoType (model vs dataset)")
    func nilForWrongType() async throws {
        let (info, repoLayout) = try await buildSampleCache(filenames: ["config.json"])
        defer { repoLayout.cleanup() }

        let url = info.cachedSnapshot(
            repoId: repoLayout.repoId,
            type: .dataset,
            revision: repoLayout.commitHash,
            containing: ["config.json"]
        )
        #expect(url == nil)
    }
}

// MARK: - Test helpers

private struct SampleRepoLayout {
    let cacheDir: URL
    let repoId: RepositoryID
    let commitHash: String
    let snapshotURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: cacheDir)
    }
}

/// Build a minimal valid cached repo layout for `models--owner--name` with a
/// single revision containing the requested `filenames`. Each filename gets
/// a real blob (one byte) and a snapshot symlink pointer, so the upstream
/// walker resolves them cleanly without warnings.
private func buildSampleCache(filenames: [String]) async throws -> (CacheInfo, SampleRepoLayout) {
    let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-test-\(UUID().uuidString)")
    let repoFolder = cacheDir.appendingPathComponent("models--owner--my-model")
    let blobsDir = repoFolder.appendingPathComponent("blobs")
    let commitHash = "0000000000000000000000000000000000000001"
    let snapshotDir =
        repoFolder
        .appendingPathComponent("snapshots")
        .appendingPathComponent(commitHash)
    try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

    for (i, filename) in filenames.enumerated() {
        let blob = blobsDir.appendingPathComponent(String(format: "blob%02d", i))
        try Data([0x42]).write(to: blob)
        let pointer = snapshotDir.appendingPathComponent(filename)
        if let parent = pointer.deletingLastPathComponent() as URL?,
            parent.path != snapshotDir.path
        {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: blob)
    }

    let client = try HFClient(cacheDirectory: cacheDir)
    let info = try await client.scanCache()
    let layout = SampleRepoLayout(
        cacheDir: cacheDir,
        repoId: try RepositoryID(owner: "owner", name: "my-model"),
        commitHash: commitHash,
        snapshotURL: snapshotDir
    )
    return (info, layout)
}
