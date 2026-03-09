import Foundation
import BenchmarkHelpers
import HFAPI
import Testing

private let benchmarksEnabled = ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] == "1"

@Suite(.serialized, .enabled(if: benchmarksEnabled))
struct Benchmarks {
    private static let freshDownloadCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appending(component: "huggingface-benchmarks")
    }()

    private func createFreshDownloadClient() -> HubClient {
        let cache = HubCache(cacheDirectory: Self.freshDownloadCacheDirectory)
        return HubClient(
            host: URL(string: "https://huggingface.co")!,
            cache: cache
        )
    }

    @Test func freshDownload() async throws {
        let repoID: Repo.ID = "mlx-community/Qwen3-0.6B-Base-DQ5"
        let runs = BenchmarkDefaults.downloadRuns
        var times: [Double] = []

        for i in 1 ... runs {
            try? FileManager.default.removeItem(at: Self.freshDownloadCacheDirectory)
            let client = createFreshDownloadClient()

            let start = CFAbsoluteTimeGetCurrent()
            _ = try await client.downloadSnapshot(
                of: repoID,
                matching: ["*.json"]
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
            print("Fresh download run \(i): \(String(format: "%.1f", elapsed))ms")
        }

        BenchmarkStats(times: times).printSummary(label: "Fresh download (swift-hf-api)")
    }

    @Test func downloadCacheHit() async throws {
        let stats = try await benchmarkDownloadCacheHit(
            from: HubClient.default
        )
        stats.printSummary(label: "Download cache hit (swift-hf-api)")
    }

    @Test func loadLLM() async throws {
        let stats = try await benchmarkLLMLoading(
            from: HubClient.default,
            using: NoOpTokenizerLoader()
        )
        stats.printSummary(label: "LLM load (swift-hf-api, no-op tokenizer)")
    }

    @Test func loadVLM() async throws {
        let stats = try await benchmarkVLMLoading(
            from: HubClient.default,
            using: NoOpTokenizerLoader()
        )
        stats.printSummary(label: "VLM load (swift-hf-api, no-op tokenizer)")
    }

    @Test func loadEmbedding() async throws {
        let stats = try await benchmarkEmbeddingLoading(
            from: HubClient.default,
            using: NoOpTokenizerLoader()
        )
        stats.printSummary(label: "Embedding load (swift-hf-api, no-op tokenizer)")
    }
}
