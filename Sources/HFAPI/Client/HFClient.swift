// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI
import HFAPIShared

/// Async client for the Hugging Face Hub API. Backed by the Rust `hf-hub` crate.
///
/// ``HFClient`` is a thin facade over `HFClientFFI`. It is `Sendable` and cheap
/// to share across tasks – every Hub call clones an `Arc<HFClientInner>` on the
/// Rust side. The token resolution chain (`HF_TOKEN` → `HF_TOKEN_PATH` →
/// `$HF_HOME/token`) is fully delegated to Rust; cache-path resolution is
/// owned by Swift via ``CachePathResolver`` so the Apple sandbox-aware default
/// applies on Apple platforms.
///
/// ## Creating a client
///
/// ```swift
/// // Zero-config: reads HF_TOKEN/HF_ENDPOINT from the environment.
/// let client = try HFClient()
///
/// // Static token and custom endpoint:
/// let client = try HFClient(
///     endpoint: "https://huggingface.co",
///     auth: .token("hf_…")
/// )
///
/// // Dynamic token (e.g. OAuth refresh):
/// let client = try HFClient(auth: .provider {
///     try await authManager.validToken()
/// })
/// ```
public struct HFClient: Sendable {
    let ffi: HfClientFfi

    /// Hub base URL this client targets, with any trailing slash trimmed.
    public let endpoint: URL

    /// Local cache directory used for downloaded files.
    public let cacheDirectory: URL

    /// Whether the local file cache is enabled.
    public let isCacheEnabled: Bool

    /// `User-Agent` header value the underlying Rust client sends with
    /// every Hub request. `nil` means the default (`hf-hub/<version>`).
    public let userAgent: String?

    /// Builds a client.
    ///
    /// - Parameters:
    ///   - endpoint: Hub base URL. When `nil`, the Rust crate reads `HF_ENDPOINT`
    ///     and falls back to `https://huggingface.co`.
    ///   - auth: Authentication mode. Defaults to ``Auth/env``.
    ///   - userAgent: `User-Agent` header. Defaults to `hf-hub/<version>`.
    ///   - cacheDirectory: Local cache directory. When `nil`, resolves via
    ///     ``CachePathResolver`` (Apple sandbox-aware on Apple platforms).
    ///   - cacheEnabled: Whether the local file cache is enabled. Defaults to `true`.
    ///   - retryMaxAttempts: Maximum retry attempts after an initial failure.
    ///     Defaults to 3. Passed through to the Rust client unchanged – there
    ///     is no upper-bound clamp on either side, so very large values
    ///     drive proportionally long exponential-backoff loops on persistent
    ///     transient failures.
    ///   - retryBaseDelay: Base delay for exponential backoff between retries.
    /// - Throws: ``HFError/invalidParameter(message:)`` if the resolved
    ///   endpoint URL is malformed; other ``HFError`` variants are bubbled up
    ///   from the underlying Rust client.
    public init(
        endpoint: String? = nil,
        auth: Auth = .env,
        userAgent: String? = nil,
        cacheDirectory: URL? = nil,
        cacheEnabled: Bool? = nil,
        retryMaxAttempts: UInt32? = nil,
        retryBaseDelay: Duration? = nil
    ) throws {
        let resolvedCacheDir = cacheDirectory ?? CachePathResolver.resolve()

        if case .token(let value) = auth,
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw HFError.invalidParameter(
                message:
                    "Auth.token cannot be empty or whitespace-only; use Auth.unauthenticated to disable authentication"
            )
        }

        // `.env` resolves the wide six-source environment chain synchronously
        // here so the result is fixed for the client's lifetime. The Rust
        // crate's narrow built-in env resolution is bypassed; we always hand
        // it a concrete token (or `nil` for unauthenticated).
        let staticToken: String? =
            switch auth {
            case .token(let value): value
            case .env: resolveEnvironmentToken()
            case .unauthenticated: nil
            case .provider: nil
            }

        let retryBaseDelayMillis: UInt64?
        if let delay = retryBaseDelay {
            let (seconds, attoseconds) = delay.components
            guard seconds >= 0, attoseconds >= 0 else {
                throw HFError.invalidParameter(
                    message: "retryBaseDelay must be non-negative; got \(delay)"
                )
            }
            let millisFromSeconds = UInt64(seconds) * 1_000
            let millisFromAttos = UInt64(attoseconds / 1_000_000_000_000_000)
            retryBaseDelayMillis = millisFromSeconds + millisFromAttos
        } else {
            retryBaseDelayMillis = nil
        }

        let dto = HfClientOptionsDto(
            endpoint: endpoint,
            token: staticToken,
            userAgent: userAgent,
            cacheDir: resolvedCacheDir.path(percentEncoded: false),
            cacheEnabled: cacheEnabled,
            retryMaxAttempts: retryMaxAttempts,
            retryBaseDelayMillis: retryBaseDelayMillis
        )

        let ffi: HfClientFfi
        do {
            switch auth {
            case .env, .token, .unauthenticated:
                // The FFI constructor passes `disable_implicit_token: true`,
                // so `.unauthenticated` (sending nil) cannot fall back through
                // hf-hub's narrower env-token chain.
                ffi = try HfClientFfi(options: dto)
            case .provider(let closure):
                let adapter = TokenProviderAdapter(closure)
                ffi = try HfClientFfi.withTokenProvider(options: dto, provider: adapter)
            }
        } catch let error as HfErrorFfi {
            throw HFError(error)
        }

        self.ffi = ffi
        // The Rust client validates the endpoint at construction, so
        // `URL(string:)` cannot fail for any value the FFI accepted.
        self.endpoint = URL(string: ffi.endpoint())!
        self.cacheDirectory = URL(fileURLWithPath: ffi.cacheDir())
        self.isCacheEnabled = ffi.cacheEnabled()
        self.userAgent = userAgent
    }

    /// Returns a model-repository handle for `owner/name`.
    ///
    /// Cheap – clones the inner client. The handle is `Sendable` and stores
    /// just the kind tag plus the owner/name strings.
    public func model(owner: String, name: String) -> ModelRepository {
        ModelRepository(ffi: ffi.model(owner: owner, name: name))
    }

    /// Returns a model-repository handle for a validated ``RepositoryID``.
    public func model(_ id: RepositoryID) -> ModelRepository {
        model(owner: id.owner, name: id.name)
    }

    /// Returns a dataset-repository handle for `owner/name`.
    public func dataset(owner: String, name: String) -> DatasetRepository {
        DatasetRepository(ffi: ffi.dataset(owner: owner, name: name))
    }

    /// Returns a dataset-repository handle for a validated ``RepositoryID``.
    public func dataset(_ id: RepositoryID) -> DatasetRepository {
        dataset(owner: id.owner, name: id.name)
    }
}
