import Foundation
import HFAPI
import MLXLMCommon

enum DownloaderBridgeError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository ID: '\(id)'. Expected format 'namespace/name'."
        }
    }
}

extension HubClient: Downloader {
    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw DownloaderBridgeError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"

        if !useLatest,
            let cached = resolveCachedSnapshot(
                repo: repoID,
                revision: revision,
                matching: patterns
            )
        {
            return cached
        }

        return try await downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}
