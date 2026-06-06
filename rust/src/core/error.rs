// Copyright © Anthony DePasquale

//! FFI error model.
//!
//! `HFErrorFFI` mirrors the variants of `hf_hub::HFError` with structured fields
//! flattened for UniFFI: `Box<HttpErrorContext>` becomes `HttpErrorContextDTO`,
//! `std::time::Duration` becomes `u64` seconds, and the source errors of
//! transport-style variants (`Request`, `Io`, `Json`, `Url`, `DiffParse`, `Xet`)
//! are stringified into a single `message` field. The variant identity is
//! preserved so the Swift side can pattern-match on it.
//!
//! `HFError` is `#[non_exhaustive]` upstream; the FFI mirror is exhaustive
//! because the wildcard `Other` variant catches anything we have not mapped.

use hf_hub::{HFError, XetOperation};

// `hf_hub::error::HttpErrorContext` is reachable through `HFError` variants but
// is not re-exported from the crate root, so we cannot name the type here. The
// macro below pulls fields out of a `Box<HttpErrorContext>` via auto-deref —
// this lets every error variant build an [`HttpErrorContextDTO`] without
// stating the source type.
macro_rules! ctx_dto {
    ($c:expr) => {
        HttpErrorContextDTO {
            status: $c.status.as_u16(),
            url: $c.url.clone(),
            request_id: $c.request_id.clone(),
            error_code: $c.error_code.clone(),
            server_message: $c.server_message.clone(),
            body: $c.body.clone(),
        }
    };
}

/// Snapshot of a failing HTTP response.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HttpErrorContextDTO {
    pub status: u16,
    pub url: String,
    pub request_id: Option<String>,
    pub error_code: Option<String>,
    pub server_message: Option<String>,
    pub body: String,
}

/// Kind of transport-level failure on an [`HFErrorFFI::Request`]. Lets the
/// Swift consumer drive retry-on-transient logic without string-matching the
/// underlying reqwest message.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum RequestErrorKindDTO {
    /// Request didn't complete because the configured timeout elapsed.
    Timeout,
    /// Request couldn't reach the host (DNS, refused connection, network down).
    Connect,
    /// Response body parsing or decoding failed.
    Decode,
    /// TLS / handshake-level failure.
    Tls,
    /// Anything else – falls back here when the reqwest error doesn't match
    /// the more specific shapes.
    Other,
}

impl RequestErrorKindDTO {
    fn classify(err: &reqwest::Error) -> Self {
        if err.is_timeout() {
            return Self::Timeout;
        }
        // `is_decode()` is response-body parse failure; `is_body()` is
        // truncated/aborted body mid-stream. Both reach the consumer as
        // "the response didn't materialize as expected," so we collapse
        // them onto the same kind.
        if err.is_decode() || err.is_body() {
            return Self::Decode;
        }

        // `reqwest::Error` exposes no `is_tls()`, so substring-match the
        // rendered cause chain. The TLS check must come before
        // `is_connect()` — on Apple platforms native-tls renders
        // handshake failures (e.g., `record overflow` from
        // Security.framework) into a reqwest error whose `is_connect()`
        // returns `true`, which would short-circuit the classification
        // before the substring check ran.
        let rendered = format!("{err:?}");
        if Self::looks_like_tls(&rendered) {
            return Self::Tls;
        }

        if err.is_connect() {
            return Self::Connect;
        }

        Self::Other
    }

    /// Heuristic match for TLS-layer failures across both supported TLS
    /// backends. `native-tls` (Apple's Security.framework) renders errors
    /// like `record overflow` and `certificate verify failed`; `rustls`
    /// emits errors that explicitly mention `tls`/`TLS`. The patterns
    /// here cover both.
    ///
    /// The TLS-acronym tokens (`tls`/`Tls`/`TLS`) are matched as whole
    /// words rather than raw substrings so a URL or hostname containing
    /// the letters "tls" (e.g., a `tls-something.example.com` host name
    /// rendered inside a non-TLS-layer error) doesn't misclassify. The
    /// other tokens are descriptive English words that don't collide
    /// with URL components.
    fn looks_like_tls(rendered: &str) -> bool {
        // Whole-word match for the TLS acronym: bounded by non-alnum
        // characters on either side.
        let bytes = rendered.as_bytes();
        for needle in ["tls", "Tls", "TLS"] {
            let needle_bytes = needle.as_bytes();
            let mut start = 0;
            while let Some(pos) = rendered[start..].find(needle) {
                let abs = start + pos;
                let before_ok = abs == 0 || !is_word_char(bytes[abs - 1]);
                let after_idx = abs + needle_bytes.len();
                let after_ok = after_idx == bytes.len() || !is_word_char(bytes[after_idx]);
                if before_ok && after_ok {
                    return true;
                }
                start = abs + needle_bytes.len();
            }
        }
        const TLS_PHRASES: &[&str] =
            &["certificate", "Certificate", "handshake", "record overflow"];
        TLS_PHRASES.iter().any(|t| rendered.contains(t))
    }
}

fn is_word_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Identifies which xet operation produced an [`HFErrorFFI::Xet`] error.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum XetOperationDTO {
    Session,
    Upload,
    Download,
    BatchDownload,
    StreamDownload,
    BucketBatchDownload,
    Other,
}

impl From<XetOperation> for XetOperationDTO {
    fn from(op: XetOperation) -> Self {
        match op {
            XetOperation::Session => Self::Session,
            XetOperation::Upload => Self::Upload,
            XetOperation::Download => Self::Download,
            XetOperation::BatchDownload => Self::BatchDownload,
            XetOperation::StreamDownload => Self::StreamDownload,
            XetOperation::BucketBatchDownload => Self::BucketBatchDownload,
            _ => Self::Other,
        }
    }
}

/// FFI mirror of [`hf_hub::HFError`].
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HFErrorFFI {
    #[error("HTTP error: {} {}", context.status, context.url)]
    Http { context: HttpErrorContextDTO },

    #[error("Authentication required: {}", context.url)]
    AuthRequired { context: HttpErrorContextDTO },

    #[error("Repository not found: {repo_id}")]
    RepoNotFound {
        repo_id: String,
        context: Option<HttpErrorContextDTO>,
    },

    #[error("Revision not found: {revision} in {repo_id}")]
    RevisionNotFound {
        repo_id: String,
        revision: String,
        context: Option<HttpErrorContextDTO>,
    },

    #[error("Entry not found: {path} in {repo_id}")]
    EntryNotFound {
        path: String,
        repo_id: String,
        context: Option<HttpErrorContextDTO>,
    },

    #[error("Forbidden: {}", context.url)]
    Forbidden { context: HttpErrorContextDTO },

    #[error("Conflict: {}", context.body)]
    Conflict { context: HttpErrorContextDTO },

    #[error("Rate limited: {}", context.url)]
    RateLimited {
        retry_after_seconds: Option<u64>,
        context: HttpErrorContextDTO,
    },

    #[error("File not found in local cache: {path}")]
    LocalEntryNotFound { path: String },

    #[error(
        "Cache is not enabled – set cacheEnabled(true) on HFClientBuilder, or set localDir(...) on the download builder"
    )]
    CacheNotEnabled,

    #[error("Cache lock timed out: {path}")]
    CacheLockTimeout { path: String },

    #[error("HTTP request error: {message}")]
    Request {
        message: String,
        url: Option<String>,
        kind: RequestErrorKindDTO,
    },

    #[error("I/O error: {message}")]
    Io { message: String },

    #[error("JSON error: {message}")]
    Json { message: String },

    #[error("URL parse error: {message}")]
    Url { message: String },

    #[error("Invalid parameter: {message}")]
    InvalidParameter { message: String },

    #[error("Diff parse error: {message}")]
    DiffParse { message: String },

    #[error("Xet {operation:?} failed: {message}")]
    Xet {
        operation: XetOperationDTO,
        message: String,
    },

    #[error("Hub response missing required data: {what}")]
    MalformedResponse { what: String, url: Option<String> },

    /// User cancelled the operation via `Task.cancel()` or `OperationHandle.cancel()`.
    /// Synthesized at the FFI boundary; not a `hf_hub::HFError` variant.
    #[error("Operation cancelled")]
    Cancelled,

    /// Foreign token-provider callback failed. Synthesized at the FFI
    /// boundary when the Swift-side closure threw. The original Swift
    /// error's `localizedDescription` is forwarded as `message` so callers
    /// can surface it to the user verbatim.
    #[error("Token provider failed: {message}")]
    TokenProviderFailed { message: String },

    #[error("{message}")]
    Other { message: String },
}

impl From<HFError> for HFErrorFFI {
    #[deny(unreachable_patterns)]
    fn from(err: HFError) -> Self {
        match err {
            HFError::Http { context } => Self::Http {
                context: ctx_dto!(context),
            },
            HFError::AuthRequired { context } => Self::AuthRequired {
                context: ctx_dto!(context),
            },
            HFError::RepoNotFound { repo_id, context } => Self::RepoNotFound {
                repo_id,
                context: context.map(|c| ctx_dto!(c)),
            },
            HFError::RevisionNotFound {
                repo_id,
                revision,
                context,
            } => Self::RevisionNotFound {
                repo_id,
                revision,
                context: context.map(|c| ctx_dto!(c)),
            },
            HFError::EntryNotFound {
                path,
                repo_id,
                context,
            } => Self::EntryNotFound {
                path,
                repo_id,
                context: context.map(|c| ctx_dto!(c)),
            },
            // `BucketNotFound` is reachable from xet internals even though
            // the wrapper does not expose a bucket API. Route to `Other`
            // with a human-readable message rather than carrying a typed
            // variant that would suggest first-class bucket support.
            // Preserve every `HttpErrorContext` field (status, url,
            // request_id, error_code, server_message) in the rendered
            // message so users hitting xet bucket issues retain full
            // diagnostic detail for an incident report.
            HFError::BucketNotFound { bucket_id, context } => {
                let suffix = context
                    .as_ref()
                    .map(|c| {
                        let mut parts = vec![format!("{} {}", c.status.as_u16(), c.url)];
                        if let Some(rid) = &c.request_id {
                            parts.push(format!("request_id={rid}"));
                        }
                        if let Some(code) = &c.error_code {
                            parts.push(format!("error_code={code}"));
                        }
                        if let Some(msg) = &c.server_message {
                            parts.push(format!("server_message={msg}"));
                        }
                        format!(" ({})", parts.join(", "))
                    })
                    .unwrap_or_default();
                Self::Other {
                    message: format!("Bucket not found: {bucket_id}{suffix}"),
                }
            }
            HFError::Forbidden { context } => Self::Forbidden {
                context: ctx_dto!(context),
            },
            HFError::Conflict { context } => Self::Conflict {
                context: ctx_dto!(context),
            },
            HFError::RateLimited {
                retry_after,
                context,
            } => Self::RateLimited {
                retry_after_seconds: retry_after.map(|d| d.as_secs()),
                context: ctx_dto!(context),
            },
            HFError::LocalEntryNotFound { path } => Self::LocalEntryNotFound { path },
            HFError::CacheNotEnabled => Self::CacheNotEnabled,
            HFError::CacheLockTimeout { path } => Self::CacheLockTimeout {
                path: path.to_string_lossy().into_owned(),
            },
            HFError::Request { source, url } => Self::Request {
                message: source.to_string(),
                url,
                kind: RequestErrorKindDTO::classify(&source),
            },
            HFError::Io(e) => Self::Io {
                message: e.to_string(),
            },
            HFError::Json(e) => Self::Json {
                message: e.to_string(),
            },
            HFError::Url(e) => Self::Url {
                message: e.to_string(),
            },
            HFError::InvalidParameter(message) => Self::InvalidParameter { message },
            HFError::DiffParse(e) => Self::DiffParse {
                message: e.to_string(),
            },
            HFError::Xet { operation, source } => Self::Xet {
                operation: operation.into(),
                message: source.to_string(),
            },
            HFError::MalformedResponse { what, url } => Self::MalformedResponse { what, url },
            HFError::Other(message) => Self::Other { message },
            // `hf_hub::HFError` is `#[non_exhaustive]`; future variants land here.
            // Format the `Debug` form so a future variant doesn't lose
            // information at the FFI boundary.
            other => Self::Other {
                message: format!("Unknown hf_hub::HFError: {other:?}"),
            },
        }
    }
}

/// Convenience alias used by FFI methods.
pub type FFIResult<T> = Result<T, HFErrorFFI>;

#[cfg(test)]
mod tests {
    use super::*;

    // Pure-data HFError variants – the FFI mapping is deterministic and
    // doesn't require constructing an `HttpErrorContext` (which isn't
    // re-exported by hf_hub and so can't be named from here). The
    // http-context-bearing variants are exercised by the integration test
    // suite against the live Hub.

    #[test]
    fn from_local_entry_not_found_preserves_variant_and_path() {
        let err = HFError::LocalEntryNotFound {
            path: "models/foo/blobs/abc".to_string(),
        };
        match HFErrorFFI::from(err) {
            HFErrorFFI::LocalEntryNotFound { path } => {
                assert_eq!(path, "models/foo/blobs/abc");
            }
            other => panic!("expected LocalEntryNotFound, got {other:?}"),
        }
    }

    #[test]
    fn from_cache_not_enabled_preserves_variant() {
        match HFErrorFFI::from(HFError::CacheNotEnabled) {
            HFErrorFFI::CacheNotEnabled => {}
            other => panic!("expected CacheNotEnabled, got {other:?}"),
        }
    }

    #[test]
    fn from_cache_lock_timeout_preserves_path() {
        let err = HFError::CacheLockTimeout {
            path: std::path::PathBuf::from("/tmp/hf-cache/.lock"),
        };
        match HFErrorFFI::from(err) {
            HFErrorFFI::CacheLockTimeout { path } => {
                assert_eq!(path, "/tmp/hf-cache/.lock");
            }
            other => panic!("expected CacheLockTimeout, got {other:?}"),
        }
    }

    #[test]
    fn from_io_preserves_message() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "synthetic missing");
        let err = HFError::Io(io_err);
        match HFErrorFFI::from(err) {
            HFErrorFFI::Io { message } => {
                assert!(message.contains("synthetic missing"), "got: {message}");
            }
            other => panic!("expected Io, got {other:?}"),
        }
    }

    #[test]
    fn from_invalid_parameter_preserves_message() {
        let err = HFError::InvalidParameter("test message".to_string());
        match HFErrorFFI::from(err) {
            HFErrorFFI::InvalidParameter { message } => {
                assert_eq!(message, "test message");
            }
            other => panic!("expected InvalidParameter, got {other:?}"),
        }
    }

    #[test]
    fn from_malformed_response_preserves_what_and_url() {
        let err = HFError::MalformedResponse {
            what: "missing field foo".to_string(),
            url: Some("https://huggingface.co/api/x".to_string()),
        };
        match HFErrorFFI::from(err) {
            HFErrorFFI::MalformedResponse { what, url } => {
                assert_eq!(what, "missing field foo");
                assert_eq!(url.as_deref(), Some("https://huggingface.co/api/x"));
            }
            other => panic!("expected MalformedResponse, got {other:?}"),
        }
    }

    #[test]
    fn from_other_preserves_message() {
        let err = HFError::Other("anything".to_string());
        match HFErrorFFI::from(err) {
            HFErrorFFI::Other { message } => {
                assert_eq!(message, "anything");
            }
            other => panic!("expected Other, got {other:?}"),
        }
    }

    // The `RequestErrorKindDTO::classify` paths are exercised by inducing
    // real `reqwest::Error`s – the type has no public constructor, so we
    // hit a port that's known to refuse connections and verify the
    // resulting error classifies as `Connect`. The other variants
    // (`Timeout`, `Decode`, `Tls`) are harder to induce without setting up
    // an external server; the catch-all `Other` and the string-matched
    // `Tls` are the most fragile and rely on integration coverage today.

    #[tokio::test]
    async fn classify_recognizes_connect_failure() {
        // Port 1 on 127.0.0.1 is reserved and refuses every connection. A
        // bare `reqwest::get` against it will produce a connect-class error.
        let result = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(2))
            .build()
            .expect("build reqwest client")
            .get("http://127.0.0.1:1/")
            .send()
            .await;
        let err = result.expect_err("expected reqwest error against 127.0.0.1:1");
        let kind = RequestErrorKindDTO::classify(&err);
        // On macOS/Linux a connection-refused or unreachable maps to
        // `is_connect()` true. The classifier should put us in `Connect`.
        assert!(
            matches!(kind, RequestErrorKindDTO::Connect),
            "expected Connect, got {kind:?} (rendered: {err:?})"
        );
    }

    /// Guards the [`RequestErrorKindDTO::classify`] TLS bucket against
    /// reqwest debug-format drift. `reqwest::Error` exposes no `is_tls()`,
    /// so the classifier substring-matches `"tls"`/`"Tls"` in
    /// `format!("{err:?}")`. A future reqwest debug-format change would
    /// silently move TLS errors into `Other` – this test fires loudly
    /// instead.
    ///
    /// Strategy: bind a local TCP listener that accepts connections and
    /// sends back plaintext HTTP. An HTTPS request to it fails during
    /// the TLS handshake (the peer didn't speak TLS). native-tls reports
    /// this as a TLS-layer error; rustls reports it as a connect-phase
    /// error, so the assertion is gated per platform (see Cargo.toml's
    /// per-target TLS backend: native-tls on Apple, rustls on Linux).
    #[tokio::test]
    async fn classify_recognizes_tls_failure() {
        use tokio::io::AsyncWriteExt;
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local_addr");

        let server = tokio::spawn(async move {
            // Accept up to two attempts so the test doesn't hang if reqwest
            // retries internally. Each connection just writes a non-TLS
            // HTTP response so the client's TLS handshake fails parsing.
            for _ in 0..2 {
                if let Ok((mut stream, _)) = listener.accept().await {
                    let _ = stream.write_all(b"HTTP/1.0 200 OK\r\n\r\n").await;
                    let _ = stream.shutdown().await;
                }
            }
        });

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .expect("build reqwest client");
        let result = client.get(format!("https://{addr}/")).send().await;
        server.abort();

        let err = result.expect_err("expected an HTTPS request to a non-TLS peer to fail");
        let kind = RequestErrorKindDTO::classify(&err);
        // native-tls (Apple) classifies the non-TLS peer as a TLS error; rustls
        // (Linux) surfaces it as a connect-phase error (InvalidContentType), so
        // accept each backend's faithful surfacing.
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        assert!(
            matches!(kind, RequestErrorKindDTO::Tls),
            "expected Tls (native-tls), got {kind:?} (rendered: {err:?})"
        );
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        assert!(
            matches!(
                kind,
                RequestErrorKindDTO::Tls | RequestErrorKindDTO::Connect
            ),
            "expected Tls or Connect (rustls), got {kind:?} (rendered: {err:?})"
        );
    }
}
