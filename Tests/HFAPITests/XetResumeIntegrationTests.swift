// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Uses hf-hub's local CAS fixture and an isolated cache; no live Hub or account is involved.
@Suite(
    "Cached Xet resume through Rust FFI",
    .enabled(if: ProcessInfo.processInfo.environment["HF_RESUME_FIXTURE"] != nil)
)
struct XetResumeIntegrationTests {
    private struct Fixture: Decodable {
        let endpoint: String
        let cacheDirectory: String
        let expectedFile: String
        let retainedBytes: UInt64
        let totalBytes: UInt64
    }

    @Test("The first snapshot progress includes retained bytes and the output is complete")
    func resumedSnapshot() async throws {
        let descriptor = try #require(ProcessInfo.processInfo.environment["HF_RESUME_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: descriptor)))
        try #require(URL(string: fixture.endpoint)?.host == "127.0.0.1")
        let client = try HFClient(
            endpoint: fixture.endpoint,
            auth: .token("fixture-only"),
            cacheDirectory: URL(fileURLWithPath: fixture.cacheDirectory)
        )
        let (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        defer { continuation.finish() }
        let directory = try await withTestTimeout(seconds: 30) {
            try await client.model(owner: "fixture", name: "resume").snapshotDownload(
                progress: { continuation.yield($0) }
            )
        }
        continuation.finish()
        var state = DownloadProgressState()
        var initialFraction: Double?
        for await event in events {
            state.observe(event)
            if case .progress = event, initialFraction == nil {
                initialFraction = state.fractionCompleted
            }
        }
        #expect(state.totalBytes == fixture.totalBytes)
        let initial = try #require(initialFraction)
        #expect(abs(initial - Double(fixture.retainedBytes) / Double(fixture.totalBytes)) < 1e-12)
        #expect(state.isComplete)
        #expect(state.fractionCompleted == 1)
        let expected = try Data(contentsOf: URL(fileURLWithPath: fixture.expectedFile))
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == expected)
        #expect(try Data(contentsOf: directory.appendingPathComponent("alias.bin")) == expected)
    }
}
