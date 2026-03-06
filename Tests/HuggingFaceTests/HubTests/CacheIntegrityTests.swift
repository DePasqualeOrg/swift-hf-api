// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import HFAPI

#if swift(>=6.1) && !canImport(FoundationNetworking)
    @Suite("Cache Integrity Tests", .serialized)
    struct CacheIntegrityTests {
        static let cacheDirectory: URL = {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            return base.appending(component: "huggingface-cache-integrity-tests")
        }()

        init() {
            try? FileManager.default.removeItem(at: Self.cacheDirectory)
        }

        private func createClient() -> (client: HubClient, cache: HubCache) {
            let cache = HubCache(cacheDirectory: Self.cacheDirectory)
            let client = HubClient(
                host: URL(string: "https://huggingface.co")!,
                cache: cache
            )
            return (client, cache)
        }

        /// Finds blobs in the blobs directory (excluding .lock and .incomplete files).
        private func findBlobs(in blobsDir: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: blobsDir.path)
                .filter { !$0.hasSuffix(".lock") && !$0.hasSuffix(".incomplete") }
        }

        /// Truncates all blobs and removes all snapshot symlinks for a file.
        /// This simulates an interrupted Xet download: the blob is partially
        /// written but no snapshot symlink was created.
        private func corruptBlobsAndRemoveSymlinks(
            cache: HubCache,
            repo: Repo.ID,
            filename: String
        ) throws {
            let blobsDir = cache.blobsDirectory(repo: repo, kind: .model)
            let blobs = try findBlobs(in: blobsDir)
            for blob in blobs {
                let blobPath = blobsDir.appendingPathComponent(blob)
                try Data(repeating: 0, count: 5).write(to: blobPath)
            }

            let snapshotsDir = cache.snapshotsDirectory(repo: repo, kind: .model)
            if let commits = try? FileManager.default.contentsOfDirectory(
                atPath: snapshotsDir.path
            ) {
                for commitDir in commits {
                    let symlink =
                        snapshotsDir
                        .appendingPathComponent(commitDir)
                        .appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: symlink)
                }
            }
        }

        // MARK: - downloadFile: Corrupted Blob Recovery

        @Test("downloadFile re-downloads when blob is truncated and entry size is known")
        func downloadFileRecoversFromCorruptedBlob() async throws {
            let repoID: Repo.ID = "google-t5/t5-base"
            let filename = "config.json"
            let (client, cache) = createClient()

            // Get file size from the API (simulates what downloadSnapshot does)
            let model = try await client.getModel(repoID, filesMetadata: true)
            let sibling = try #require(
                model.siblings?.first { $0.relativeFilename == filename }
            )
            let fileSize = try #require(sibling.size)
            let entry = Git.TreeEntry(
                path: filename,
                type: .file,
                oid: nil,
                size: fileSize,
                lastCommit: nil
            )

            // Download to populate cache using the entry-based overload
            let cachedPath = try await client.downloadFile(entry, from: repoID)
            let correctContent = try Data(contentsOf: cachedPath)
            #expect(correctContent.count > 10)

            // Simulate interrupted download: truncate blob, remove symlink
            try corruptBlobsAndRemoveSymlinks(
                cache: cache,
                repo: repoID,
                filename: filename
            )

            // Re-download with known entry size — should detect size mismatch
            let recoveredPath = try await client.downloadFile(entry, from: repoID)
            let recoveredContent = try Data(contentsOf: recoveredPath)

            #expect(
                recoveredContent == correctContent,
                "Recovered file should match original content"
            )
        }

        // MARK: - downloadSnapshot: Corrupted Blob Recovery

        @Test("downloadSnapshot re-downloads when blob is truncated")
        func downloadSnapshotRecoversFromCorruptedBlob() async throws {
            let repoID: Repo.ID = "google-t5/t5-base"
            let (client, cache) = createClient()

            // Download to populate cache
            let snapshotPath = try await client.downloadSnapshot(
                of: repoID,
                matching: ["config.json"]
            )
            let configPath = snapshotPath.appendingPathComponent("config.json")
            let correctContent = try Data(contentsOf: configPath)
            #expect(correctContent.count > 10)

            // Simulate interrupted Xet download: truncate blob, remove symlink
            try corruptBlobsAndRemoveSymlinks(
                cache: cache,
                repo: repoID,
                filename: "config.json"
            )

            // Re-download — should detect size mismatch and re-download
            let recoveredSnapshot = try await client.downloadSnapshot(
                of: repoID,
                matching: ["config.json"]
            )
            let recoveredConfig = recoveredSnapshot.appendingPathComponent("config.json")
            let recoveredContent = try Data(contentsOf: recoveredConfig)

            #expect(
                recoveredContent == correctContent,
                "Recovered file should match original content"
            )
        }

        // MARK: - Snapshot Fast Path: Size Mismatch Detection

        @Test("Commit hash fast path detects truncated blob")
        func commitHashFastPathDetectsTruncatedBlob() async throws {
            let repoID: Repo.ID = "google-t5/t5-base"
            let (client, cache) = createClient()

            // Get commit hash
            let model = try await client.getModel(repoID)
            let commitHash = try #require(model.sha)

            // Download with commit hash to populate cache + repo info metadata
            let snapshotPath = try await client.downloadSnapshot(
                of: repoID,
                revision: commitHash,
                matching: ["config.json"]
            )
            let configPath = snapshotPath.appendingPathComponent("config.json")
            let correctSize = try #require(
                FileManager.default.attributesOfItem(
                    atPath: configPath.path
                )[.size] as? Int
            )
            #expect(correctSize > 10)

            // Truncate the blob (symlink still points to it)
            let blobsDir = cache.blobsDirectory(repo: repoID, kind: .model)
            let blobs = try findBlobs(in: blobsDir)
            for blob in blobs {
                let blobPath = blobsDir.appendingPathComponent(blob)
                try Data(repeating: 0, count: 5).write(to: blobPath)
            }

            // Re-download with same commit hash — verifiedSnapshotPath should
            // detect the size mismatch and fall through to the network path
            let recoveredSnapshot = try await client.downloadSnapshot(
                of: repoID,
                revision: commitHash,
                matching: ["config.json"]
            )
            let recoveredConfig = recoveredSnapshot.appendingPathComponent("config.json")
            let recoveredSize = try #require(
                FileManager.default.attributesOfItem(
                    atPath: recoveredConfig.path
                )[.size] as? Int
            )

            #expect(
                recoveredSize == correctSize,
                "File size should be restored after re-download"
            )
        }

        // MARK: - resolveCachedSnapshot: Size Mismatch Returns Nil

        @Test("resolveCachedSnapshot returns nil when blob is truncated")
        func resolveCachedSnapshotReturnsNilForTruncatedBlob() async throws {
            let repoID: Repo.ID = "google-t5/t5-base"
            let (client, cache) = createClient()

            let model = try await client.getModel(repoID)
            let commitHash = try #require(model.sha)

            // Download to populate cache and repo info metadata
            let snapshotPath = try await client.downloadSnapshot(
                of: repoID,
                revision: commitHash,
                matching: ["config.json"]
            )

            // Verify the file was actually downloaded
            let configPath = snapshotPath.appendingPathComponent("config.json")
            #expect(
                FileManager.default.fileExists(atPath: configPath.path),
                "config.json should exist in snapshot"
            )

            // Verify cache hit before corruption
            let beforePath = client.resolveCachedSnapshot(
                repo: repoID,
                revision: commitHash,
                matching: ["config.json"]
            )
            #expect(beforePath != nil, "Should have a cache hit before corruption")

            // Truncate the blob (but keep the snapshot symlink)
            let blobsDir = cache.blobsDirectory(repo: repoID, kind: .model)
            let blobs = try findBlobs(in: blobsDir)
            #expect(!blobs.isEmpty, "Should have blobs after download")
            for blob in blobs {
                let blobPath = blobsDir.appendingPathComponent(blob)
                try Data(repeating: 0, count: 5).write(to: blobPath)
            }

            // resolveCachedSnapshot should now return nil (size mismatch)
            let afterPath = client.resolveCachedSnapshot(
                repo: repoID,
                revision: commitHash,
                matching: ["config.json"]
            )
            #expect(
                afterPath == nil,
                "Should return nil after blob corruption (size mismatch)"
            )
        }
    }
#endif
