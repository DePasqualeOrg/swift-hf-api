// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Live-Hub download tests. Each test downloads `config.json` from
/// `openai-community/gpt2` (a tiny ~700 byte file) into an isolated cache
/// directory so concurrent test runs don't fight over the same blob.
@Suite("HFClient downloadFile – live Hub", .enabled(if: integrationTestsEnabled))
struct ClientDownloadTests {
    @Test("downloadFile returns an on-disk path that exists")
    func downloadFileReturnsPath() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        guard
            let url = try await fetchOrSkip({
                try await model.downloadFile("config.json")
            })
        else { return }

        #expect(FileManager.default.fileExists(atPath: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        #expect(size > 0)
    }

    @Test("downloadFile invokes progress callback")
    func downloadFileProgressCallback() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        let events = ProgressCollector()
        let url: URL?
        do {
            url = try await model.downloadFile(
                "config.json",
                forceDownload: true,
                progress: { event in
                    events.append(event)
                }
            )
        } catch let error as HFError where error.isTransient {
            return
        }

        guard let url else { return }
        #expect(FileManager.default.fileExists(atPath: url.path))

        // We expect at minimum a `start` and a `complete` event for any
        // download that traversed the network. Cache hits short-circuit, but
        // `forceDownload: true` guarantees we cross the wire.
        let collected = events.snapshot()
        let kinds = collected.map { eventKind($0) }
        #expect(kinds.contains("start"))
        #expect(kinds.contains("complete"))
    }

    @Test("downloadFileStream emits events and resolves the URL")
    func downloadFileStreamRunsToCompletion() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        let stream = model.downloadFileStream("config.json", forceDownload: true)

        var events: [DownloadEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
        } catch let error as HFError where error.isTransient {
            return
        }

        let url: URL
        do {
            url = try await stream.value
        } catch let error as HFError where error.isTransient {
            return
        }

        #expect(FileManager.default.fileExists(atPath: url.path))
        let kinds = events.map { eventKind($0) }
        #expect(kinds.contains("start"))
        #expect(kinds.contains("complete"))
    }

    @Test("cancelled download then resumed download produces a valid file with no .incomplete residue")
    func cancelledDownloadResumesCleanly() async throws {
        let (client, cacheDir) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Start a large download and cancel after the first progress event.
        // `model.safetensors` is hundreds of MB on gpt2 – we will not let it
        // complete, but the partial bytes (if any) populate the
        // `.incomplete` temp file that the upstream cache writer uses.
        let firstStream = model.downloadFileStream(
            "model.safetensors",
            forceDownload: true
        )
        var firstIterator = firstStream.makeAsyncIterator()
        do {
            _ = try await firstIterator.next()
        } catch let error as HFError where error.isTransient {
            return
        }
        firstStream.cancel()
        do {
            _ = try await withTestTimeout(seconds: 30) { try await firstStream.value }
            Issue.record("expected the cancelled download to surface .cancelled, but it succeeded")
            return
        } catch HFError.cancelled {
            // Expected.
        } catch is TestTimeoutError {
            Issue.record("download did not surface .cancelled within 30s")
            return
        } catch let error as HFError where error.isTransient {
            return
        }

        // Resume by downloading a *different* small file from the same repo.
        // A full retry of `model.safetensors` would take minutes; what we
        // need is to prove the cache is still healthy after the cancel and
        // that no `.incomplete` residue blocks subsequent downloads. The
        // upstream cleanup fix (hf-hub PR #15) is what this exercises.
        let url: URL?
        do {
            url = try await model.downloadFile("config.json")
        } catch let error as HFError where error.isTransient {
            return
        }
        guard let url else { return }
        #expect(FileManager.default.fileExists(atPath: url.path))

        // No `.incomplete` files should linger anywhere under the cache
        // directory. The cancel handler in the Rust crate's
        // `stream_response_to_file_with_progress` path now removes the
        // temp file on early termination – this assertion locks that
        // contract from the Swift side.
        let enumerator = FileManager.default.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: nil
        )
        var stragglers: [String] = []
        while let next = enumerator?.nextObject() as? URL {
            if next.lastPathComponent.hasSuffix(".incomplete") {
                stragglers.append(next.path)
            }
        }
        #expect(
            stragglers.isEmpty,
            "expected no `.incomplete` residue after a cancelled-then-resumed download; found: \(stragglers)"
        )
    }

    @Test("downloadFile resumes from an existing .incomplete file")
    func downloadFileResumesFromPartial() async throws {
        // Ground-truth pass: download config.json to cache_a, capture the
        // full bytes and the cache-relative blob path. The .incomplete
        // sibling of that path is what the resume code reads on the next
        // attempt, so mirroring the layout under a fresh cache lets us
        // pre-populate a partial without leaking implementation details.
        let (clientA, cacheA) = try makeIsolatedClient()
        let modelA = clientA.model(owner: "openai-community", name: "gpt2")

        let snapshotA: URL?
        do {
            snapshotA = try await modelA.downloadFile("config.json")
        } catch let error as HFError where error.isTransient {
            return
        }
        guard let snapshotA else { return }

        let blobA = resolveCanonical(snapshotA)
        let fullBytes = try Data(contentsOf: blobA)
        #expect(fullBytes.count > 32, "fixture too small to split meaningfully")

        // Pre-populate a fresh cache's .incomplete with the *correct* first
        // half of the file. A working resume implementation sends
        // `Range: bytes=N-` and only fetches the remaining bytes; a broken
        // one would truncate-and-restart, leaving no signal beyond byte
        // equality (which both shapes satisfy if the network completes).
        let (clientB, cacheB) = try makeIsolatedClient()
        let modelB = clientB.model(owner: "openai-community", name: "gpt2")

        let blobB = try rebaseCanonical(blobA, from: cacheA, to: cacheB)
        let incompleteB = URL(fileURLWithPath: blobB.path + ".incomplete")
        try FileManager.default.createDirectory(
            at: incompleteB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partialSize = fullBytes.count / 2
        try fullBytes.prefix(partialSize).write(to: incompleteB)

        let events = ProgressCollector()
        let resumed: URL?
        do {
            resumed = try await modelB.downloadFile(
                "config.json",
                progress: { events.append($0) }
            )
        } catch let error as HFError where error.isTransient {
            return
        }
        guard let resumed else { return }

        // Correctness: the final blob must byte-equal the canonical content.
        let resumedBytes = try Data(contentsOf: resumed)
        #expect(
            resumedBytes == fullBytes,
            "resumed download must produce byte-identical content to a clean download"
        )

        // Resume actually fired: the first .started progress entry reports
        // the resume offset (= partialSize), not 0. A truncate-and-restart
        // implementation would report bytesCompleted: 0 here.
        let firstStartedOffset = events.snapshot().compactMap { event -> UInt64? in
            guard case .progress(let files) = event else { return nil }
            return files.first(where: { $0.status == .started })?.bytesCompleted
        }.first

        #expect(
            firstStartedOffset == UInt64(partialSize),
            "first .started event should report the resume offset; got \(firstStartedOffset.map(String.init) ?? "nil"), expected \(partialSize)"
        )
    }

    @Test("Task.cancel() on a non-streaming snapshotDownload surfaces .cancelled")
    func taskCancelPropagatesToSnapshotDownload() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Run the snapshotDownload inside a child Task so we can hit it
        // with `Task.cancel()` from the outside. snapshotDownload pulls
        // the full repo (~500MB of safetensors) – plenty of headroom to
        // cancel before completion. The non-streaming path is wrapped by
        // `withCancellableHFOperation`, which registers a
        // `withTaskCancellationHandler { } onCancel: { handle.cancel() }`;
        // this test guards that wiring against a regression to no-op.
        let downloadTask = Task { () -> URL in
            try await model.snapshotDownload(forceDownload: true)
        }

        // Give the Rust side a beat to actually start the download
        // before cancelling – `withCancellableHFOperation` registers the
        // cancellation handler synchronously, but the FFI future has to
        // be entered for the cancellation token to be observed.
        try? await Task.sleep(for: .milliseconds(500))

        downloadTask.cancel()

        do {
            let url = try await withTestTimeout(seconds: 30) {
                try await downloadTask.value
            }
            Issue.record(
                """
                expected `.cancelled` after Task.cancel() but snapshotDownload \
                finished at \(url.path); cancellation likely not wiring through \
                to the Rust future
                """
            )
        } catch HFError.cancelled {
            // Expected – `Task.cancel()` → `withTaskCancellationHandler`
            // → `handle.cancel()` → tokio `select!` arm.
        } catch is TestTimeoutError {
            Issue.record(
                "snapshotDownload neither completed nor surfaced `.cancelled` within 30s – task cancellation appears stuck"
            )
        } catch let error as HFError where error.isTransient {
            return
        } catch {
            Issue.record("unexpected error after Task.cancel(): \(error)")
        }
    }

    @Test("stream.cancel() aborts the in-flight download")
    func cancelAbortsInflightDownload() async throws {
        let (client, _) = try makeIsolatedClient()
        let model = client.model(owner: "openai-community", name: "gpt2")

        // Use a known-large file (gpt2's safetensors is ~500MB) so the
        // download cannot complete before we issue cancel(). Smaller
        // files (e.g., `tokenizer.json`, ~1MB) finish in <100ms on fast
        // links, letting the result `Task` resolve successfully and
        // masking a broken cancellation path.
        let stream = model.downloadFileStream(
            "model.safetensors",
            forceDownload: true
        )

        // Wait for the first progress event to confirm the download
        // started. Iterating once via the iterator API (rather than a
        // `for try await` loop) avoids relying on `onTermination` firing
        // on iterator drop – which is best-effort for long downloads
        // because the producer must `yield()` again before the dropped
        // consumer is detected.
        var iterator = stream.makeAsyncIterator()
        do {
            let _ = try await iterator.next()
        } catch let error as HFError where error.isTransient {
            return
        }

        // Explicit cancellation – the documented contract for stopping
        // an in-flight stream. The Rust `tokio::select!` arm flips on
        // the cancellation token's signal and aborts the download
        // future via `HFErrorFFI::Cancelled`.
        stream.cancel()
        #expect(stream.isCancelled)

        // After the cancel the transferred bytes are bounded by the few
        // MB that streamed before our iterator's first `next()`. The
        // result task must surface `.cancelled` – if it returns a URL,
        // either the network is implausibly fast or cancellation isn't
        // wired through to the Rust download future. Either case is
        // worth investigating, so make the failure noisy. The 30s
        // ceiling guards against a hung future when cancellation
        // regresses to a no-op.
        do {
            let url = try await withTestTimeout(seconds: 30) {
                try await stream.value
            }
            Issue.record(
                """
                expected `.cancelled` but the 500MB download finished at \
                \(url.path); cancellation likely not wiring through to the \
                Rust future
                """
            )
        } catch HFError.cancelled {
            // Expected – the cancellation token won the select! arm.
        } catch is TestTimeoutError {
            Issue.record(
                "download neither completed nor surfaced `.cancelled` within 30s – cancellation appears stuck"
            )
        } catch let error as HFError where error.isTransient {
            return
        } catch {
            Issue.record("unexpected error after stream cancel: \(error)")
        }
    }
}

/// Live-Hub coverage for the dataset download path. The model side is
/// covered above; this suite exercises the same four download flavors
/// against a public dataset (`nyu-mll/glue`) to confirm the kind-uniform
/// dispatch in `RepositoryProtocol` actually reaches the dataset
/// branch on the Rust side.
@Suite("DatasetRepository download – live Hub", .enabled(if: integrationTestsEnabled))
struct DatasetDownloadTests {
    @Test("downloadFile on a dataset returns an on-disk path that exists")
    func datasetDownloadFileReturnsPath() async throws {
        let (client, _) = try makeIsolatedClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard
            let url = try await fetchOrSkip({
                try await dataset.downloadFile("README.md")
            })
        else { return }

        #expect(FileManager.default.fileExists(atPath: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        #expect(size > 0)
    }

    @Test("downloadFileToBytes on a dataset returns the file contents")
    func datasetDownloadFileToBytes() async throws {
        let (client, _) = try makeIsolatedClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        guard
            let bytes = try await fetchOrSkip({
                try await dataset.downloadFileToBytes("README.md")
            })
        else { return }

        #expect(!bytes.isEmpty)
    }

    @Test("downloadFileStream on a dataset emits events and resolves the URL")
    func datasetDownloadFileStream() async throws {
        let (client, _) = try makeIsolatedClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        let stream = dataset.downloadFileStream("README.md", forceDownload: true)

        var sawStart = false
        var sawComplete = false
        do {
            for try await event in stream {
                switch event {
                case .start: sawStart = true
                case .complete: sawComplete = true
                default: break
                }
            }
        } catch let error as HFError where error.isTransient {
            return
        }

        let url: URL
        do {
            url = try await stream.value
        } catch let error as HFError where error.isTransient {
            return
        }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(sawStart)
        #expect(sawComplete)
    }

    @Test("downloadFileBytesStream on a dataset reassembles into the file")
    func datasetDownloadFileBytesStream() async throws {
        let (client, _) = try makeIsolatedClient()
        let dataset = client.dataset(owner: "nyu-mll", name: "glue")

        let stream = dataset.downloadFileBytesStream("README.md")

        var buffer = Data()
        do {
            for try await chunk in stream {
                buffer.append(chunk)
            }
        } catch let error as HFError where error.isTransient {
            return
        }

        _ = await stream.contentLength
        #expect(!buffer.isEmpty)
    }
}

/// Marker error thrown by [`withTestTimeout`] when an operation outruns
/// its deadline. Tests catch this case explicitly to distinguish "still
/// running after N seconds" from a normal completion or `HFError`.
struct TestTimeoutError: Error, Sendable {}

/// Race `operation` against a sleep – if the sleep wins, throw
/// [`TestTimeoutError`] and cancel the operation. Used to guard tests
/// that would otherwise block indefinitely if a cancellation regression
/// stops the underlying future from terminating.
func withTestTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func makeIsolatedClient() throws -> (HFClient, URL) {
    let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hf-test-\(UUID().uuidString)")
    let client = try HFClient(cacheDirectory: cacheDir)
    return (client, cacheDir)
}

/// Resolve a snapshot symlink down to the on-disk blob it points at,
/// resolving every intermediate symlink. Required because tests on macOS
/// see `/var/folders/...` from `temporaryDirectory` but the blob lives
/// behind a `/private/var/...` canonical resolution.
private func resolveCanonical(_ url: URL) -> URL {
    let resolved = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
    let canonical = (resolved.path as NSString).resolvingSymlinksInPath
    return URL(fileURLWithPath: canonical)
}

/// Given a canonical blob path under `sourceCache`, compute the equivalent
/// path under `destCache`. Both caches share the layout (same repo, same
/// etag) for any two clients hitting the same file on the same Hub.
private func rebaseCanonical(_ canonical: URL, from sourceCache: URL, to destCache: URL) throws -> URL {
    let sourceCanonical = URL(fileURLWithPath: (sourceCache.path as NSString).resolvingSymlinksInPath)
    guard canonical.path.hasPrefix(sourceCanonical.path + "/") else {
        throw NSError(
            domain: "DownloadTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "canonical path \(canonical.path) is not under \(sourceCanonical.path)"
            ]
        )
    }
    let relative = String(canonical.path.dropFirst(sourceCanonical.path.count + 1))
    return destCache.appendingPathComponent(relative)
}

private func eventKind(_ event: DownloadEvent) -> String {
    switch event {
    case .start: return "start"
    case .progress: return "progress"
    case .aggregateProgress: return "aggregateProgress"
    case .complete: return "complete"
    }
}

/// Thread-safe accumulator for progress events. The FFI fires events on tokio
/// worker threads.
private final class ProgressCollector: @unchecked Sendable {
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
