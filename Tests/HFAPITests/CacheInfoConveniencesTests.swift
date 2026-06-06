// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

@Suite("CacheInfo conveniences – local")
struct CacheInfoConveniencesTests {
    @Test("cachedRepos(ofType:) filters by RepoType")
    func filtersRepoByType() async throws {
        let (client, cacheDir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        try seedRepoDir(in: cacheDir, name: "models--openai-community--gpt2")
        try seedRepoDir(in: cacheDir, name: "models--mlx-community--Qwen2-1.5B")
        try seedRepoDir(in: cacheDir, name: "datasets--squad--main")

        let info = try await client.scanCache()

        let models = info.cachedRepos(ofType: .model)
        let datasets = info.cachedRepos(ofType: .dataset)
        #expect(models.count == 2)
        #expect(datasets.count == 1)
        #expect(Set(models.map(\.repoID)) == Set(["openai-community/gpt2", "mlx-community/Qwen2-1.5B"]))
        #expect(datasets.first?.repoID == "squad/main")
    }

    @Test("cachedRepo(_:type:) finds a repo by RepositoryID + type")
    func findsByID() async throws {
        let (client, cacheDir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        try seedRepoDir(in: cacheDir, name: "models--openai-community--gpt2")
        try seedRepoDir(in: cacheDir, name: "datasets--openai-community--gpt2")

        let info = try await client.scanCache()
        let id = try RepositoryID(owner: "openai-community", name: "gpt2")

        let model = info.cachedRepo(id, type: .model)
        let dataset = info.cachedRepo(id, type: .dataset)
        #expect(model?.type == .model)
        #expect(dataset?.type == .dataset)
        #expect(model?.repoID == "openai-community/gpt2")
        #expect(dataset?.repoID == "openai-community/gpt2")
    }

    @Test("cachedRepo(_:type:) returns nil for an uncached repo")
    func nilForUncached() async throws {
        let (client, cacheDir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        try seedRepoDir(in: cacheDir, name: "models--owner--cached")

        let info = try await client.scanCache()
        let absent = try RepositoryID(owner: "owner", name: "missing")

        #expect(info.cachedRepo(absent, type: .model) == nil)
    }
}

private func makeIsolatedCache() -> (HFClient, URL) {
    let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-test-\(UUID().uuidString)")
    let client = try! HFClient(cacheDirectory: cacheDir)
    return (client, cacheDir)
}

/// Seed a minimal valid repo folder. The walker recognizes the directory
/// even without `refs/`/`snapshots/`/`blobs/` (see
/// `CacheScanTests.malformedRepoYieldsEmptyEntry`), surfacing it as a
/// zero-revision entry – enough for the convenience methods to find it.
private func seedRepoDir(in cacheDir: URL, name: String) throws {
    let dir = cacheDir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
