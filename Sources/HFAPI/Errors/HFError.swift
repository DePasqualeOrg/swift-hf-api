// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Snapshot of a failing HTTP response captured by the Rust crate.
///
/// Returned alongside several ``HFError`` cases so callers can read the request
/// id, error code, and best-effort server message for incident reports.
public struct HTTPErrorContext: Equatable, Hashable, Sendable {
    public let status: UInt16
    public let url: String
    public let requestID: String?
    public let errorCode: String?
    public let serverMessage: String?
    public let body: String

    init(_ dto: HttpErrorContextDto) {
        self.status = dto.status
        self.url = dto.url
        self.requestID = dto.requestId
        self.errorCode = dto.errorCode
        self.serverMessage = dto.serverMessage
        self.body = dto.body
    }
}

/// Kind of transport-level failure carried by ``HFError/request(message:url:kind:)``. Lets
/// callers drive retry-on-transient logic without string-matching the
/// underlying message.
public enum RequestErrorKind: Sendable, Hashable {
    /// Request didn't complete before the configured timeout.
    case timeout
    /// Couldn't reach the host (DNS, refused connection, network unreachable).
    case connect
    /// Response body parsing or decoding failed.
    case decode
    /// TLS / handshake-level failure.
    case tls
    /// Anything else.
    case other

    init(_ dto: RequestErrorKindDto) {
        self =
            switch dto {
            case .timeout: .timeout
            case .connect: .connect
            case .decode: .decode
            case .tls: .tls
            case .other: .other
            }
    }

    /// Whether the underlying failure looks like a transient network blip
    /// that's worth a retry. `timeout` and `connect` are transient;
    /// `decode`, `tls`, and `other` are not.
    public var isTransient: Bool {
        switch self {
        case .timeout, .connect: true
        case .decode, .tls, .other: false
        }
    }
}

/// Identifies which xet operation produced an ``HFError/xet(operation:message:)`` error.
///
/// Bucket-related xet failures (`bucketBatchDownload` on the FFI side) collapse
/// into ``other`` here: bucket APIs are intentionally not wrapped by this
/// library, so consumers cannot act on a bucket-specific failure differently
/// from any other xet failure.
public enum XetOperation: Sendable, Hashable {
    case session
    case upload
    case download
    case batchDownload
    case streamDownload
    case other

    init(_ dto: XetOperationDto) {
        self =
            switch dto {
            case .session: .session
            case .upload: .upload
            case .download: .download
            case .batchDownload: .batchDownload
            case .streamDownload: .streamDownload
            case .bucketBatchDownload, .other: .other
            }
    }
}

/// Errors raised by the Rust-backed Hugging Face Hub client.
///
/// Mirrors the Rust `HFErrorFFI` enum 1:1; the variant identity is preserved
/// so the Swift side can pattern-match on it (e.g., to retry on `.rateLimited`
/// after `retryAfter` seconds, or to surface `.repoNotFound` with the missing
/// `repoID` to the user).
public enum HFError: Error, Sendable, Equatable, Hashable {
    case http(context: HTTPErrorContext)
    case authRequired(context: HTTPErrorContext)
    case repoNotFound(repoID: String, context: HTTPErrorContext?)
    case revisionNotFound(repoID: String, revision: String, context: HTTPErrorContext?)
    case entryNotFound(path: String, repoID: String, context: HTTPErrorContext?)
    case forbidden(context: HTTPErrorContext)
    case conflict(context: HTTPErrorContext)
    case rateLimited(retryAfter: TimeInterval?, context: HTTPErrorContext)
    case localEntryNotFound(path: String)
    case cacheNotEnabled
    case cacheLockTimeout(path: String)
    case request(message: String, url: String?, kind: RequestErrorKind)
    case io(message: String)
    case json(message: String)
    case urlParse(message: String)
    case invalidParameter(message: String)
    case diffParse(message: String)
    case xet(operation: XetOperation, message: String)
    case malformedResponse(what: String, url: String?)
    case cancelled
    /// The dynamic token provider configured via ``Auth/provider(_:)-(_)``
    /// (or wrapped by `HFAPIHubAuth.OAuthClientFactory`) threw. The original
    /// error's
    /// `localizedDescription` is forwarded as `message`.
    ///
    /// For OAuth flows this typically means the refresh token is invalid
    /// or the keychain is inaccessible – the consumer should re-prompt
    /// the user for sign-in rather than retry the Hub request blindly.
    case tokenProviderFailed(message: String)
    case other(message: String)

    init(_ ffi: HfErrorFfi) {
        self =
            switch ffi {
            case .Http(let c):
                .http(context: HTTPErrorContext(c))
            case .AuthRequired(let c):
                .authRequired(context: HTTPErrorContext(c))
            case .RepoNotFound(let repoId, let c):
                .repoNotFound(repoID: repoId, context: c.map(HTTPErrorContext.init))
            case .RevisionNotFound(let repoId, let revision, let c):
                .revisionNotFound(repoID: repoId, revision: revision, context: c.map(HTTPErrorContext.init))
            case .EntryNotFound(let path, let repoId, let c):
                .entryNotFound(path: path, repoID: repoId, context: c.map(HTTPErrorContext.init))
            case .Forbidden(let c):
                .forbidden(context: HTTPErrorContext(c))
            case .Conflict(let c):
                .conflict(context: HTTPErrorContext(c))
            case .RateLimited(let retryAfterSeconds, let c):
                .rateLimited(
                    retryAfter: retryAfterSeconds.map { TimeInterval($0) },
                    context: HTTPErrorContext(c)
                )
            case .LocalEntryNotFound(let path):
                .localEntryNotFound(path: path)
            case .CacheNotEnabled:
                .cacheNotEnabled
            case .CacheLockTimeout(let path):
                .cacheLockTimeout(path: path)
            case .Request(let message, let url, let kind):
                .request(message: message, url: url, kind: RequestErrorKind(kind))
            case .Io(let message):
                .io(message: message)
            case .Json(let message):
                .json(message: message)
            case .Url(let message):
                .urlParse(message: message)
            case .InvalidParameter(let message):
                .invalidParameter(message: message)
            case .DiffParse(let message):
                .diffParse(message: message)
            case .Xet(let operation, let message):
                .xet(operation: XetOperation(operation), message: message)
            case .MalformedResponse(let what, let url):
                .malformedResponse(what: what, url: url)
            case .Cancelled:
                .cancelled
            case .TokenProviderFailed(let message):
                .tokenProviderFailed(message: message)
            case .Other(let message):
                .other(message: message)
            }
    }
}

extension HFError {
    /// Whether this error looks like a transient failure worth retrying.
    ///
    /// Transient cases: ``request(message:url:kind:)`` with a
    /// ``RequestErrorKind/isTransient`` kind (timeout / connect), and
    /// ``rateLimited(retryAfter:context:)`` (back off then retry).
    ///
    /// Everything else – including ``cancelled``, ``cacheLockTimeout(path:)``,
    /// auth failures, parse errors – returns `false`. Pattern-match on the
    /// specific variants if your retry policy needs finer-grained control.
    public var isTransient: Bool {
        switch self {
        case .request(_, _, let kind): kind.isTransient
        case .rateLimited: true
        default: false
        }
    }
}

extension HFError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let c):
            "HTTP error \(c.status): \(c.url)\(suffix(for: c))"
        case .authRequired(let c):
            "Authentication required: \(c.url)\(suffix(for: c))"
        case .repoNotFound(let id, _):
            "Repository not found: \(id)"
        case .revisionNotFound(let id, let rev, _):
            "Revision not found: \(rev) in \(id)"
        case .entryNotFound(let path, let id, _):
            "File not found: \(path) in \(id)"
        case .forbidden(let c):
            "Forbidden: \(c.url)\(suffix(for: c))"
        case .conflict(let c):
            "Conflict: \(c.body.isEmpty ? c.url : c.body)\(suffix(for: c))"
        case .rateLimited(let retryAfter, let c):
            "Rate limited: \(c.url)\(retryAfter.map { " (retry after \(Int($0))s)" } ?? "")\(suffix(for: c))"
        case .localEntryNotFound(let path):
            "File not found in local cache: \(path)"
        case .cacheNotEnabled:
            "Cache is not enabled – pass `cacheEnabled: true` to `HFClient`, or set `localDir:` on the download call"
        case .cacheLockTimeout(let path):
            "Cache lock timed out: \(path)"
        case .request(let message, let url, _):
            "HTTP request error: \(message)\(url.map { " (\($0))" } ?? "")"
        case .io(let message):
            "I/O error: \(message)"
        case .json(let message):
            "JSON error: \(message)"
        case .urlParse(let message):
            "URL parse error: \(message)"
        case .invalidParameter(let message):
            "Invalid parameter: \(message)"
        case .diffParse(let message):
            "Diff parse error: \(message)"
        case .xet(let operation, let message):
            "Xet \(operation) failed: \(message)"
        case .malformedResponse(let what, let url):
            "Hub response missing required data: \(what)\(url.map { " (\($0))" } ?? "")"
        case .cancelled:
            "Operation cancelled"
        case .tokenProviderFailed(let message):
            "Token provider failed: \(message)"
        case .other(let message):
            "Hub error: \(message)"
        }
    }

    private func suffix(for context: HTTPErrorContext) -> String {
        switch (context.requestID, context.errorCode) {
        case (let rid?, let code?): " (request_id=\(rid), error_code=\(code))"
        case (let rid?, nil): " (request_id=\(rid))"
        case (nil, let code?): " (error_code=\(code))"
        case (nil, nil): ""
        }
    }
}

/// Lift any thrown `HfErrorFfi` from an async `body` into the typed
/// ``HFError`` enum so consumers can pattern-match on a single error type.
/// Errors that aren't `HfErrorFfi` propagate unchanged.
///
/// Used by every internal `repoXxx` helper and every ``HFClient`` extension
/// method to keep the conversion in one place.
func mapHFError<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as HfErrorFfi {
        throw HFError(error)
    }
}
