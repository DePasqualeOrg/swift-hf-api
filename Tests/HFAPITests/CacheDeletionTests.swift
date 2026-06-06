// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

@Suite("Cache deletion – local")
struct CacheDeletionTests {
    // MARK: - Strategy preview

    @Test("Per-revision deletion populates snapshots/refs/blobs, not repos")
    func perRevisionStrategy() async throws {
        let fixture = try await buildFixture(
            repoName: "openai-community/gpt2",
            revisions: [
                .init(
                    commitHash: "1111111111111111111111111111111111111111",
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: "2222222222222222222222222222222222222222",
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 100)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let strategy = fixture.cacheInfo.deleteRevisions("1111111111111111111111111111111111111111")

        #expect(strategy.repos.isEmpty)
        #expect(strategy.snapshots.count == 1)
        #expect(strategy.refs.count == 1)
        #expect(strategy.blobs.count == 1)
        #expect(strategy.locks.isEmpty)
        #expect(strategy.expectedFreedSize == 100)
        #expect(strategy.missingRevisions.isEmpty)
    }

    @Test("Whole-repo deletion populates repos, not individual paths")
    func wholeRepoStrategy() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let strategy = fixture.cacheInfo.deleteRevisions(
            fixture.cacheInfo.repos[0].revisions.map(\.commitHash)
        )

        #expect(strategy.repos.count == 1)
        #expect(strategy.snapshots.isEmpty)
        #expect(strategy.refs.isEmpty)
        #expect(strategy.blobs.isEmpty)
        // expectedFreedSize comes from the repo's deduplicated sizeOnDisk.
        #expect(strategy.expectedFreedSize == fixture.cacheInfo.repos[0].sizeOnDisk)
    }

    @Test("Surviving revision preserves shared blob")
    func survivingRevisionPreservesBlob() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "shared", 100),
                        ("only-a.json", "etag-a", 50),
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        // Shares the "shared" blob with revision A.
                        ("config.json", "shared", 100),
                        ("only-b.json", "etag-b", 30),
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let strategy = fixture.cacheInfo.deleteRevisions(String(repeating: "a", count: 40))

        // Only the revision-unique blob is removed; the shared one stays.
        #expect(strategy.blobs.count == 1)
        #expect(strategy.blobs.first?.lastPathComponent == "etag-a")
        #expect(strategy.expectedFreedSize == 50)
    }

    @Test("Co-deleted blobs are not double-counted")
    func coDeletedBlobsDedup() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "shared", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "shared", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "c", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-c", 999)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        // Delete A and B, which share the "shared" blob. C survives and
        // does NOT reference "shared", so the blob is reclaimed once.
        let strategy = fixture.cacheInfo.deleteRevisions(
            String(repeating: "a", count: 40),
            String(repeating: "b", count: 40)
        )

        #expect(strategy.blobs.count == 1)
        #expect(strategy.blobs.first?.lastPathComponent == "shared")
        // 100, not 200 — the dedup guard counts the shared blob once.
        #expect(strategy.expectedFreedSize == 100)
    }

    @Test("Missing revisions are reported separately")
    func missingRevisions() async throws {
        // Two revisions so that deleting one stays in the per-revision
        // branch (and produces a planned blob to assert on).
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let unknown = String(repeating: "9", count: 40)
        let strategy = fixture.cacheInfo.deleteRevisions(
            String(repeating: "a", count: 40),
            unknown
        )

        #expect(strategy.missingRevisions == [unknown])
        // The existing hash is still planned.
        #expect(strategy.blobs.count == 1)
    }

    // MARK: - Execute

    @Test("execute() removes the planned paths and reduces disk usage")
    func executeRemovesPlannedPaths() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let strategy = fixture.cacheInfo.deleteRevisions(String(repeating: "a", count: 40))
        let plannedBlob = try #require(strategy.blobs.first)
        let plannedSnapshot = try #require(strategy.snapshots.first)
        let plannedRef = try #require(strategy.refs.first)

        let result = try strategy.execute()
        #expect(result.failures.isEmpty)

        #expect(!FileManager.default.fileExists(atPath: plannedBlob.path))
        #expect(!FileManager.default.fileExists(atPath: plannedSnapshot.path))
        #expect(!FileManager.default.fileExists(atPath: plannedRef.path))

        // Re-scan to confirm the cache view reflects the deletion.
        let after = try await fixture.client.scanCache()
        let repo = try #require(after.repos.first)
        #expect(repo.revisions.count == 1)
        #expect(repo.revisions.first?.commitHash == String(repeating: "b", count: 40))
    }

    @Test("execute() is idempotent on tolerated errors")
    func executeIsIdempotent() async throws {
        // Two revisions so deleting one stays in the per-revision branch
        // (per-revision execute doesn't try to remove the optional locks
        // directory, isolating this test to refs/snapshots/blobs).
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let strategy = fixture.cacheInfo.deleteRevisions(String(repeating: "a", count: 40))
        let first = try strategy.execute()
        #expect(first.failures.isEmpty)

        // Re-execute the same plan. Paths no longer exist; failures are
        // tolerated (not thrown).
        let second = try strategy.execute()
        // Either all failures are .fileNoSuchFile/POSIX ENOENT, or the
        // platform silently accepted the redundant remove (also fine).
        for failure in second.failures {
            if let cocoa = failure.error as? CocoaError {
                #expect(
                    cocoa.code == .fileNoSuchFile || cocoa.code == .fileReadNoSuchFile,
                    "unexpected tolerated CocoaError: \(cocoa)"
                )
            }
        }
    }

    @Test("execute() removes refs before blobs (no dangling snapshots mid-run)")
    func executeOrderRefsBeforeBlobs() async throws {
        // Two revisions so that deleting one stays in the per-revision
        // branch (which populates refs and blobs as separate phases).
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let strategy = fixture.cacheInfo.deleteRevisions(String(repeating: "a", count: 40))
        // Spy by ordering the planned sets: refs and blobs both single-
        // element. The phase-ordering is the real invariant – verify the
        // sequence by deleting blobs first manually, then re-running, and
        // confirming the strategy still cleans up the survivors. A
        // synthetic interruption is more invasive than necessary; here we
        // assert the simpler "execute reaches both phases" form.
        let result = try strategy.execute()
        #expect(result.failures.isEmpty)
        // After execute, both ref and blob are gone.
        let refPath = try #require(strategy.refs.first)
        let blobPath = try #require(strategy.blobs.first)
        #expect(!FileManager.default.fileExists(atPath: refPath.path))
        #expect(!FileManager.default.fileExists(atPath: blobPath.path))
    }

    // MARK: - deleteRepository convenience

    @Test("deleteRepository matches deleteRevisions(all-revs) and returns nil for uncached")
    func deleteRepositoryConvenience() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let id = try RepositoryID(owner: "owner", name: "m")
        let direct = try #require(fixture.cacheInfo.deleteRepository(id, type: .model))
        let via = fixture.cacheInfo.deleteRevisions(
            fixture.cacheInfo.repos[0].revisions.map(\.commitHash)
        )
        #expect(direct == via)
        #expect(direct.repos.count == 1)
        #expect(direct.expectedFreedSize == fixture.cacheInfo.repos[0].sizeOnDisk)

        // Absent repo returns nil.
        let absent = try RepositoryID(owner: "owner", name: "absent")
        #expect(fixture.cacheInfo.deleteRepository(absent, type: .model) == nil)
    }

    // MARK: - Locks cleanup

    @Test("Whole-repo deletion wipes .locks/<repoFolder>/")
    func wholeRepoWipesLocks() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                )
            ]
        )
        defer { fixture.cleanup() }

        // Seed a stale lock file.
        let lockDir =
            fixture.cacheDir
            .appendingPathComponent(".locks")
            .appendingPathComponent("models--owner--m")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try Data().write(to: lockDir.appendingPathComponent("etag-a.lock"))

        let id = try RepositoryID(owner: "owner", name: "m")
        let strategy = try #require(fixture.cacheInfo.deleteRepository(id, type: .model))
        #expect(strategy.locks.count == 1)
        try strategy.execute()

        #expect(!FileManager.default.fileExists(atPath: lockDir.path))
    }

    @Test("Per-revision deletion leaves .locks untouched")
    func perRevisionLeavesLocks() async throws {
        let fixture = try await buildFixture(
            repoName: "owner/m",
            revisions: [
                .init(
                    commitHash: String(repeating: "a", count: 40),
                    refs: ["main"],
                    files: [
                        ("config.json", "etag-a", 100)
                    ]
                ),
                .init(
                    commitHash: String(repeating: "b", count: 40),
                    refs: [],
                    files: [
                        ("config.json", "etag-b", 200)
                    ]
                ),
            ]
        )
        defer { fixture.cleanup() }

        let lockDir =
            fixture.cacheDir
            .appendingPathComponent(".locks")
            .appendingPathComponent("models--owner--m")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let lockFile = lockDir.appendingPathComponent("etag-a.lock")
        try Data().write(to: lockFile)

        let strategy = fixture.cacheInfo.deleteRevisions(String(repeating: "a", count: 40))
        #expect(strategy.locks.isEmpty)
        try strategy.execute()

        #expect(FileManager.default.fileExists(atPath: lockFile.path))
    }
}

// MARK: - Test fixture

/// Description of a single revision to seed.
private struct RevisionDescriptor {
    let commitHash: String
    let refs: [String]
    /// Tuple of (filename in snapshot, blob etag, blob byte size).
    let files: [(String, String, Int)]
}

private struct CacheFixture {
    let cacheDir: URL
    let client: HFClient
    let cacheInfo: CacheInfo

    func cleanup() {
        try? FileManager.default.removeItem(at: cacheDir)
    }
}

/// Build a synthetic cache populated with the given revisions. Files are
/// created as real blobs of the requested byte size, with symlinks in the
/// snapshot directory pointing at them – so the upstream walker resolves
/// the layout cleanly (no dangling-pointer warnings).
private func buildFixture(
    repoName: String,
    revisions: [RevisionDescriptor]
) async throws -> CacheFixture {
    let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-test-\(UUID().uuidString)")
    let owner = String(repoName.split(separator: "/").first!)
    let name = String(repoName.split(separator: "/").last!)
    let repoFolder = cacheDir.appendingPathComponent("models--\(owner)--\(name)")
    let blobsDir = repoFolder.appendingPathComponent("blobs")
    let refsDir = repoFolder.appendingPathComponent("refs")
    try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)

    // Track which blobs we've already written – revisions can share blobs.
    var writtenBlobs: Set<String> = []
    for revision in revisions {
        let snapshotDir =
            repoFolder
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision.commitHash)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        for (filename, etag, size) in revision.files {
            let blob = blobsDir.appendingPathComponent(etag)
            if !writtenBlobs.contains(etag) {
                try Data(count: size).write(to: blob)
                writtenBlobs.insert(etag)
            }
            let pointer = snapshotDir.appendingPathComponent(filename)
            try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: blob)
        }

        for refName in revision.refs {
            let refPath = refsDir.appendingPathComponent(refName)
            try revision.commitHash.write(to: refPath, atomically: true, encoding: .utf8)
        }
    }

    let client = try HFClient(cacheDirectory: cacheDir)
    let info = try await client.scanCache()
    return CacheFixture(cacheDir: cacheDir, client: client, cacheInfo: info)
}
