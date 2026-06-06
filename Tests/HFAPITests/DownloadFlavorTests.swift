// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub coverage for the Phase 3g download flavors:
/// `downloadFileToBytes`, `downloadFileBytesStream`, and
/// `snapshotDownload`. Each test uses an isolated cache directory so it
/// doesn't pollute or depend on the user's real cache.

@Suite("ModelRepository.downloadFileToBytes – live Hub", .enabled(if: integrationTestsEnabled))
struct DownloadToBytesTests {
    @Test("downloadFileToBytes returns the file contents")
    func gpt2ConfigBytes() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let bytes = try await fetchOrSkip({
                try await model.downloadFileToBytes("config.json")
            })
        else { return }

        #expect(!bytes.isEmpty)
        // gpt2/config.json is JSON; verify it parses.
        let parsed = try JSONSerialization.jsonObject(with: bytes)
        #expect(parsed is [String: Any])
    }
}

@Suite("ModelRepository.downloadFileBytesStream – live Hub", .enabled(if: integrationTestsEnabled))
struct DownloadBytesStreamTests {
    @Test("downloadFileBytesStream emits chunks that reassemble into the file")
    func gpt2ConfigChunks() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        let stream = model.downloadFileBytesStream("config.json")

        var buffer = Data()
        do {
            for try await chunk in stream {
                buffer.append(chunk)
            }
        } catch let error as HFError where error.isTransient {
            return
        }

        let total = await stream.contentLength

        #expect(buffer.count > 0)
        // The Hub may or may not send Content-Length depending on
        // transfer encoding. When it does, it should match the bytes we
        // received; when it doesn't, the result is nil.
        if let total {
            #expect(UInt64(buffer.count) == total)
        }

        // Verify the reassembled bytes parse as JSON.
        let parsed = try JSONSerialization.jsonObject(with: buffer)
        #expect(parsed is [String: Any])
    }
}

@Suite("ModelRepository.snapshotDownload – live Hub", .enabled(if: integrationTestsEnabled))
struct SnapshotDownloadTests {
    @Test("snapshotDownload(allowPatterns: [config.json]) returns a directory containing only config.json")
    func gpt2ConfigSnapshot() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let snapshotURL = try await fetchOrSkip({
                try await model.snapshotDownload(allowPatterns: ["config.json"])
            })
        else { return }

        // The snapshot directory should exist.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: snapshotURL.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)

        // config.json should be inside the snapshot directory.
        let configURL = snapshotURL.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("snapshotDownload with a non-matching pattern returns an empty snapshot dir")
    func noMatch() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Upstream `snapshot_download` resolves the revision, filters
        // the file list, and returns the snapshot directory path even
        // when zero files match – the call is not an error per se.
        // Verify the call succeeds and the directory contains no
        // matched files. (The hub may not bother creating it if zero
        // files would be downloaded.)
        guard
            let url = try await fetchOrSkip({
                try await model.snapshotDownload(
                    allowPatterns: ["this-pattern-matches-nothing-\(UUID().uuidString).bin"]
                )
            })
        else { return }

        // The snapshot dir should either not exist (Hub didn't bother
        // creating it for zero matches) or exist with no downloaded files.
        // Locking down both cases catches a regression that returned the
        // full snapshot.
        let configURL = url.appendingPathComponent("config.json")
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            let nonDotFiles = contents.filter { !$0.hasPrefix(".") }
            #expect(nonDotFiles.isEmpty, "expected empty snapshot dir, got: \(nonDotFiles)")
        }
    }

    @Test("snapshotDownload(localDir:) installs the snapshot at the supplied path")
    func snapshotIntoLocalDir() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-test-localdir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localDir) }

        guard
            let url = try await fetchOrSkip({
                try await model.snapshotDownload(
                    allowPatterns: ["config.json"],
                    localDir: localDir
                )
            })
        else { return }

        // The returned URL must live under the supplied localDir – not
        // inside the cache. Comparing the standardized paths is the
        // robust check (symlink targets vs the literal path argument).
        #expect(url.standardizedFileURL.path.hasPrefix(localDir.standardizedFileURL.path))
        let configURL = url.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("snapshotDownload(ignorePatterns:) skips matched files")
    func snapshotIgnorePatterns() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Pull only `*.json` and then exclude `tokenizer.json`. The Hub
        // root has both `config.json` and `tokenizer.json`, so the
        // result must contain config.json but not tokenizer.json.
        guard
            let url = try await fetchOrSkip({
                try await model.snapshotDownload(
                    allowPatterns: ["*.json"],
                    ignorePatterns: ["tokenizer.json"]
                )
            })
        else { return }

        let configURL = url.appendingPathComponent("config.json")
        let tokenizerURL = url.appendingPathComponent("tokenizer.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))
        #expect(!FileManager.default.fileExists(atPath: tokenizerURL.path))
    }

    @Test("resolveCachedSnapshot returns nil on an empty cache")
    func resolveCachedSnapshotEmptyCache() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Empty cache + no network call: must return nil rather than
        // throw. The pre-migration API had this no-throw contract; callers
        // depend on it to gate UI on "model present locally?" without
        // try/catch.
        let resolved = try await model.resolveCachedSnapshot(
            allowPatterns: ["config.json"]
        )
        #expect(resolved == nil)
    }

    @Test("resolveCachedSnapshot returns the snapshot URL after a download")
    func resolveCachedSnapshotAfterDownload() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let downloaded = try await fetchOrSkip({
                try await model.snapshotDownload(allowPatterns: ["config.json"])
            })
        else { return }

        // Second call without `networkAccess: .bypass` would also succeed,
        // but resolveCachedSnapshot proves the cache-only path returns
        // the same URL – verifying the pre-migration ergonomic still
        // works.
        let resolved = try await model.resolveCachedSnapshot(
            allowPatterns: ["config.json"]
        )
        let url = try #require(resolved, "expected cached snapshot to resolve")
        #expect(url.standardizedFileURL == downloaded.standardizedFileURL)
        let configURL = url.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("snapshotDownload(networkAccess: .bypass) on an empty cache throws")
    func snapshotOfflineEmptyCache() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Forcing offline against a fresh cache directory must fail —
        // there's nothing local to resolve from. Verify the error
        // surfaces as one of the documented offline variants rather
        // than silently going to the network.
        do {
            _ = try await model.snapshotDownload(
                allowPatterns: ["config.json"],
                networkAccess: .bypass
            )
            Issue.record("expected snapshotDownload(networkAccess: .bypass) on empty cache to throw")
        } catch HFError.localEntryNotFound, HFError.cacheNotEnabled, HFError.entryNotFound {
            // expected – cache miss in offline mode
        } catch let error as HFError where error.isTransient {
            return
        } catch {
            Issue.record("unexpected error variant: \(error)")
        }
    }

    @Test("snapshotDownload emits at least one progress event")
    func snapshotProgressEvents() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        let received = SnapshotEventCollector()
        do {
            _ = try await model.snapshotDownload(
                allowPatterns: ["config.json"],
                forceDownload: true,
                progress: { event in received.append(event) }
            )
        } catch let error as HFError where error.isTransient {
            return
        }

        let kinds = received.snapshot().map(eventKind)
        // A forced snapshot of a real file goes through the network and
        // must emit at least one progress-shaped event. Don't assert a
        // specific kind beyond "non-empty" – the upstream may bundle
        // start/complete with aggregateProgress in either order.
        #expect(!kinds.isEmpty)
    }
}

private func eventKind(_ event: DownloadEvent) -> String {
    switch event {
    case .start: return "start"
    case .progress: return "progress"
    case .aggregateProgress: return "aggregateProgress"
    case .complete: return "complete"
    }
}

/// Thread-safe accumulator for snapshot download progress events. The
/// FFI fires events on tokio worker threads.
private final class SnapshotEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadEvent] = []

    func append(_ event: DownloadEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [DownloadEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private func makeIsolatedClient() throws -> (HFClient, URL) {
    let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-test-\(UUID().uuidString)")
    let client = try HFClient(cacheDirectory: cacheDir)
    return (client, cacheDir)
}
