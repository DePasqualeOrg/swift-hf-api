// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Crypto
import FileLock
import Foundation

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import Xet

/// Controls which transport is used for file downloads.
public enum FileDownloadTransport: Hashable, CaseIterable, Sendable {
    /// Automatically select the best transport. Xet is used when the server's
    /// HEAD response advertises Xet via `X-Xet-Hash` together with either a
    /// `Link` header containing `rel="xet-auth"` or an `X-Xet-Refresh-Route`
    /// header; otherwise the LFS path is used.
    case automatic

    /// Force classic LFS download.
    case lfs

    /// Force Xet download (requires Xet support).
    case xet

    var shouldAttemptXet: Bool {
        switch self {
        case .automatic, .xet:
            return true
        case .lfs:
            return false
        }
    }
}

/// Controls which endpoint is used for file downloads.
public enum FileDownloadEndpoint: String, Hashable, CaseIterable, Sendable {
    /// Resolve endpoint (default behavior).
    case resolve

    /// Raw endpoint (bypass resolve redirects).
    case raw

    var pathComponent: String { rawValue }
}

// MARK: - Upload Operations

public extension HubClient {
    /// Upload a single file to a repository
    /// - Parameters:
    ///   - filePath: Local file path to upload
    ///   - repoPath: Destination path in repository
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository (model, dataset, or space)
    ///   - branch: Target branch (default: "main")
    ///   - message: Commit message
    /// - Returns: Tuple of (path, commit) where commit may be nil
    func uploadFile(
        _ filePath: String,
        to repoPath: String,
        in repo: Repo.ID,
        kind: Repo.Kind = .model,
        branch: String = "main",
        message: String? = nil
    ) async throws -> (path: String, commit: String?) {
        let fileURL = URL(fileURLWithPath: filePath)
        return try await uploadFile(fileURL, to: repoPath, in: repo, kind: kind, branch: branch, message: message)
    }

    /// Upload a single file to a repository
    /// - Parameters:
    ///   - fileURL: Local file URL to upload
    ///   - path: Destination path in repository
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository (model, dataset, or space)
    ///   - branch: Target branch (default: "main")
    ///   - message: Commit message
    /// - Returns: Tuple of (path, commit) where commit may be nil
    func uploadFile(
        _ fileURL: URL,
        to repoPath: String,
        in repo: Repo.ID,
        kind: Repo.Kind = .model,
        branch: String = "main",
        message: String? = nil
    ) async throws -> (path: String, commit: String?) {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: kind.pluralized)
            .appending(path: repo.namespace)
            .appending(path: repo.name)
            .appending(path: "upload")
            .appending(component: branch)
        var request = try await httpClient.createRequest(.post, url: url)

        let boundary = "----hf-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Determine file size for streaming decision
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let threshold = 10 * 1024 * 1024  // 10MB
        let shouldStream = fileSize >= threshold

        let mimeType = fileURL.mimeType

        if shouldStream {
            // Large file: stream from disk using URLSession.uploadTask
            request.setValue("100-continue", forHTTPHeaderField: "Expect")
            let tempFile = try MultipartBuilder(boundary: boundary)
                .addText(name: "path", value: repoPath)
                .addOptionalText(name: "message", value: message)
                .addFileStreamed(name: "file", fileURL: fileURL, mimeType: mimeType)
                .buildToTempFile()
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let (data, response) = try await session.upload(for: request, fromFile: tempFile)
            _ = try httpClient.validateResponse(response, data: data)

            if data.isEmpty {
                return (path: repoPath, commit: nil)
            }

            let result = try JSONDecoder().decode(UploadResponse.self, from: data)
            return (path: result.path, commit: result.commit)
        } else {
            // Small file: build in memory
            let body = try MultipartBuilder(boundary: boundary)
                .addText(name: "path", value: repoPath)
                .addOptionalText(name: "message", value: message)
                .addFile(name: "file", fileURL: fileURL, mimeType: mimeType)
                .buildInMemory()

            let (data, response) = try await session.upload(for: request, from: body)
            _ = try httpClient.validateResponse(response, data: data)

            if data.isEmpty {
                return (path: repoPath, commit: nil)
            }

            let result = try JSONDecoder().decode(UploadResponse.self, from: data)
            return (path: result.path, commit: result.commit)
        }
    }

    /// Upload multiple files to a repository
    /// - Parameters:
    ///   - batch: Batch of files to upload (path: URL dictionary)
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - branch: Target branch
    ///   - message: Commit message
    ///   - maxConcurrent: Maximum concurrent uploads
    /// - Returns: Array of (path, commit) tuples
    func uploadFiles(
        _ batch: FileBatch,
        to repo: Repo.ID,
        kind: Repo.Kind = .model,
        branch: String = "main",
        message: String,
        maxConcurrent: Int = 3
    ) async throws -> [(path: String, commit: String?)] {
        let entries = Array(batch)

        return try await withThrowingTaskGroup(
            of: (Int, (path: String, commit: String?)).self
        ) { group in
            var results: [(path: String, commit: String?)?] = Array(
                repeating: nil,
                count: entries.count
            )
            var activeCount = 0

            for (index, (path, entry)) in entries.enumerated() {
                // Limit concurrency
                while activeCount >= maxConcurrent {
                    if let (idx, result) = try await group.next() {
                        results[idx] = result
                        activeCount -= 1
                    }
                }

                group.addTask {
                    let result = try await self.uploadFile(
                        entry.url,
                        to: path,
                        in: repo,
                        kind: kind,
                        branch: branch,
                        message: message
                    )
                    return (index, result)
                }
                activeCount += 1
            }

            // Collect remaining results
            for try await (index, result) in group {
                results[index] = result
            }

            return results.compactMap { $0 }
        }
    }
}

// MARK: - Download Operations

/// Constants for download operations.
private enum DownloadConstants {
    /// Interval between speed updates during downloads (250 ms).
    static let speedUpdateIntervalNanoseconds: UInt64 = 250_000_000
}

public extension HubClient {
    /// Download file data using URLSession.dataTask.
    ///
    /// With `transport == .automatic`, the Xet path is attempted whenever the
    /// Hub's HEAD response advertises Xet support; otherwise the LFS path is
    /// used. `transport == .xet` forces the Xet path and propagates errors;
    /// `transport == .lfs` skips Xet entirely.
    /// - Parameters:
    ///   - repoPath: Path to file in repository
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - revision: Git revision (branch, tag, or commit)
    ///   - endpoint: Select resolve or raw endpoint
    ///   - cachePolicy: Cache policy for the request
    /// - Returns: File data
    func downloadContentsOfFile(
        at repoPath: String,
        from repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main",
        endpoint: FileDownloadEndpoint = .resolve,
        transport: FileDownloadTransport = .automatic,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> Data {
        // Check cache first
        if let cachedPath = cache.cachedFilePath(
            repo: repo,
            kind: kind,
            revision: revision,
            filename: repoPath
        ) {
            return try Data(contentsOf: cachedPath)
        }

        if endpoint == .resolve, transport.shouldAttemptXet {
            do {
                if let data = try await downloadDataWithXet(
                    repoPath: repoPath,
                    repo: repo,
                    kind: kind,
                    revision: revision
                ) {
                    return data
                }
            } catch {
                if transport == .xet {
                    throw error
                }
            }
        }

        // Fallback to existing LFS download method
        let url = fileURL(
            repoPath: repoPath,
            repo: repo,
            kind: kind,
            revision: revision,
            endpoint: endpoint
        )

        // Fetch metadata first (without following redirects) to get X-Linked-Etag for LFS/xet files
        let metadata = try await fetchFileMetadata(url: url)

        var request = try await httpClient.createRequest(.get, url: url)
        request.cachePolicy = cachePolicy

        let (data, response) = try await session.data(for: request)
        _ = try httpClient.validateResponse(response, data: data)

        // Store in cache if we have etag and commit info
        let etag = metadata.etag ?? (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        let commitHash =
            metadata.commitHash ?? (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Repo-Commit")

        if let etag, let commitHash {
            try? await cache.storeData(
                data,
                repo: repo,
                kind: kind,
                revision: commitHash,
                filename: repoPath,
                etag: etag,
                ref: revision != commitHash ? revision : nil
            )
        }

        return data
    }

    /// Download a file to the cache with automatic resume support.
    ///
    /// Downloads the file to the blob cache and creates a snapshot symlink.
    /// Returns the snapshot symlink path, which resolves through to the blob.
    /// If the file is already cached, returns immediately with no network calls.
    ///
    /// With `transport == .automatic`, the Xet path is attempted whenever the
    /// Hub's HEAD response advertises Xet support; otherwise the LFS path is
    /// used. `transport == .xet` forces the Xet path and propagates errors;
    /// `transport == .lfs` skips Xet entirely.
    ///
    /// If a previous download was interrupted, this method automatically resumes
    /// from where it left off using HTTP Range headers (LFS) or swift-xet's
    /// byte-range append API (Xet).
    ///
    /// - Parameters:
    ///   - repoPath: Path to file in repository
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - revision: Git revision
    ///   - endpoint: Select resolve or raw endpoint
    ///   - cachePolicy: Cache policy for the request
    ///   - progress: Optional Progress object to track download progress
    ///   - transport: Download transport selection
    /// - Returns: Path to the cached file (snapshot symlink)
    func downloadFile(
        at repoPath: String,
        from repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main",
        to destination: URL? = nil,
        localFilesOnly: Bool = false,
        endpoint: FileDownloadEndpoint = .resolve,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        progress: Progress? = nil,
        transport: FileDownloadTransport = .automatic,
        expectedSize: Int? = nil
    ) async throws -> URL {
        // Check cache first. This avoids a HEAD request when the file is already
        // cached. Python's hf_hub_download has the same early return (existence-only),
        // trusting that the caching logic wrote the blob atomically. We go further
        // by also validating the file size when the caller provides an expected size
        // (e.g., from the API's file list). This self-heals corrupted caches — if a
        // blob was truncated by a bug in an earlier version, the size mismatch causes
        // a cache miss and the file is re-downloaded.
        if let cachedPath = cache.cachedFilePath(
            repo: repo,
            kind: kind,
            revision: revision,
            filename: repoPath
        ) {
            if let expectedSize {
                let resolved = cachedPath.resolvingSymlinksInPath()
                if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                    let actualSize = attrs[.size] as? Int,
                    actualSize != expectedSize
                {
                    // Size mismatch — fall through to re-download
                } else {
                    if let progress {
                        progress.completedUnitCount = progress.totalUnitCount
                    }
                    return try copyToLocalDirectoryIfNeeded(
                        cachedPath,
                        repoPath: repoPath,
                        localDirectory: destination
                    )
                }
            } else {
                if let progress {
                    progress.completedUnitCount = progress.totalUnitCount
                }
                return try copyToLocalDirectoryIfNeeded(
                    cachedPath,
                    repoPath: repoPath,
                    localDirectory: destination
                )
            }
        }

        if localFilesOnly {
            throw HubCacheError.offlineModeError(
                "File '\(repoPath)' not available in cache"
            )
        }

        if endpoint == .resolve, transport.shouldAttemptXet {
            do {
                if let downloaded = try await downloadFileWithXet(
                    repoPath: repoPath,
                    repo: repo,
                    kind: kind,
                    revision: revision,
                    progress: progress,
                    expectedSize: expectedSize
                ) {
                    return try copyToLocalDirectoryIfNeeded(
                        downloaded,
                        repoPath: repoPath,
                        localDirectory: destination
                    )
                }
            } catch {
                if transport == .xet {
                    throw error
                }
            }
        }

        // Fallback to existing LFS download method
        let url = fileURL(
            repoPath: repoPath,
            repo: repo,
            kind: kind,
            revision: revision,
            endpoint: endpoint
        )

        // Fetch metadata first (without following redirects) to get X-Linked-Etag for LFS/xet files
        let metadata = try await fetchFileMetadata(url: url)

        var request = try await httpClient.createRequest(.get, url: url)
        request.cachePolicy = cachePolicy

        // Use shared cache coordination (blob check, locking) for both platforms
        let cachedPath = try await downloadWithCacheCoordination(
            request: request,
            metadata: metadata,
            repo: repo,
            kind: kind,
            revision: revision,
            repoPath: repoPath,
            expectedSize: expectedSize,
            progress: progress
        )
        return try copyToLocalDirectoryIfNeeded(
            cachedPath,
            repoPath: repoPath,
            localDirectory: destination
        )
    }

    /// Downloads a file with cache coordination (blob check, locking) shared across platforms.
    ///
    /// This method handles:
    /// 1. Check if blob already exists → skip download
    /// 2. Acquire file lock to prevent parallel downloads
    /// 3. Platform-specific download (with resume on Apple, without on Linux)
    /// 4. Create snapshot symlink
    ///
    /// Returns the snapshot symlink path, which resolves through to the blob.
    /// Requires a cache to be configured.
    private func downloadWithCacheCoordination(
        request: URLRequest,
        metadata: FileMetadata?,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String,
        repoPath: String,
        expectedSize callerExpectedSize: Int? = nil,
        progress: Progress?
    ) async throws -> URL {
        let fileManager = FileManager.default

        // Etag is required for blob-based cache storage
        // Note: metadata.etag is already normalized by fetchFileMetadata
        guard let normalizedEtag = metadata?.etag else {
            throw HubCacheError.unexpectedAPIResponse("Server did not return an ETag header for '\(repoPath)'")
        }
        guard let commitHash = metadata?.commitHash else {
            throw HubCacheError.unexpectedAPIResponse("Server did not return a commit hash for '\(repoPath)'")
        }
        let blobsDir = cache.blobsDirectory(repo: repo, kind: kind)
        let blobPath = blobsDir.appendingPathComponent(normalizedEtag)

        // Require a known file size for integrity validation. Use the HEAD response
        // size when available, falling back to the caller-provided size (e.g., from
        // the model API's siblings list). Python also requires size (raises
        // FileMetadataError if missing). This guard only fires when the file isn't
        // cached (the cache-first check above returns early for cached files).
        guard let expectedSize = metadata?.size ?? callerExpectedSize else {
            throw HubCacheError.missingFileSize(repoPath)
        }

        // Check if blob already exists (skip download)
        if fileManager.fileExists(atPath: blobPath.path) {
            if isBlobSizeValid(atPath: blobPath.path, expectedSize: expectedSize) {
                return try createCacheEntries(
                    cache: cache,
                    repo: repo,
                    kind: kind,
                    revision: revision,
                    commitHash: commitHash,
                    repoPath: repoPath,
                    etag: normalizedEtag
                )
            }
            // Size mismatch — corrupted blob will be deleted inside the lock
        }

        // Acquire lock to prevent parallel downloads of the same blob
        let locksDir = cache.locksDirectory(repo: repo, kind: kind)
        let lockPath = locksDir.appendingPathComponent(normalizedEtag)
        let lock = await FileLock(lockPath: lockPath.appendingPathExtension("lock"), maxRetries: nil)
        return try await lock.withLock {
            // Double-check blob doesn't exist after acquiring lock
            if fileManager.fileExists(atPath: blobPath.path) {
                if isBlobSizeValid(atPath: blobPath.path, expectedSize: expectedSize) {
                    return try createCacheEntries(
                        cache: cache,
                        repo: repo,
                        kind: kind,
                        revision: revision,
                        commitHash: commitHash,
                        repoPath: repoPath,
                        etag: normalizedEtag
                    )
                }
                try? fileManager.removeItem(at: blobPath)
            }

            // Create blobs directory
            try fileManager.createDirectory(at: blobsDir, withIntermediateDirectories: true)

            // Platform-specific download to cache
            #if canImport(FoundationNetworking)
                try await downloadToCacheLinux(
                    request: request,
                    blobPath: blobPath,
                    expectedSize: expectedSize,
                    progress: progress
                )
            #else
                try await downloadToCacheApple(
                    request: request,
                    blobPath: blobPath,
                    etag: normalizedEtag,
                    blobsDir: blobsDir,
                    expectedSize: expectedSize,
                    progress: progress
                )
            #endif

            // Create snapshot symlink and return path
            return try createCacheEntries(
                cache: cache,
                repo: repo,
                kind: kind,
                revision: revision,
                commitHash: commitHash,
                repoPath: repoPath,
                etag: normalizedEtag
            )
        }
    }

    /// Checks whether a blob's on-disk size matches the expected size.
    private func isBlobSizeValid(atPath path: String, expectedSize: Int) -> Bool {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let actualSize = attrs[.size] as? Int
        else { return false }
        return actualSize == expectedSize
    }

    /// Validates a downloaded file's size against the expected size.
    /// Removes the file and throws if there is a mismatch.
    private func validateDownloadedFileSize(
        at path: URL,
        expectedSize: Int
    ) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let actualSize = (attrs[.size] as? Int) ?? 0
        if actualSize != expectedSize {
            try? FileManager.default.removeItem(at: path)
            throw HubCacheError.fileSizeMismatch(
                expected: expectedSize,
                actual: actualSize
            )
        }
    }

    /// Creates cache entries (snapshot symlink and ref) for a downloaded blob.
    ///
    /// Returns the snapshot symlink path, which resolves through to the blob.
    private func createCacheEntries(
        cache: HubCache,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String,
        commitHash: String,
        repoPath: String,
        etag: String
    ) throws -> URL {
        // Create symlink in snapshots
        try cache.createSnapshotSymlink(
            repo: repo,
            kind: kind,
            revision: commitHash,
            filename: repoPath,
            etag: etag
        )

        // Update ref if needed
        if revision != commitHash {
            try? cache.updateRef(repo: repo, kind: kind, ref: revision, commit: commitHash)
        }

        return cache.snapshotsDirectory(repo: repo, kind: kind)
            .appendingPathComponent(commitHash)
            .appendingPathComponent(repoPath)
    }

    private func fileURL(
        repoPath: String,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String,
        endpoint: FileDownloadEndpoint
    ) -> URL {
        var url = httpClient.host
        // Models have no path prefix on resolve URLs; only datasets and spaces
        // are pluralized. Matches Python's REPO_TYPES_URL_PREFIXES.
        if kind != .model {
            url = url.appending(path: kind.pluralized)
        }
        return
            url
            .appending(path: repo.namespace)
            .appending(path: repo.name)
            .appending(path: endpoint.pathComponent)
            .appending(component: revision)
            .appending(path: repoPath)
    }

    /// Download a file to the cache using a tree entry (uses file size for transport selection).
    ///
    /// Returns the snapshot symlink path, which resolves through to the blob.
    func downloadFile(
        _ entry: Git.TreeEntry,
        from repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main",
        endpoint: FileDownloadEndpoint = .resolve,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        progress: Progress? = nil,
        transport: FileDownloadTransport = .automatic
    ) async throws -> URL {
        return try await downloadFile(
            at: entry.path,
            from: repo,
            kind: kind,
            revision: revision,
            endpoint: endpoint,
            cachePolicy: cachePolicy,
            progress: progress,
            transport: transport,
            expectedSize: entry.size
        )
    }

    #if canImport(FoundationNetworking)
        /// Linux: Downloads file to cache blob path.
        private func downloadToCacheLinux(
            request: URLRequest,
            blobPath: URL,
            expectedSize: Int,
            progress: Progress?
        ) async throws {
            let (tempURL, response) = try await session.asyncDownload(for: request, progress: progress)
            _ = try httpClient.validateResponse(response, data: nil)

            // Move temp file to blob path
            try? FileManager.default.removeItem(at: blobPath)
            try FileManager.default.moveItem(at: tempURL, to: blobPath)

            // Validate size after move
            try validateDownloadedFileSize(at: blobPath, expectedSize: expectedSize)
        }
    #else
        /// Apple: Downloads file to cache with resume support.
        ///
        /// Uses `URLSession.download(for:delegate:)` for efficient OS-level streaming to disk.
        /// For resume, downloads the remainder to a temp file and appends it to the
        /// `.incomplete` file, then moves to the final blob path.
        private func downloadToCacheApple(
            request: URLRequest,
            blobPath: URL,
            etag: String,
            blobsDir: URL,
            expectedSize: Int,
            progress: Progress?
        ) async throws {
            let fileManager = FileManager.default
            let incompletePath = blobsDir.appendingPathComponent("\(etag).incomplete")

            // Track whether we should ignore any existing incomplete file and start fresh.
            // This is set to true after receiving a 416 response, which indicates the
            // Range header we sent was invalid (e.g., incomplete file is larger than
            // the actual file, or the file changed on the server).
            var shouldStartFresh = false

            while true {
                // Check for incomplete file to resume (skip if we're retrying after 416)
                var resumeSize: Int64 = 0
                if !shouldStartFresh,
                    fileManager.fileExists(atPath: incompletePath.path),
                    let attrs = try? fileManager.attributesOfItem(atPath: incompletePath.path),
                    let size = attrs[.size] as? Int64
                {
                    resumeSize = size
                } else {
                    try? fileManager.removeItem(at: incompletePath)
                }

                // Add Range header if resuming
                var resumeRequest = request
                if resumeSize > 0 {
                    resumeRequest.setValue("bytes=\(resumeSize)-", forHTTPHeaderField: "Range")
                }

                let (tempURL, response): (URL, URLResponse)
                if let progress {
                    (tempURL, response) = try await downloadWithProgress(
                        request: resumeRequest,
                        progress: progress,
                        resumeOffset: resumeSize
                    )
                } else {
                    (tempURL, response) = try await session.download(for: resumeRequest)
                }

                // URLSession writes the response body to a temp file but does not delete it.
                // Clean up here whether we consumed it via moveItem/appendFile or threw.
                defer { try? fileManager.removeItem(at: tempURL) }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw HTTPClientError.unexpectedError("Invalid HTTP response")
                }

                let statusCode = httpResponse.statusCode

                // Handle 416 Range Not Satisfiable: the Range header we sent was invalid.
                // This typically happens when:
                // 1. The incomplete file is larger than the actual file on the server
                // 2. The file changed on the server since we started downloading
                // 3. The incomplete file contains corrupted/invalid data
                // Solution: delete the incomplete file and retry once without a Range header.
                if statusCode == 416 {
                    guard !shouldStartFresh else {
                        throw HTTPClientError.responseError(
                            response: httpResponse,
                            detail: "Download failed: server returned 416 after fresh retry"
                        )
                    }
                    shouldStartFresh = true
                    continue
                }

                guard (200 ..< 300).contains(statusCode) else {
                    throw HTTPClientError.responseError(
                        response: httpResponse,
                        detail: "Download failed with status \(statusCode)"
                    )
                }

                if statusCode == 206, resumeSize > 0 {
                    // Partial content: append the downloaded remainder to the incomplete file
                    try appendFile(from: tempURL, to: incompletePath)
                    try? fileManager.removeItem(at: blobPath)
                    try fileManager.moveItem(at: incompletePath, to: blobPath)
                } else {
                    // Full download (200): server ignored Range or fresh download.
                    try? fileManager.removeItem(at: incompletePath)
                    try? fileManager.removeItem(at: blobPath)
                    try fileManager.moveItem(at: tempURL, to: blobPath)
                }

                // Validate size after move
                try validateDownloadedFileSize(at: blobPath, expectedSize: expectedSize)

                return
            }
        }

        /// Downloads a file using the callback-based URLSession API with a delegate for progress tracking.
        ///
        /// The async `URLSession.download(for:delegate:)` API does not call `URLSessionDownloadDelegate`
        /// methods (only `URLSessionTaskDelegate`), so progress callbacks never fire. This method uses
        /// the older callback-based `downloadTask(with:)` with a dedicated session to get real progress.
        private func downloadWithProgress(
            request: URLRequest,
            progress: Progress,
            resumeOffset: Int64
        ) async throws -> (URL, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = CallbackDownloadDelegate(
                    progress: progress,
                    resumeOffset: resumeOffset,
                    continuation: continuation
                )
                let downloadSession = URLSession(
                    configuration: session.configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task = downloadSession.downloadTask(with: request)
                delegate.task = task
                task.resume()
            }
        }

        /// Appends the contents of one file to another using chunked reads.
        private func appendFile(from source: URL, to destination: URL) throws {
            let sourceHandle = try FileHandle(forReadingFrom: source)
            defer { try? sourceHandle.close() }
            let destHandle = try FileHandle(forWritingTo: destination)
            defer { try? destHandle.close() }

            try destHandle.seekToEnd()

            let chunkSize = 1_048_576  // 1 MB
            while let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty {
                try destHandle.write(contentsOf: chunk)
            }
        }
    #endif

}

// MARK: - Download Progress Delegate

#if !canImport(FoundationNetworking)
    /// Delegate for tracking download progress and completing the download via continuation.
    ///
    /// Used with the callback-based `URLSession.downloadTask(with:)` API because the async
    /// `URLSession.download(for:delegate:)` does not call `URLSessionDownloadDelegate` methods.
    ///
    /// When resuming a partial download, `resumeOffset` accounts for bytes already on disk
    /// so that progress reports the true total (offset + newly downloaded bytes). Without this,
    /// Foundation's Progress parent-child tree would scale the partial download to the full
    /// file weight, causing the progress bar to advance at inflated speed.
    ///
    /// Safe to mark @unchecked Sendable: mutable state is only accessed from URLSession's
    /// delegate queue, which serializes all callbacks.
    private final class CallbackDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: Progress
        private let resumeOffset: Int64
        private let startTime: CFAbsoluteTime
        private let continuation: CheckedContinuation<(URL, URLResponse), Error>
        var task: URLSessionDownloadTask?
        private var hasResumed = false

        init(
            progress: Progress,
            resumeOffset: Int64,
            continuation: CheckedContinuation<(URL, URLResponse), Error>
        ) {
            self.progress = progress
            self.resumeOffset = resumeOffset
            self.startTime = CFAbsoluteTimeGetCurrent()
            self.continuation = continuation
        }

        func urlSession(
            _: URLSession,
            downloadTask _: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            // Only update totalUnitCount when the server provides Content-Length.
            // When using chunked transfer encoding, totalBytesExpectedToWrite is
            // NSURLSessionTransferSizeUnknown (-1), which would corrupt the
            // Progress parent-child tree (fractionCompleted returns 0 for
            // negative totalUnitCount).
            if totalBytesExpectedToWrite >= 0 {
                progress.totalUnitCount = resumeOffset + totalBytesExpectedToWrite
            }
            progress.completedUnitCount = resumeOffset + totalBytesWritten

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > 0 {
                let bytesPerSecond = Double(totalBytesWritten) / elapsed
                progress.setUserInfoObject(bytesPerSecond, forKey: .throughputKey)
            }
        }

        func urlSession(
            _: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard !hasResumed else { return }
            hasResumed = true

            guard let response = downloadTask.response else {
                continuation.resume(throwing: URLError(.badServerResponse))
                return
            }

            // Copy to a new temp location since the original will be deleted
            let newTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: location, to: newTempURL)
                continuation.resume(returning: (newTempURL, response))
            } catch {
                continuation.resume(throwing: error)
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            guard !hasResumed else { return }
            hasResumed = true

            // Resume with the error if one occurred. If error is nil,
            // didFinishDownloadingTo should have already resumed the
            // continuation. Reaching here with nil error means the download
            // completed without producing a file — resume with an error to
            // avoid leaking the continuation.
            continuation.resume(throwing: error ?? URLError(.cannotWriteToFile))
        }
    }
#endif

// MARK: - Delete Operations

public extension HubClient {
    /// Delete a file from a repository
    /// - Parameters:
    ///   - repoPath: Path to file to delete
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - branch: Target branch
    ///   - message: Commit message
    func deleteFile(
        at repoPath: String,
        from repo: Repo.ID,
        kind: Repo.Kind = .model,
        branch: String = "main",
        message: String
    ) async throws {
        try await deleteFiles(at: [repoPath], from: repo, kind: kind, branch: branch, message: message)
    }

    /// Delete multiple files from a repository
    /// - Parameters:
    ///   - paths: Paths to files to delete
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - branch: Target branch
    ///   - message: Commit message
    func deleteFiles(
        at repoPaths: [String],
        from repo: Repo.ID,
        kind: Repo.Kind = .model,
        branch: String = "main",
        message: String
    ) async throws {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: kind.pluralized)
            .appending(path: repo.namespace)
            .appending(path: repo.name)
            .appending(path: "commit")
            .appending(component: branch)
        let operations = repoPaths.map { path in
            Value.object(["op": .string("delete"), "path": .string(path)])
        }
        let params: [String: Value] = [
            "title": .string(message),
            "operations": .array(operations),
        ]

        let _: Bool = try await httpClient.fetch(.post, url: url, params: params)
    }
}

// MARK: - Query Operations

public extension HubClient {
    /// Check if a file exists in a repository
    /// - Parameters:
    ///   - repoPath: Path to file
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - revision: Git revision
    /// - Returns: True if file exists
    func fileExists(
        at repoPath: String,
        in repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main"
    ) async -> Bool {
        do {
            let info = try await getFile(at: repoPath, in: repo, kind: kind, revision: revision)
            return info.exists
        } catch {
            return false
        }
    }

    /// List files in a repository
    /// - Parameters:
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - revision: Git revision
    ///   - recursive: List files recursively
    /// - Returns: Array of tree entries
    func listFiles(
        in repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main",
        recursive: Bool = true
    ) async throws -> [Git.TreeEntry] {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: kind.pluralized)
            .appending(path: repo.namespace)
            .appending(path: repo.name)
            .appending(path: "tree")
            .appending(component: revision)
        let params: [String: Value]? = recursive ? ["recursive": .bool(true)] : nil

        return try await httpClient.fetch(.get, url: url, params: params)
    }

    /// Get file information
    /// - Parameters:
    ///   - repoPath: Path to file
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - revision: Git revision
    /// - Returns: File information
    func getFile(
        at repoPath: String,
        in repo: Repo.ID,
        kind _: Repo.Kind = .model,
        revision: String = "main"
    ) async throws -> File {
        let url = httpClient.host
            .appending(path: repo.namespace)
            .appending(path: repo.name)
            .appending(path: "resolve")
            .appending(component: revision)
            .appending(path: repoPath)
        var request = try await httpClient.createRequest(.head, url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return File(exists: false)
            }

            let exists = httpResponse.statusCode == 200 || httpResponse.statusCode == 206
            let size = httpResponse.value(forHTTPHeaderField: "Content-Length")
                .flatMap { Int64($0) }
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")
            let revision = httpResponse.value(forHTTPHeaderField: "X-Repo-Commit")
            let isLFS =
                httpResponse.value(forHTTPHeaderField: "X-Linked-Size") != nil
                || httpResponse.value(forHTTPHeaderField: "Link")?.contains("lfs") == true

            return File(
                exists: exists,
                size: size,
                etag: etag,
                revision: revision,
                isLFS: isLFS
            )
        } catch {
            return File(exists: false)
        }
    }
}

// MARK: - Snapshot Cache Lookup

public extension HubClient {
    /// Returns the cached snapshot path if all files matching the given globs
    /// are already downloaded, without making any network calls.
    ///
    /// This method resolves the revision (commit hash or branch name) to a
    /// local commit hash and checks cached repo info to verify that all
    /// matching files have been downloaded. Returns `nil` if the snapshot is
    /// missing, incomplete, or has no cached repo info.
    ///
    /// Use this method to avoid the latency of a network call when you only
    /// need to check whether files are already available locally. For branch
    /// names (e.g. "main"), the returned snapshot may not reflect the latest
    /// remote version — use ``downloadSnapshot(of:kind:revision:matching:to:localFilesOnly:maxConcurrent:progressHandler:)``
    /// when freshness matters.
    ///
    /// - Parameters:
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - revision: Git revision (branch, tag, or commit hash)
    ///   - globs: Glob patterns to filter files (empty array checks all files)
    /// - Returns: Path to the verified snapshot directory, or `nil`
    func resolveCachedSnapshot(
        repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String,
        matching globs: [String] = []
    ) -> URL? {
        let commit: String
        if isCommitHash(revision) {
            commit = revision
        } else if let resolved = cache.resolveRevision(repo: repo, kind: kind, ref: revision) {
            commit = resolved
        } else {
            return nil
        }

        return verifiedSnapshotPath(
            cache: cache,
            repo: repo,
            kind: kind,
            commit: commit,
            matching: globs
        )?.snapshotPath
    }
}

// MARK: - Snapshot Download

public extension HubClient {
    /// Download a repository snapshot to a local directory.
    ///
    /// This method downloads all files from a repository to the specified destination.
    /// Files are automatically cached in the Python-compatible cache directory,
    /// allowing cache reuse between Swift and Python Hugging Face clients.
    ///
    /// Files are downloaded in parallel (up to `maxConcurrent` simultaneous downloads)
    /// and progress is weighted by file size for accurate reporting.
    ///
    /// In offline mode (explicit or auto-detected), this method returns cached files
    /// without making network requests. An error is thrown if required files are not cached.
    ///
    /// Downloads can be cancelled by cancelling the enclosing task:
    /// ```swift
    /// let task = Task {
    ///     try await client.downloadSnapshot(of: "repo/id")
    /// }
    /// // Later:
    /// task.cancel()
    /// ```
    ///
    /// - Parameters:
    ///   - repo: Repository identifier
    ///   - kind: Kind of repository
    ///   - destination: Local destination directory
    ///   - revision: Git revision (branch, tag, or commit)
    ///   - matching: Glob patterns to filter files (empty array downloads all files)
    ///   - maxConcurrent: Maximum number of concurrent downloads (default: 8)
    ///   - progressHandler: Optional closure called with progress updates
    /// - Returns: URL to the local snapshot directory
    func downloadSnapshot(
        of repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main",
        matching globs: [String] = [],
        to destination: URL? = nil,
        localFilesOnly: Bool = false,
        maxConcurrent: Int = 8,
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        // When localFilesOnly is set or the device is offline, return cached
        // files without making any network requests.
        if localFilesOnly {
            let snapshotPath = try downloadSnapshotOffline(
                cache: cache,
                repo: repo,
                kind: kind,
                revision: revision
            )
            return try copySnapshotToLocalDirectoryIfNeeded(
                from: snapshotPath,
                localDirectory: destination
            )
        }
        if await shouldUseOfflineMode() {
            let snapshotPath = try downloadSnapshotOffline(
                cache: cache,
                repo: repo,
                kind: kind,
                revision: revision
            )
            return try copySnapshotToLocalDirectoryIfNeeded(
                from: snapshotPath,
                localDirectory: destination
            )
        }

        // Fast path: when revision is already a commit hash (immutable), use cached
        // repo info to verify all matching files are present before returning.
        //
        // Python's snapshot_download acknowledges this limitation in its offline path:
        //   "we can't check if all the files are actually there"
        //   (huggingface_hub/_snapshot_download.py:293)
        // We improve on this by caching the API response after the first download and
        // verifying each file's presence in the snapshot on subsequent calls.
        if isCommitHash(revision),
            let verified = verifiedSnapshotPath(
                cache: cache,
                repo: repo,
                kind: kind,
                commit: revision,
                matching: globs
            )
        {
            // Cache hit: nothing is actually downloaded, but we report the final state of
            // a logically complete download, so consumers see consistent metadata between
            // this path and the active-download path below.
            let totalBytes = verified.entries.reduce(Int64(0)) { $0 + Int64($1.size ?? 1) }
            let totalProgress = Progress(totalUnitCount: totalBytes)
            totalProgress.kind = .file
            #if !canImport(FoundationNetworking)
                totalProgress.fileOperationKind = .downloading
                totalProgress.fileTotalCount = verified.entries.count
                totalProgress.fileCompletedCount = verified.entries.count
            #endif
            totalProgress.completedUnitCount = totalProgress.totalUnitCount
            progressHandler?(totalProgress)
            return try copySnapshotToLocalDirectoryIfNeeded(
                from: verified.snapshotPath,
                localDirectory: destination
            )
        }

        // Fetch repo info from the server. If the network call fails, fall back to the
        // local cache (matching huggingface_hub's try/except → local_files_only pattern).
        let repoInfo: RepoInfoForDownload
        do {
            repoInfo = try await getRepoInfo(for: repo, kind: kind, revision: revision)
        } catch {
            if let cached = try? downloadSnapshotOffline(
                cache: cache,
                repo: repo,
                kind: kind,
                revision: revision
            ) {
                return try copySnapshotToLocalDirectoryIfNeeded(
                    from: cached,
                    localDirectory: destination
                )
            }
            throw error
        }
        let commitHash = repoInfo.commitHash

        guard let siblings = repoInfo.siblings else {
            throw HubCacheError.unexpectedAPIResponse("Could not get file list for repository '\(repo)'")
        }

        let entries = siblings.filter { entry in
            guard !globs.isEmpty else { return true }
            return globs.contains { glob in
                fnmatch(glob, entry.path, 0) == 0
            }
        }

        let snapshotPath = cache.snapshotsDirectory(repo: repo, kind: kind)
            .appendingPathComponent(commitHash)

        // Size-weighted progress: total is sum of file sizes (bytes)
        let totalBytes = entries.reduce(Int64(0)) { $0 + Int64($1.size ?? 1) }
        let totalProgress = Progress(totalUnitCount: totalBytes)
        totalProgress.kind = .file
        #if !canImport(FoundationNetworking)
            totalProgress.fileOperationKind = .downloading
            totalProgress.fileTotalCount = entries.count
            totalProgress.fileCompletedCount = 0
        #endif
        let startTime = Date().timeIntervalSinceReferenceDate
        progressHandler?(totalProgress)

        // Periodically update speed and notify the caller so progress is visible
        // during long single-file downloads (not just at file boundaries).
        let speedUpdateTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: DownloadConstants.speedUpdateIntervalNanoseconds)
                let elapsed = Date().timeIntervalSinceReferenceDate - startTime
                let bytesCompleted = totalProgress.completedUnitCount
                if elapsed > 0 && bytesCompleted > 0 {
                    let speed = Double(bytesCompleted) / elapsed
                    totalProgress.setUserInfoObject(speed, forKey: .throughputKey)
                }
                progressHandler?(totalProgress)
            }
        }
        defer { speedUpdateTask.cancel() }

        // Parallel downloads with concurrency limiting
        try await withThrowingTaskGroup(of: Void.self) { group in
            let concurrencyLimit = max(1, maxConcurrent)
            var activeCount = 0
            var completedFileCount = 0

            // Increments fileCompletedCount as each per-file task finishes. The task-group
            // consumer loop is serial, so we update from a single context – no atomicity
            // dance needed. Only successful files are counted: if a child task throws,
            // its completion is never recorded, and fileCompletedCount stops short of
            // entries.count.
            func recordFileCompletion() {
                completedFileCount += 1
                #if !canImport(FoundationNetworking)
                    totalProgress.fileCompletedCount = completedFileCount
                #endif
                progressHandler?(totalProgress)
            }

            for entry in entries {
                while activeCount >= concurrencyLimit {
                    guard try await group.next() != nil else { break }
                    activeCount -= 1
                    recordFileCompletion()
                }

                if Task.isCancelled {
                    break
                }

                let fileSize = Int64(entry.size ?? 1)
                let fileProgress = Progress(totalUnitCount: fileSize, parent: totalProgress, pendingUnitCount: fileSize)

                group.addTask {
                    _ = try await self.downloadFile(
                        entry,
                        from: repo,
                        kind: kind,
                        revision: commitHash,
                        progress: fileProgress
                    )
                    fileProgress.completedUnitCount = fileProgress.totalUnitCount
                }
                activeCount += 1
            }

            for try await _ in group {
                recordFileCompletion()
            }
        }

        // Save repo info after downloads so resolveCachedSnapshot can verify
        // completeness on future calls without a network round-trip
        saveCachedRepoInfo(
            repoInfo,
            cache: cache,
            repo: repo,
            kind: kind,
            commit: commitHash
        )

        // Update ref mapping if we resolved a branch/tag to commit hash
        if revision != commitHash {
            try? cache.updateRef(repo: repo, kind: kind, ref: revision, commit: commitHash)
        }

        // Compute final speed before last handler call
        let elapsed = Date().timeIntervalSinceReferenceDate - startTime
        if elapsed > 0 && totalProgress.completedUnitCount > 0 {
            let finalSpeed = Double(totalProgress.completedUnitCount) / elapsed
            totalProgress.setUserInfoObject(finalSpeed, forKey: .throughputKey)
        }

        progressHandler?(totalProgress)
        return try copySnapshotToLocalDirectoryIfNeeded(
            from: snapshotPath,
            localDirectory: destination
        )
    }

    /// Download a repository snapshot with aggregate speed reporting.
    @discardableResult
    func downloadSnapshot(
        of repo: Repo.ID,
        kind: Repo.Kind = .model,
        revision: String = "main",
        matching globs: [String] = [],
        to destination: URL? = nil,
        localFilesOnly: Bool = false,
        maxConcurrent: Int = 8,
        progressHandler: @Sendable @escaping (Progress, Double?) -> Void
    ) async throws -> URL {
        try await downloadSnapshot(
            of: repo,
            kind: kind,
            revision: revision,
            matching: globs,
            to: destination,
            localFilesOnly: localFilesOnly,
            maxConcurrent: maxConcurrent
        ) { progress in
            let speed = progress.userInfo[.throughputKey] as? Double
            progressHandler(progress, speed)
        }
    }

    /// Returns the snapshot cache path in offline mode.
    ///
    /// Matches huggingface_hub behavior: returns cached snapshot path.
    /// As huggingface_hub notes: "we can't check if all the files are actually there" —
    /// this is a best-effort approach.
    private func downloadSnapshotOffline(
        cache: HubCache,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String
    ) throws -> URL {
        guard let snapshotPath = cache.snapshotPath(repo: repo, kind: kind, revision: revision) else {
            throw HubCacheError.offlineModeError("Repository '\(repo)' not available in cache")
        }
        return snapshotPath
    }

    /// If `localDirectory` is set, copies a single cached file there and returns the
    /// local path. Otherwise returns the cached path unchanged.
    private func copyToLocalDirectoryIfNeeded(
        _ cachedPath: URL,
        repoPath: String,
        localDirectory: URL?
    ) throws -> URL {
        guard let localDirectory else { return cachedPath }
        let localPath = localDirectory.appendingPathComponent(repoPath)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: localPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Resolve symlinks because snapshot entries are relative symlinks to blobs
        // (e.g., ../../blobs/etag). copyItem preserves symlinks, unlike Python's
        // shutil.copyfile which follows them, so we must resolve first.
        try Self.atomicallyCopyItem(
            from: cachedPath.resolvingSymlinksInPath(),
            to: localPath,
            fileManager: fileManager
        )
        return localPath
    }

    /// If `localDirectory` is set, copies all files from a snapshot directory there
    /// and returns the local directory. Otherwise returns the snapshot path unchanged.
    private func copySnapshotToLocalDirectoryIfNeeded(
        from snapshotPath: URL,
        localDirectory: URL?
    ) throws -> URL {
        guard let localDirectory else { return snapshotPath }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: localDirectory, withIntermediateDirectories: true)

        guard
            let enumerator = fileManager.enumerator(
                at: snapshotPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return localDirectory
        }

        for case let fileURL as URL in enumerator {
            // Skip directories so we don't double-walk: the enumerator yields
            // each subdirectory before descending, and `copyItem` would
            // recursively copy it once, then the enumerator would yield each
            // child and we'd copy it again. Snapshot entries are normally
            // symlinks pointing into the blobs directory, and `isDirectoryKey`
            // uses `lstat` semantics so it correctly reports `false` for those
            // — we want to copy them. Using `isRegularFileKey` here would also
            // report `false` for symlinks and skip the entire snapshot, which
            // is what we actually saw before this check was rewritten.
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }

            let snapshotComponents = snapshotPath.standardized.pathComponents
            let fileComponents = fileURL.standardized.pathComponents
            let relativeComponents = fileComponents.dropFirst(snapshotComponents.count)
            let destURL = relativeComponents.reduce(localDirectory) { $0.appendingPathComponent($1) }
            try fileManager.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // See comment in copyToLocalDirectoryIfNeeded above
            try Self.atomicallyCopyItem(
                from: fileURL.resolvingSymlinksInPath(),
                to: destURL,
                fileManager: fileManager
            )
        }

        return localDirectory
    }

    /// Copies `source` into `destination` atomically with respect to concurrent
    /// callers writing to the same destination. Foundation's `moveItem(at:to:)`
    /// pre-checks destination existence and fails if a file appeared between
    /// the check and the rename, so it can't safely overwrite. POSIX `rename(2)`
    /// is atomic on the same volume and overwrites silently, so we copy to a
    /// unique temp path inside the destination's parent and then swap it in.
    private static func atomicallyCopyItem(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let tempURL =
            destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: tempURL)
        var renameErrno: Int32 = 0
        let result = tempURL.withUnsafeFileSystemRepresentation { src -> Int32 in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                let ret = rename(src, dst)
                if ret != 0 { renameErrno = errno }
                return ret
            }
        }
        if result != 0 {
            try? fileManager.removeItem(at: tempURL)
            throw HubCacheError.atomicCopyFailed(
                source: source,
                destination: destination,
                reason: String(cString: strerror(renameErrno))
            )
        }
    }
}

// MARK: - Xet Operations

/// Metadata returned from a Xet HEAD request, combining the Xet file ID
/// with standard cache metadata (etag, commit hash) from the same response.
private struct XetFileInfo {
    let fileID: String
    let refreshURL: URL
    let requestHeaders: [String: String]
    let etag: String?
    let commitHash: String?
    let size: Int?
}

private extension HubClient {
    /// Downloads file data using Xet's content-addressable storage system.
    func downloadDataWithXet(
        repoPath: String,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String
    ) async throws -> Data? {
        guard
            let xetInfo = try await fetchXetFileInfo(
                repoPath: repoPath,
                repo: repo,
                kind: kind,
                revision: revision
            )
        else {
            return nil
        }

        let data = try await Xet.withDownloader(
            refreshURL: xetInfo.refreshURL,
            hubToken: try? await httpClient.tokenProvider.getToken(),
            requestHeaders: xetInfo.requestHeaders
        ) { downloader in
            let data = try await downloader.data(for: xetInfo.fileID)
            if let expectedSize = xetInfo.size, data.count != expectedSize {
                throw HubCacheError.fileSizeMismatch(
                    expected: expectedSize,
                    actual: data.count
                )
            }
            return data
        }

        // Populate the cache so subsequent downloadFile/downloadContentsOfFile
        // calls hit the blob instead of refetching. Mirrors the LFS Data path
        // in downloadContentsOfFile.
        if let etag = xetInfo.etag, let commitHash = xetInfo.commitHash {
            try? await cache.storeData(
                data,
                repo: repo,
                kind: kind,
                revision: commitHash,
                filename: repoPath,
                etag: etag,
                ref: revision != commitHash ? revision : nil
            )
        }

        return data
    }

    /// Downloads a file using Xet's content-addressable storage system.
    ///
    /// Downloads to the blob cache and creates a snapshot symlink.
    /// Returns the snapshot symlink path, or nil if the file doesn't support Xet.
    /// Requires a cache to be configured.
    @discardableResult
    func downloadFileWithXet(
        repoPath: String,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String,
        progress: Progress?,
        expectedSize callerExpectedSize: Int? = nil
    ) async throws -> URL? {
        guard
            let xetInfo = try await fetchXetFileInfo(
                repoPath: repoPath,
                repo: repo,
                kind: kind,
                revision: revision
            )
        else {
            return nil
        }

        guard let normalizedEtag = xetInfo.etag else {
            throw HubCacheError.unexpectedAPIResponse("Server did not return an ETag header for '\(repoPath)'")
        }

        let fileManager = FileManager.default
        guard let commitHash = xetInfo.commitHash else {
            throw HubCacheError.unexpectedAPIResponse("Server did not return a commit hash for '\(repoPath)'")
        }
        let blobsDir = cache.blobsDirectory(repo: repo, kind: kind)
        let blobPath = blobsDir.appendingPathComponent(normalizedEtag)

        // Require a known file size for integrity validation (see downloadWithCacheCoordination).
        guard let expectedSize = xetInfo.size ?? callerExpectedSize else {
            throw HubCacheError.missingFileSize(repoPath)
        }
        let needsDownload =
            !fileManager.fileExists(atPath: blobPath.path)
            || !isBlobSizeValid(atPath: blobPath.path, expectedSize: expectedSize)

        if needsDownload {
            let locksDir = cache.locksDirectory(repo: repo, kind: kind)
            let lockPath = locksDir.appendingPathComponent(normalizedEtag)
            let lock = await FileLock(lockPath: lockPath.appendingPathExtension("lock"), maxRetries: nil)
            try await lock.withLock {
                // Double-check after acquiring lock
                let stillNeeded =
                    !fileManager.fileExists(atPath: blobPath.path)
                    || !isBlobSizeValid(atPath: blobPath.path, expectedSize: expectedSize)
                if stillNeeded {
                    try? fileManager.removeItem(at: blobPath)
                    try fileManager.createDirectory(at: blobsDir, withIntermediateDirectories: true)

                    let incompletePath = blobsDir.appendingPathComponent(
                        "\(normalizedEtag).incomplete"
                    )

                    try await downloadXetWithResume(
                        xetInfo: xetInfo,
                        incompletePath: incompletePath,
                        expectedSize: expectedSize,
                        progress: progress
                    )

                    try validateDownloadedFileSize(
                        at: incompletePath,
                        expectedSize: expectedSize
                    )
                    try? fileManager.removeItem(at: blobPath)
                    try fileManager.moveItem(at: incompletePath, to: blobPath)
                }
            }
        }

        let result = try createCacheEntries(
            cache: cache,
            repo: repo,
            kind: kind,
            revision: revision,
            commitHash: commitHash,
            repoPath: repoPath,
            etag: normalizedEtag
        )

        return result
    }

    /// Downloads a Xet file to `incompletePath`, resuming from any existing
    /// partial bytes. Mirrors the LFS resume flow in `downloadToCacheApple`.
    /// On `appendSizeMismatch` (the staged file no longer matches the requested
    /// resume offset), the partial file is discarded and the download retries
    /// once from byte 0.
    private func downloadXetWithResume(
        xetInfo: XetFileInfo,
        incompletePath: URL,
        expectedSize: Int,
        progress: Progress?
    ) async throws {
        let fileManager = FileManager.default
        let xetProgressHandler: (@Sendable (DownloadProgress) -> Void)? =
            if let progress {
                { xetProgress in
                    progress.totalUnitCount = xetProgress.totalBytes
                    progress.completedUnitCount = xetProgress.bytesWritten
                }
            } else {
                nil
            }

        let totalSize = UInt64(expectedSize)
        let hubToken = try? await httpClient.tokenProvider.getToken()

        func resumeOffset() -> UInt64 {
            guard fileManager.fileExists(atPath: incompletePath.path),
                let attrs = try? fileManager.attributesOfItem(atPath: incompletePath.path),
                let size = attrs[.size] as? Int64,
                size > 0,
                UInt64(size) < totalSize
            else {
                try? fileManager.removeItem(at: incompletePath)
                return 0
            }
            return UInt64(size)
        }

        func attempt(resumingFrom resumeSize: UInt64) async throws {
            _ = try await Xet.withDownloader(
                refreshURL: xetInfo.refreshURL,
                hubToken: hubToken,
                requestHeaders: xetInfo.requestHeaders
            ) { downloader in
                if resumeSize > 0 {
                    try await downloader.download(
                        xetInfo.fileID,
                        byteRange: resumeSize ..< totalSize,
                        to: incompletePath,
                        appendingToExistingFile: true,
                        progressHandler: xetProgressHandler
                    )
                } else {
                    try await downloader.download(
                        xetInfo.fileID,
                        to: incompletePath,
                        progressHandler: xetProgressHandler
                    )
                }
            }
        }

        do {
            try await attempt(resumingFrom: resumeOffset())
        } catch XetDownloaderError.appendSizeMismatch {
            try? fileManager.removeItem(at: incompletePath)
            try await attempt(resumingFrom: 0)
        }
    }

    func fetchXetFileInfo(
        repoPath: String,
        repo: Repo.ID,
        kind: Repo.Kind,
        revision: String
    ) async throws -> XetFileInfo? {
        let url = fileURL(
            repoPath: repoPath,
            repo: repo,
            kind: kind,
            revision: revision,
            endpoint: .resolve
        )
        var request = try await httpClient.createRequest(.head, url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Capture after setting Accept-Encoding so swift-xet forwards the same
        // header set to the Hub token-refresh endpoint, matching Python's
        // xet_get which propagates hf_headers (including Accept-Encoding).
        let requestHeaders = request.allHTTPHeaderFields ?? [:]

        let (_, response) = try await metadataSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        let rawFileID = httpResponse.value(forHTTPHeaderField: "X-Xet-Hash")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileID = rawFileID, !fileID.isEmpty else {
            return nil
        }

        guard let refreshURL = xetRefreshURL(from: httpResponse) else {
            return nil
        }

        let rawSize =
            httpResponse.value(forHTTPHeaderField: "X-Linked-Size")
            ?? ((200 ..< 300).contains(httpResponse.statusCode)
                ? httpResponse.value(forHTTPHeaderField: "Content-Length")
                : nil)
        let fileSizeBytes = rawSize.flatMap(Int.init)

        guard isValidHash(fileID, pattern: sha256Pattern) else {
            return nil
        }

        // Extract cache metadata from the same HEAD response to avoid a second request.
        // Uses X-Linked-Etag (for LFS/Xet files) with ETag fallback, matching fetchFileMetadata.
        let linkedEtag = httpResponse.value(forHTTPHeaderField: "X-Linked-Etag")
        let etag = linkedEtag ?? httpResponse.value(forHTTPHeaderField: "ETag")
        let commitHash = httpResponse.value(forHTTPHeaderField: "X-Repo-Commit")

        return XetFileInfo(
            fileID: fileID,
            refreshURL: refreshURL,
            requestHeaders: requestHeaders,
            etag: etag.map { HubCache.normalizeEtag($0) },
            commitHash: commitHash,
            size: fileSizeBytes
        )
    }

    func xetRefreshURL(from response: HTTPURLResponse) -> URL? {
        if let linkHeader = response.value(forHTTPHeaderField: "Link"),
            let linkURL = xetAuthURL(from: linkHeader)
        {
            return normalizeXetRefreshURL(linkURL)
        }

        if let refreshRoute = response.value(forHTTPHeaderField: "X-Xet-Refresh-Route") {
            return normalizeXetRefreshURL(refreshRoute)
        }

        return nil
    }

    /// Extracts the URL of the `xet-auth` link from an RFC 8288 `Link` header.
    ///
    /// Tolerates parameter ordering, optional quoting, mixed casing of parameter
    /// names, multi-token `rel` values, and characters that would confuse a naive
    /// comma/semicolon split (commas inside `<...>` or inside quoted parameter
    /// values).
    ///
    /// When multiple links carry `rel="xet-auth"`, returns the URL of the last
    /// one. This matches `httpx.Response.links`, which keys a dict by `rel` so
    /// later entries overwrite earlier ones. RFC 8288 does not specify a tie
    /// breaker; the Hub never sends more than one xet-auth link in practice.
    ///
    /// `rel` matching uses RFC 8288 token semantics: a link with
    /// `rel="xet-auth other"` matches. This is more permissive than Python's
    /// `httpx`, which keys by the full `rel` string and would only match an
    /// exact `rel="xet-auth"`. The two behaviors agree on the single-token
    /// case the Hub actually emits.
    func xetAuthURL(from linkHeader: String) -> String? {
        var match: String?
        for link in Self.parseLinkHeader(linkHeader) {
            let hasXetAuth = link.parameters.contains { name, value in
                name.lowercased() == "rel"
                    && value.split(whereSeparator: \.isWhitespace)
                        .contains { $0.lowercased() == "xet-auth" }
            }
            if hasXetAuth {
                match = link.url
            }
        }
        return match
    }

    private struct LinkHeaderEntry {
        let url: String
        let parameters: [(name: String, value: String)]
    }

    /// Parses an RFC 8288 `Link` header into individual `<url>; param=value`
    /// entries. Splits only at top-level delimiters (outside of `<...>` and
    /// outside of quoted strings).
    private static func parseLinkHeader(_ header: String) -> [LinkHeaderEntry] {
        var entries: [LinkHeaderEntry] = []
        var current = ""
        var inAngleBrackets = false
        var inQuotes = false
        var escaped = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            if trimmed.isEmpty { return }
            if let entry = parseLinkEntry(trimmed) {
                entries.append(entry)
            }
        }

        for char in header {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if inQuotes {
                if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inQuotes = false
                }
                current.append(char)
                continue
            }
            if inAngleBrackets {
                if char == ">" { inAngleBrackets = false }
                current.append(char)
                continue
            }
            switch char {
            case "<": inAngleBrackets = true; current.append(char)
            case "\"": inQuotes = true; current.append(char)
            case ",": flush()
            default: current.append(char)
            }
        }
        flush()
        return entries
    }

    /// Parses a single link entry of the form `<url>; name=value; name="value"`.
    private static func parseLinkEntry(_ entry: String) -> LinkHeaderEntry? {
        var segments: [String] = []
        var current = ""
        var inAngleBrackets = false
        var inQuotes = false
        var escaped = false
        for char in entry {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if inQuotes {
                if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inQuotes = false
                }
                current.append(char)
                continue
            }
            if inAngleBrackets {
                if char == ">" { inAngleBrackets = false }
                current.append(char)
                continue
            }
            switch char {
            case "<": inAngleBrackets = true; current.append(char)
            case "\"": inQuotes = true; current.append(char)
            case ";":
                segments.append(current)
                current = ""
            default: current.append(char)
            }
        }
        segments.append(current)

        guard let first = segments.first else { return nil }
        let trimmedURL = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.hasPrefix("<"), trimmedURL.hasSuffix(">") else { return nil }
        let url = String(trimmedURL.dropFirst().dropLast())

        let parameters: [(name: String, value: String)] = segments.dropFirst().compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let equals = trimmed.firstIndex(of: "=") else { return nil }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return (name: name, value: value)
        }

        return LinkHeaderEntry(url: url, parameters: parameters)
    }

    func normalizeXetRefreshURL(_ route: String) -> URL? {
        let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Match Python's huggingface_hub: replace just the host prefix
        // (`https://huggingface.co`) with the configured endpoint, preserving
        // any sub-path on that endpoint (e.g. `https://mirror.example/hf`).
        // The trailing slash on the matched prefix prevents accidental host
        // swaps for prefixes like `https://huggingface.cooperative.example`.
        let huggingFaceHome = "https://huggingface.co/"
        if trimmed.hasPrefix(huggingFaceHome) {
            let hostStripped = String(huggingFaceHome.dropLast())  // "https://huggingface.co"
            let endpoint = httpClient.host.absoluteString
            let endpointStripped = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
            return URL(string: endpointStripped + trimmed.dropFirst(hostStripped.count))
        }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: trimmed, relativeTo: httpClient.host)?.absoluteURL
    }
}

// MARK: - Metadata Helpers

extension HubClient {
    private var sha256Pattern: String { "^[0-9a-f]{64}$" }
    private var commitHashPattern: String { "^[0-9a-f]{40}$" }

    /// Read metadata about a file in the local directory.
    func readDownloadMetadata(at metadataPath: URL) -> LocalDownloadFileMetadata? {
        FileManager.default.readDownloadMetadata(at: metadataPath)
    }

    /// Write metadata about a downloaded file.
    func writeDownloadMetadata(commitHash: String, etag: String, to metadataPath: URL) throws {
        try FileManager.default.writeDownloadMetadata(
            commitHash: commitHash,
            etag: etag,
            to: metadataPath
        )
    }

    /// Check if a hash matches the expected pattern.
    func isValidHash(_ hash: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(location: 0, length: hash.utf16.count)
        return regex.firstMatch(in: hash, options: [], range: range) != nil
    }

    /// Compute SHA256 hash of a file.
    func computeFileHash(at url: URL) throws -> String {
        try FileManager.default.computeFileHash(at: url)
    }
}

// MARK: -

private struct UploadResponse: Codable {
    let path: String
    let commit: String?
}

// MARK: -

private extension FileManager {
    /// Read metadata about a file in the local directory.
    func readDownloadMetadata(at metadataPath: URL) -> LocalDownloadFileMetadata? {
        guard fileExists(atPath: metadataPath.path) else {
            return nil
        }

        do {
            let contents = try String(contentsOf: metadataPath, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)

            guard lines.count >= 3 else {
                try? removeItem(at: metadataPath)
                return nil
            }

            let commitHash = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let etag = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)

            guard let timestamp = Double(lines[2].trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                try? removeItem(at: metadataPath)
                return nil
            }

            let timestampDate = Date(timeIntervalSince1970: timestamp)
            let filename = metadataPath.lastPathComponent.replacingOccurrences(
                of: ".metadata",
                with: ""
            )

            return LocalDownloadFileMetadata(
                commitHash: commitHash,
                etag: etag,
                filename: filename,
                timestamp: timestampDate
            )
        } catch {
            try? removeItem(at: metadataPath)
            return nil
        }
    }

    /// Write metadata about a downloaded file.
    func writeDownloadMetadata(commitHash: String, etag: String, to metadataPath: URL) throws {
        let metadataContent = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        try createDirectory(
            at: metadataPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try metadataContent.write(to: metadataPath, atomically: true, encoding: .utf8)
    }

    /// Compute SHA256 hash of a file.
    func computeFileHash(at url: URL) throws -> String {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw HTTPClientError.unexpectedError("Unable to open file: \(url.path)")
        }

        defer {
            try? fileHandle.close()
        }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024

        #if canImport(Darwin)
            while autoreleasepool(invoking: {
                guard let nextChunk = try? fileHandle.read(upToCount: chunkSize),
                    !nextChunk.isEmpty
                else {
                    return false
                }

                hasher.update(data: nextChunk)
                return true
            }) {}
        #else
            while true {
                guard let nextChunk = try? fileHandle.read(upToCount: chunkSize),
                    !nextChunk.isEmpty
                else {
                    break
                }

                hasher.update(data: nextChunk)
            }
        #endif

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: -

private extension URL {
    var mimeType: String? {
        #if canImport(UniformTypeIdentifiers)
            guard let uti = UTType(filenameExtension: pathExtension) else {
                return nil
            }
            return uti.preferredMIMEType
        #else
            // Fallback MIME type lookup for Linux
            let ext = pathExtension.lowercased()
            switch ext {
            // MARK: - JSON
            case "json":
                return "application/json"
            // MARK: - Text
            case "txt":
                return "text/plain"
            case "md":
                return "text/markdown"
            case "csv":
                return "text/csv"
            case "tsv":
                return "text/tab-separated-values"
            // MARK: - HTML and Markup
            case "html", "htm":
                return "text/html"
            case "xml":
                return "application/xml"
            case "svg":
                return "image/svg+xml"
            case "yaml", "yml":
                return "application/x-yaml"
            case "toml":
                return "application/toml"
            // MARK: - Code
            case "js":
                return "application/javascript"
            case "py":
                return "text/x-python"
            case "swift":
                return "text/x-swift"
            case "css":
                return "text/css"
            case "ipynb":
                return "application/x-ipynb+json"
            // MARK: - Archives and Compressed
            case "zip":
                return "application/zip"
            case "gz", "gzip":
                return "application/gzip"
            case "tar":
                return "application/x-tar"
            case "bz2":
                return "application/x-bzip2"
            case "7z":
                return "application/x-7z-compressed"
            // MARK: - PDF and Documents
            case "pdf":
                return "application/pdf"
            // MARK: - Images
            case "png":
                return "image/png"
            case "jpg", "jpeg":
                return "image/jpeg"
            case "gif":
                return "image/gif"
            case "webp":
                return "image/webp"
            case "bmp":
                return "image/bmp"
            case "tiff", "tif":
                return "image/tiff"
            // MARK: - Audio
            case "m4a":
                return "audio/mp4"
            case "mp3":
                return "audio/mpeg"
            case "wav":
                return "audio/wav"
            case "flac":
                return "audio/flac"
            case "ogg":
                return "audio/ogg"
            // MARK: - Video
            case "mp4":
                return "video/mp4"
            case "webm":
                return "video/webm"
            // MARK: - ML/Model/Raw Data
            case "bin", "safetensors", "gguf", "ggml":
                return "application/octet-stream"
            case "pt", "pth":
                return "application/octet-stream"
            case "onnx":
                return "application/octet-stream"
            case "ckpt":
                return "application/octet-stream"
            case "npz":
                return "application/octet-stream"
            // MARK: - Default
            default:
                return "application/octet-stream"
            }
        #endif
    }
}

/// Checks if a string is a valid Git commit hash (40 hex characters).
private func isCommitHash(_ string: String) -> Bool {
    guard string.count == 40 else { return false }
    return string.allSatisfy { $0.isHexDigit }
}

// MARK: - Cached Repo Info

/// Saves the API response for a commit to the metadata directory for future fast path lookups.
private func saveCachedRepoInfo(
    _ info: RepoInfoForDownload,
    cache: HubCache,
    repo: Repo.ID,
    kind: Repo.Kind,
    commit: String
) {
    let metadataDir = cache.metadataDirectory(repo: repo, kind: kind)
    try? FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
    let path = metadataDir.appendingPathComponent("\(commit).json")
    try? JSONEncoder().encode(info).write(to: path)
}

/// Loads cached repo info from the metadata directory, if available.
private func loadCachedRepoInfo(
    cache: HubCache,
    repo: Repo.ID,
    kind: Repo.Kind,
    commit: String
) -> RepoInfoForDownload? {
    let path = cache.metadataDirectory(repo: repo, kind: kind)
        .appendingPathComponent("\(commit).json")
    guard let data = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(RepoInfoForDownload.self, from: data)
}

/// Checks whether all files matching the given globs are present in the snapshot directory,
/// using cached repo info to know the complete file list for the commit.
///
/// Returns the snapshot path and the verified file entries if all matching files are
/// present, `nil` otherwise. Returning the entries lets callers report progress with the
/// actual byte total instead of a placeholder.
private func verifiedSnapshotPath(
    cache: HubCache,
    repo: Repo.ID,
    kind: Repo.Kind,
    commit: String,
    matching globs: [String]
) -> (snapshotPath: URL, entries: [Git.TreeEntry])? {
    let snapshotDir = cache.snapshotsDirectory(repo: repo, kind: kind)
        .appendingPathComponent(commit)

    guard
        let cachedInfo = loadCachedRepoInfo(
            cache: cache,
            repo: repo,
            kind: kind,
            commit: commit
        ), let siblings = cachedInfo.siblings
    else { return nil }

    let entries = siblings.filter { entry in
        guard !globs.isEmpty else { return true }
        return globs.contains { glob in
            fnmatch(glob, entry.path, 0) == 0
        }
    }

    let allPresent = entries.allSatisfy { entry in
        let path = snapshotDir.appendingPathComponent(entry.path).path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // Validate file size if known. Resolve symlinks first because
        // attributesOfItem returns the symlink's own size, not the target's.
        if let expectedSize = entry.size {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
                let actualSize = attrs[.size] as? Int,
                actualSize != expectedSize
            {
                return false
            }
        }
        return true
    }

    return allPresent ? (snapshotDir, entries) : nil
}

/// Repository info with commit hash and file list.
struct RepoInfoForDownload: Codable {
    let commitHash: String
    let siblings: [Git.TreeEntry]?
}

extension HubClient {
    /// Gets repository info including commit hash and file list with sizes in a single API call.
    /// Uses `filesMetadata=true` to include file sizes for size-weighted progress reporting.
    func getRepoInfo(for repo: Repo.ID, kind: Repo.Kind, revision: String) async throws -> RepoInfoForDownload {
        switch kind {
        case .model:
            let model = try await getModel(repo, revision: revision, filesMetadata: true)
            guard let sha = model.sha else {
                throw HubCacheError.unexpectedAPIResponse("Could not resolve revision '\(revision)' to commit hash")
            }
            let siblings = model.siblings?.map {
                Git.TreeEntry(path: $0.relativeFilename, type: .file, oid: nil, size: $0.size, lastCommit: nil)
            }
            return RepoInfoForDownload(commitHash: sha, siblings: siblings)
        case .dataset:
            let dataset = try await getDataset(repo, revision: revision, filesMetadata: true)
            guard let sha = dataset.sha else {
                throw HubCacheError.unexpectedAPIResponse("Could not resolve revision '\(revision)' to commit hash")
            }
            let siblings = dataset.siblings?.map {
                Git.TreeEntry(path: $0.relativeFilename, type: .file, oid: nil, size: $0.size, lastCommit: nil)
            }
            return RepoInfoForDownload(commitHash: sha, siblings: siblings)
        case .space:
            let space = try await getSpace(repo, revision: revision, filesMetadata: true)
            guard let sha = space.sha else {
                throw HubCacheError.unexpectedAPIResponse("Could not resolve revision '\(revision)' to commit hash")
            }
            let siblings = space.siblings?.map {
                Git.TreeEntry(path: $0.relativeFilename, type: .file, oid: nil, size: $0.size, lastCommit: nil)
            }
            return RepoInfoForDownload(commitHash: sha, siblings: siblings)
        }
    }
}

// MARK: - File Metadata

/// Metadata for a file fetched without following redirects.
/// Used to get headers from the HuggingFace response before redirect to CDN.
struct FileMetadata {
    /// The commit hash from the X-Repo-Commit header.
    let commitHash: String?
    /// The ETag for cache storage (X-Linked-Etag for xet files, ETag otherwise).
    /// This matches huggingface_hub's behavior for Python cache compatibility.
    let etag: String?
    /// The expected file size from Content-Length or X-Linked-Size.
    let size: Int?
}

extension HubClient {
    /// Fetches file metadata without following redirects to CDN.
    /// This allows us to get X-Repo-Commit and X-Linked-Etag from the HuggingFace response
    /// before the redirect to CDN (which doesn't have these headers).
    /// Follows same-host redirects (e.g., renamed repos) but blocks cross-host redirects (e.g., CDN).
    func fetchFileMetadata(url: URL) async throws -> FileMetadata {
        var request = try await httpClient.createRequest(.head, url: url)
        // Prevent gzip encoding so Content-Length reflects the actual file size.
        // Matches huggingface_hub's Accept-Encoding: identity on HEAD requests.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (_, response) = try await metadataSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return FileMetadata(commitHash: nil, etag: nil, size: nil)
        }

        // Use X-Linked-Etag if available (xet storage), otherwise fall back to ETag.
        // This matches huggingface_hub's behavior for Python cache compatibility.
        let linkedEtag = httpResponse.value(forHTTPHeaderField: "X-Linked-Etag")
        let etag = linkedEtag ?? httpResponse.value(forHTTPHeaderField: "ETag")
        let commitHash = httpResponse.value(forHTTPHeaderField: "X-Repo-Commit")
        let linkedSize = httpResponse.value(forHTTPHeaderField: "X-Linked-Size")
        // Only use Content-Length from successful responses. For blocked redirects
        // (cross-host), Content-Length is the redirect body size, not the file size.
        let contentLength: String? =
            if (200 ..< 300).contains(httpResponse.statusCode) {
                httpResponse.value(forHTTPHeaderField: "Content-Length")
            } else {
                nil
            }
        let size = (linkedSize ?? contentLength).flatMap(Int.init)

        return FileMetadata(
            commitHash: commitHash,
            etag: etag.map { HubCache.normalizeEtag($0) },
            size: size
        )
    }
}

/// URLSession delegate that follows relative redirects (same host) but blocks absolute redirects (different host).
/// This matches huggingface_hub's `_httpx_follow_relative_redirects` behavior.
/// - Relative redirects (e.g., renamed repos on same host) are followed automatically.
/// - Absolute redirects (e.g., to CDN) are blocked so we can capture X-Repo-Commit and X-Linked-Etag headers.
/// Safe to mark @unchecked Sendable: stateless singleton with no mutable state.
final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SameHostRedirectDelegate()
    private override init() { super.init() }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Follow relative redirects (same host) but block absolute redirects (different host)
        guard let originalHost = task.originalRequest?.url?.host,
            let newHost = request.url?.host
        else {
            completionHandler(nil)
            return
        }

        if originalHost == newHost {
            // Same host redirect (e.g., renamed repo) — follow it.
            // Preserve custom headers (e.g., Accept-Encoding, Authorization)
            // that URLSession drops when creating the redirect request.
            var redirectRequest = request
            if let originalHeaders = task.originalRequest?.allHTTPHeaderFields {
                for (key, value) in originalHeaders
                where redirectRequest.value(forHTTPHeaderField: key) == nil {
                    redirectRequest.setValue(value, forHTTPHeaderField: key)
                }
            }
            completionHandler(redirectRequest)
        } else {
            // Different host redirect (e.g., CDN) - block to capture headers
            completionHandler(nil)
        }
    }
}
