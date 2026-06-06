// Copyright © Anthony DePasquale

//! `HFClientFFI` – UniFFI Object wrapping `hf_hub::HFClient`.
//!
//! The wrapper supports two modes:
//!
//! * **Static-token mode** (default): the token comes from the
//!   [`HFClientOptionsDTO`] and never changes. Hub calls clone the inner
//!   `hf_hub::HFClient` (just an `Arc` bump) and run.
//! * **Dynamic-token mode**: a foreign [`FFITokenProvider`] is consulted
//!   before each Hub call. When the provider returns a value that differs
//!   from the last seen token, the inner client is rebuilt with the new
//!   token before the call runs. See [`HFClientFFI::active_client`] for the
//!   rotation logic.
//!
//! The Swift adapter is responsible for resolving the cache directory before
//! calling either constructor.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use futures::TryStreamExt;
use hf_hub::repository::{RepoTypeDataset, RepoTypeModel};
use hf_hub::{HFClient, HFClientBuilder};

use crate::core::auth::{DynTokenProvider, FFITokenProvider, TokenProviderErrorFFI};
use crate::core::cancellation::OperationHandle;
use crate::core::dto::{DatasetInfoDTO, HFCacheInfoDTO, ModelInfoDTO, RepoUrlDTO, UserDTO};
use crate::core::error::{FFIResult, HFErrorFFI};
use crate::core::repository::{HFRepositoryFFI, RepoTypeDTO, u64_to_usize_saturating};

/// Options forwarded to `HFClientBuilder`.
///
/// Every field is `Option<…>` – leaving a field as `None` defers to the
/// `hf_hub::HFClientBuilder` default (which itself reads env vars where
/// applicable). The Swift wrapper resolves `cache_dir` before calling so the
/// Apple sandbox-aware default takes effect on Apple platforms.
#[derive(Clone, Default, uniffi::Record)]
pub struct HFClientOptionsDTO {
    pub endpoint: Option<String>,
    pub token: Option<String>,
    pub user_agent: Option<String>,
    pub cache_dir: Option<String>,
    pub cache_enabled: Option<bool>,
    pub retry_max_attempts: Option<u32>,
    pub retry_base_delay_millis: Option<u64>,
}

// Manual `Debug` so any future `tracing::error!("opts: {:?}", options)` or
// panic that captures the struct doesn't leak the bearer token to logs.
// The presence flag is logged; the value never is.
impl std::fmt::Debug for HFClientOptionsDTO {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HFClientOptionsDTO")
            .field("endpoint", &self.endpoint)
            .field("token", &self.token.as_ref().map(|_| "<redacted>"))
            .field("user_agent", &self.user_agent)
            .field("cache_dir", &self.cache_dir)
            .field("cache_enabled", &self.cache_enabled)
            .field("retry_max_attempts", &self.retry_max_attempts)
            .field("retry_base_delay_millis", &self.retry_base_delay_millis)
            .finish()
    }
}

#[derive(uniffi::Object)]
pub struct HFClientFFI {
    /// Current `hf_hub::HFClient`. Static-token mode never replaces this; the
    /// dynamic-token mode swaps it whenever the foreign provider returns a
    /// new value.
    inner: tokio::sync::RwLock<HFClient>,

    /// Immutable Hub config – captured at construction and exposed by sync
    /// getters (`endpoint`, `cache_dir`, `cache_enabled`). These never change
    /// across token rotations.
    endpoint: String,
    cache_dir: PathBuf,
    cache_enabled: bool,

    /// Captures everything except the token so we can rebuild on rotation.
    /// In static-token mode the field is unused (the inner client never
    /// rebuilds), but we still store it for symmetry.
    options_template: HFClientOptionsDTO,

    /// Foreign callback for fetching the current token. `None` for
    /// static-token mode.
    token_provider: Option<DynTokenProvider>,

    /// Last token we built the inner client with. Compared against the
    /// provider's return value to decide whether a rebuild is required.
    /// Initialized to whatever token the constructor used.
    ///
    /// Held as a `Mutex` (not `RwLock`) so the entire
    /// fetch-compare-rebuild-swap sequence in `active_client()` runs as a
    /// single critical section. Without exclusive ownership across that
    /// span, two concurrent callers can both observe a stale value, both
    /// rebuild, and write `inner` in arbitrary order – leaving `inner`
    /// holding a token older than `last_token`.
    last_token: tokio::sync::Mutex<Option<String>>,
}

impl HFClientFFI {
    /// Build an `hf_hub::HFClient` from `options`, optionally setting a
    /// static `token`. Always sets `disable_implicit_token(true)` so the
    /// underlying crate never falls back to its narrower `HF_TOKEN`/
    /// `HF_TOKEN_PATH`/`$HF_HOME/token` chain: the Swift layer either
    /// resolved a token already (via `Auth.env`'s six-source chain) and
    /// passed it through `token`, or explicitly chose `Auth.unauthenticated`,
    /// or wired a dynamic provider that is the sole source of truth.
    fn build_client_with_token(
        options: &HFClientOptionsDTO,
        token: Option<String>,
    ) -> FFIResult<HFClient> {
        let mut builder = HFClientBuilder::new().disable_implicit_token(true);
        if let Some(endpoint) = &options.endpoint {
            builder = builder.endpoint(endpoint.clone());
        }
        if let Some(token) = token {
            builder = builder.token(token);
        }
        if let Some(ua) = &options.user_agent {
            builder = builder.user_agent(ua.clone());
        }
        if let Some(cache_dir) = &options.cache_dir {
            builder = builder.cache_dir(PathBuf::from(cache_dir));
        }
        if let Some(enabled) = options.cache_enabled {
            builder = builder.cache_enabled(enabled);
        }
        if let Some(n) = options.retry_max_attempts {
            builder = builder.retry_max_attempts(n as usize);
        }
        if let Some(ms) = options.retry_base_delay_millis {
            builder = builder.retry_base_delay(Duration::from_millis(ms));
        }
        builder.build().map_err(HFErrorFFI::from)
    }

    /// Returns a clone of the current `hf_hub::HFClient`, refreshing the
    /// inner client if a foreign token provider has rotated the token since
    /// the last call.
    ///
    /// Static-token mode (no provider configured) takes the read-lock fast
    /// path with no callback hop.
    ///
    /// Dynamic-token mode: invokes the provider, compares the result against
    /// `last_token`, rebuilds `hf_hub::HFClient` with the new token if
    /// they differ, then returns a clone of the (possibly new) inner.
    ///
    /// # Concurrency
    ///
    /// Provider invocations are serialized through `last_token`. The reason
    /// is subtle: an "outside-the-lock" fast path that fetched the provider's
    /// snapshot *before* acquiring the rotation mutex was racy. Two
    /// concurrent rotators could observe different snapshots (call them
    /// `B` and `C`, where the provider transitioned `B -> C` mid-flight);
    /// the one that acquired the lock second would then overwrite the
    /// freshly installed `C` with its stale `B`, leaving `last_token = B`
    /// while a concurrent reader had already returned a `C`-bound client.
    /// Querying the provider *under* the lock means whatever value the
    /// rotator installs is the provider's freshest reading at install time.
    ///
    /// **Provider latency budget**: every dynamic-token Hub call awaits the
    /// provider while holding `last_token`. A provider that takes hundreds
    /// of milliseconds (e.g., synchronous OAuth refresh hitting the
    /// network) serializes the whole client for that duration. The
    /// canonical OAuth provider should return an in-memory cached access
    /// token in microseconds and refresh in the background; the
    /// `HFAPIHubAuth.HubClientManager` bridge follows that shape via
    /// `OAuthManager.getValidToken()`. The lock is dropped before the
    /// `inner` read on the unchanged-token fast path so a slow read
    /// doesn't block subsequent rotators unnecessarily.
    ///
    /// TODO: replace rebuild with `hf_hub::HFClient::set_token()` when
    /// upstream exposes it. Today, hf-hub stores the token as a private
    /// static field on `HFClientInner`, so any token rotation requires
    /// constructing a new `HFClient` via the builder. See
    /// `docs/upstream-patches.md` ("Watching for upstream additions").
    pub(crate) async fn active_client(&self) -> FFIResult<HFClient> {
        let Some(provider) = self.token_provider.clone() else {
            return Ok(self.inner.read().await.clone());
        };

        // Acquire the rotation lock before invoking the provider so the
        // value we install is provider-fresh at install time (see the
        // # Concurrency note on the function). Propagate provider failures
        // as `HFErrorFFI::TokenProviderFailed` – the Swift consumer then
        // sees the OAuth-side error message instead of the generic Hub 401
        // the request would otherwise produce. `Ok(None)` is the explicit
        // "no token, run unauthenticated" path and stays distinct from the
        // error case.
        let mut last = self.last_token.lock().await;
        let new_token =
            provider
                .get_token()
                .await
                .map_err(|TokenProviderErrorFFI::Failed { message }| {
                    HFErrorFFI::TokenProviderFailed { message }
                })?;
        if *last == new_token {
            // Drop the rotation guard before reading `inner` so a slow
            // clone doesn't serialize subsequent rotators on the
            // unchanged-token fast path.
            drop(last);
            return Ok(self.inner.read().await.clone());
        }
        tracing::debug!(
            target = "hf_api_rust::client",
            has_token = new_token.is_some(),
            "rotating inner client: token changed",
        );
        // Dynamic-token mode: when `new_token` is `None`, we want an
        // explicitly-unauthenticated client – never the env fallback that
        // `HFClientBuilder` would otherwise consult. The flag is harmless
        // when `new_token` is `Some` because `.token(...)` always wins.
        let new_client = Self::build_client_with_token(&self.options_template, new_token.clone())?;
        *self.inner.write().await = new_client.clone();
        *last = new_token;
        Ok(new_client)
    }
}

#[uniffi::export]
impl HFClientFFI {
    /// Build an [`HFClient`] with the supplied static-token options.
    /// Equivalent to chaining every set field on `HFClientBuilder` and
    /// calling `.build()`. The token (if any) comes from
    /// [`HFClientOptionsDTO::token`] and never rotates.
    #[uniffi::constructor]
    pub fn new(options: HFClientOptionsDTO) -> FFIResult<Arc<Self>> {
        let initial_token = options.token.clone();
        // Disable hf-hub's implicit env-token chain (HF_TOKEN / HF_TOKEN_PATH
        // / $HF_HOME/token). The Swift layer's `Auth.env` already runs a
        // six-source resolution that is a superset of hf-hub's three-source
        // chain, and the result is handed in via `options.token`. Letting
        // hf-hub re-check its narrower chain on the static-token path would
        // be a no-op in practice (a strict subset) but would silently
        // override the Swift contract documented on `HFClient.swift` —
        // "When no token is found, the resulting client runs unauthenticated."
        let inner = Self::build_client_with_token(&options, initial_token.clone())?;
        let endpoint = inner.endpoint().to_string();
        let cache_dir = inner.cache_dir().to_path_buf();
        let cache_enabled = inner.cache_enabled();
        // Strip the token from the template so future rebuilds (if a
        // provider is later configured via `with_token_provider`) don't
        // accidentally fall back to a stale value.
        let mut template = options;
        template.token = None;
        Ok(Arc::new(Self {
            inner: tokio::sync::RwLock::new(inner),
            endpoint,
            cache_dir,
            cache_enabled,
            options_template: template,
            token_provider: None,
            last_token: tokio::sync::Mutex::new(initial_token),
        }))
    }

    /// Build an [`HFClient`] whose token is fetched dynamically from a
    /// foreign callback before each Hub call. `options.token` is ignored —
    /// pass it via the provider instead. The first Hub call invokes the
    /// provider and rebuilds the inner client with whatever token it
    /// returns.
    #[uniffi::constructor]
    pub fn with_token_provider(
        options: HFClientOptionsDTO,
        provider: Arc<dyn FFITokenProvider>,
    ) -> FFIResult<Arc<Self>> {
        // Build a token-less initial client so the immutable getters
        // (`endpoint`, `cache_dir`, `cache_enabled`) have valid values. The
        // first Hub call goes through `active_client()`, which will fetch
        // the real token and rebuild.
        //
        // Disable the implicit-token chain so the env-side token sources
        // (`HF_TOKEN` / `HF_TOKEN_PATH` / `$HF_HOME/token`) don't bleed
        // through when the foreign provider is in charge. The provider
        // becomes the only source of truth for the token; returning `None`
        // means "run unauthenticated" rather than "fall back to env".
        let mut template = options;
        template.token = None;
        let inner = Self::build_client_with_token(&template, None)?;
        let endpoint = inner.endpoint().to_string();
        let cache_dir = inner.cache_dir().to_path_buf();
        let cache_enabled = inner.cache_enabled();
        Ok(Arc::new(Self {
            inner: tokio::sync::RwLock::new(inner),
            endpoint,
            cache_dir,
            cache_enabled,
            options_template: template,
            token_provider: Some(provider),
            last_token: tokio::sync::Mutex::new(None),
        }))
    }

    /// Hub base URL this client targets, with any trailing slash trimmed.
    pub fn endpoint(&self) -> String {
        self.endpoint.clone()
    }

    /// Local cache directory used for downloaded files.
    pub fn cache_dir(&self) -> String {
        self.cache_dir.to_string_lossy().into_owned()
    }

    /// Whether the local file cache is enabled.
    pub fn cache_enabled(&self) -> bool {
        self.cache_enabled
    }

    /// Build a model-repository handle. The handle holds an `Arc<HFClientFFI>`
    /// so it observes future token rotations without rebuilding.
    pub fn model(self: Arc<Self>, owner: String, name: String) -> Arc<HFRepositoryFFI> {
        Arc::new(HFRepositoryFFI::new(self, RepoTypeDTO::Model, owner, name))
    }

    /// Build a dataset-repository handle.
    pub fn dataset(self: Arc<Self>, owner: String, name: String) -> Arc<HFRepositoryFFI> {
        Arc::new(HFRepositoryFFI::new(
            self,
            RepoTypeDTO::Dataset,
            owner,
            name,
        ))
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl HFClientFFI {
    /// List models on the Hub. The underlying `hf_hub` API returns a `Stream`;
    /// the FFI eagerly collects into a `Vec` because UniFFI cannot bridge
    /// streaming pagination directly. Pass `limit` to cap the total result
    /// count (also used as the server page size when below 1000).
    #[allow(clippy::too_many_arguments)]
    pub async fn list_models(
        &self,
        search: Option<String>,
        author: Option<String>,
        filter: Option<String>,
        sort: Option<String>,
        pipeline_tag: Option<String>,
        full: Option<bool>,
        card_data: Option<bool>,
        fetch_config: Option<bool>,
        limit: Option<u64>,
    ) -> FFIResult<Vec<ModelInfoDTO>> {
        let client = self.active_client().await?;
        let limit = clamp_eager_listing_limit(limit);
        let stream = client
            .list_models()
            .maybe_search(search)
            .maybe_author(author)
            .maybe_filter(filter)
            .maybe_sort(sort)
            .maybe_pipeline_tag(pipeline_tag)
            .maybe_full(full)
            .maybe_card_data(card_data)
            .maybe_fetch_config(fetch_config)
            .maybe_limit(Some(limit))
            .send()
            .map_err(HFErrorFFI::from)?;

        let entries: Vec<hf_hub::repository::ModelInfo> =
            stream.try_collect().await.map_err(HFErrorFFI::from)?;
        Ok(entries.into_iter().map(ModelInfoDTO::from).collect())
    }

    /// List datasets on the Hub. Eagerly collects the underlying stream into
    /// a `Vec`. See [`HFClientFFI::list_models`] for the same `limit` cap.
    pub async fn list_datasets(
        &self,
        search: Option<String>,
        author: Option<String>,
        filter: Option<String>,
        sort: Option<String>,
        full: Option<bool>,
        limit: Option<u64>,
    ) -> FFIResult<Vec<DatasetInfoDTO>> {
        let client = self.active_client().await?;
        let limit = clamp_eager_listing_limit(limit);
        let stream = client
            .list_datasets()
            .maybe_search(search)
            .maybe_author(author)
            .maybe_filter(filter)
            .maybe_sort(sort)
            .maybe_full(full)
            .maybe_limit(Some(limit))
            .send()
            .map_err(HFErrorFFI::from)?;

        let entries: Vec<hf_hub::repository::DatasetInfo> =
            stream.try_collect().await.map_err(HFErrorFFI::from)?;
        Ok(entries.into_iter().map(DatasetInfoDTO::from).collect())
    }

    /// Build a pull-based listing of Hub models. Returns a
    /// [`ModelInfoListingFFI`] handle whose `next()` method yields one
    /// entry per call – the Rust side polls hf-hub's `Stream` exactly
    /// once per pull, so memory is bounded by the channel's capacity-1
    /// buffer regardless of how slowly the Swift consumer iterates.
    ///
    /// Cancellation: the listing owns its own [`OperationHandle`]; call
    /// `cancel()` on the returned object, drop the Swift wrapper, or
    /// stop iterating – any of these closes the receiving channel and
    /// the drain task drops the underlying request at its next poll.
    /// There is no caller-supplied handle.
    #[allow(clippy::too_many_arguments)]
    pub async fn list_models_stream(
        &self,
        search: Option<String>,
        author: Option<String>,
        filter: Option<String>,
        sort: Option<String>,
        pipeline_tag: Option<String>,
        full: Option<bool>,
        card_data: Option<bool>,
        fetch_config: Option<bool>,
        limit: Option<u64>,
    ) -> FFIResult<Arc<ModelInfoListingFFI>> {
        let client = self.active_client().await?;
        let limit = limit.map(u64_to_usize_saturating);
        let handle = OperationHandle::new();
        let token = handle.token.clone();
        // Capacity 1: strict backpressure. The drain task can buffer at
        // most one item ahead of the consumer; further `tx.send().await`
        // blocks until the Swift side calls `next()`. The upstream Hub
        // page (50–1000 items) is already buffered inside hf-hub, so the
        // wrapper-side bound only governs how far past the consumer the
        // drain task can race.
        let (tx, rx) = tokio::sync::mpsc::channel::<FFIResult<ModelInfoDTO>>(1);
        tokio::spawn(async move {
            drain_model_listing(
                client,
                search,
                author,
                filter,
                sort,
                pipeline_tag,
                full,
                card_data,
                fetch_config,
                limit,
                tx,
                token,
            )
            .await;
        });
        Ok(Arc::new(ModelInfoListingFFI {
            rx: tokio::sync::Mutex::new(rx),
            handle,
        }))
    }

    /// Build a pull-based listing of Hub datasets. See
    /// [`list_models_stream`](Self::list_models_stream) for the
    /// cancellation and backpressure semantics.
    pub async fn list_datasets_stream(
        &self,
        search: Option<String>,
        author: Option<String>,
        filter: Option<String>,
        sort: Option<String>,
        full: Option<bool>,
        limit: Option<u64>,
    ) -> FFIResult<Arc<DatasetInfoListingFFI>> {
        let client = self.active_client().await?;
        let limit = limit.map(u64_to_usize_saturating);
        let handle = OperationHandle::new();
        let token = handle.token.clone();
        let (tx, rx) = tokio::sync::mpsc::channel::<FFIResult<DatasetInfoDTO>>(1);
        tokio::spawn(async move {
            drain_dataset_listing(client, search, author, filter, sort, full, limit, tx, token)
                .await;
        });
        Ok(Arc::new(DatasetInfoListingFFI {
            rx: tokio::sync::Mutex::new(rx),
            handle,
        }))
    }

    /// Fetch the profile of the user that owns the current token. Fails with
    /// `HFErrorFFI::AuthRequired` when no valid token is configured.
    pub async fn whoami(&self) -> FFIResult<UserDTO> {
        let client = self.active_client().await?;
        let user = client.whoami().send().await.map_err(HFErrorFFI::from)?;
        Ok(UserDTO::from(user))
    }

    /// Scan the configured cache directory and return a summary of every
    /// cached repository, revision, and file. If the cache directory does
    /// not exist, returns an `HFCacheInfoDTO` with no repos and zero size —
    /// not an error. Unreadable blobs and dangling snapshot pointers surface
    /// in [`HFCacheInfoDTO::warnings`] rather than failing the scan.
    pub async fn scan_cache(&self) -> FFIResult<HFCacheInfoDTO> {
        let client = self.active_client().await?;
        let info = client.scan_cache().send().await.map_err(HFErrorFFI::from)?;
        Ok(HFCacheInfoDTO::from(info))
    }

    /// Create a repository of the given kind. Mirrors `HFClient::create_repository`.
    /// Returns the canonical repository URL on success. With `exist_ok = true`
    /// a 409 from the Hub is swallowed and the repository URL is reconstructed
    /// locally – see the upstream method for details.
    pub async fn create_repository(
        &self,
        repo_id: String,
        kind: RepoTypeDTO,
        private: Option<bool>,
        exist_ok: bool,
        space_sdk: Option<String>,
    ) -> FFIResult<RepoUrlDTO> {
        let client = self.active_client().await?;
        let url = match kind {
            RepoTypeDTO::Model => {
                client
                    .create_repository()
                    .repo_id(repo_id)
                    .repo_type(RepoTypeModel)
                    .maybe_private(private)
                    .exist_ok(exist_ok)
                    .maybe_space_sdk(space_sdk)
                    .send()
                    .await
            }
            RepoTypeDTO::Dataset => {
                client
                    .create_repository()
                    .repo_id(repo_id)
                    .repo_type(RepoTypeDataset)
                    .maybe_private(private)
                    .exist_ok(exist_ok)
                    .maybe_space_sdk(space_sdk)
                    .send()
                    .await
            }
        }
        .map_err(HFErrorFFI::from)?;
        Ok(RepoUrlDTO::from(url))
    }

    /// Delete a repository of the given kind. Mirrors `HFClient::delete_repository`.
    /// With `missing_ok = true`, a 404 from the Hub returns successfully.
    pub async fn delete_repository(
        &self,
        repo_id: String,
        kind: RepoTypeDTO,
        missing_ok: bool,
    ) -> FFIResult<()> {
        let client = self.active_client().await?;
        match kind {
            RepoTypeDTO::Model => {
                client
                    .delete_repository()
                    .repo_id(repo_id)
                    .repo_type(RepoTypeModel)
                    .missing_ok(missing_ok)
                    .send()
                    .await
            }
            RepoTypeDTO::Dataset => {
                client
                    .delete_repository()
                    .repo_id(repo_id)
                    .repo_type(RepoTypeDataset)
                    .missing_ok(missing_ok)
                    .send()
                    .await
            }
        }
        .map_err(HFErrorFFI::from)
    }

    /// Move (rename) a repository. Mirrors `HFClient::move_repository`.
    /// Both `from_id` and `to_id` are full `"owner/name"` strings.
    pub async fn move_repository(
        &self,
        from_id: String,
        to_id: String,
        kind: RepoTypeDTO,
    ) -> FFIResult<RepoUrlDTO> {
        let client = self.active_client().await?;
        let url = match kind {
            RepoTypeDTO::Model => {
                client
                    .move_repository()
                    .from_id(from_id)
                    .to_id(to_id)
                    .repo_type(RepoTypeModel)
                    .send()
                    .await
            }
            RepoTypeDTO::Dataset => {
                client
                    .move_repository()
                    .from_id(from_id)
                    .to_id(to_id)
                    .repo_type(RepoTypeDataset)
                    .send()
                    .await
            }
        }
        .map_err(HFErrorFFI::from)?;
        Ok(RepoUrlDTO::from(url))
    }
}

/// Pull-based handle for a streaming model listing. Built by
/// [`HFClientFFI::list_models_stream`]. The Rust side runs a tokio task
/// that drives hf-hub's listing `Stream`; the task `await`s on a
/// capacity-1 `mpsc` channel, so the upstream is only polled when the
/// Swift consumer calls [`next`](Self::next).
///
/// Cancellation: dropping the `Arc` (the Swift wrapper releases its
/// reference) closes the receiver, which causes the next `tx.send()` in
/// the drain task to fail and the task to exit, dropping the in-flight
/// HTTP request. [`cancel`](Self::cancel) is the explicit version of the
/// same shutdown path.
#[derive(uniffi::Object)]
pub struct ModelInfoListingFFI {
    rx: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<FFIResult<ModelInfoDTO>>>,
    handle: Arc<OperationHandle>,
}

#[uniffi::export(async_runtime = "tokio")]
impl ModelInfoListingFFI {
    /// Pull the next entry, awaiting if necessary. Returns `Ok(None)`
    /// when the upstream stream is exhausted.
    pub async fn next(&self) -> FFIResult<Option<ModelInfoDTO>> {
        let mut rx = self.rx.lock().await;
        match rx.recv().await {
            Some(Ok(item)) => Ok(Some(item)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    /// Abort the underlying request. Idempotent; safe to call from
    /// multiple consumers and at any point during iteration.
    pub fn cancel(&self) {
        self.handle.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.handle.is_cancelled()
    }
}

/// Pull-based handle for a streaming dataset listing. Mirrors
/// [`ModelInfoListingFFI`].
#[derive(uniffi::Object)]
pub struct DatasetInfoListingFFI {
    rx: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<FFIResult<DatasetInfoDTO>>>,
    handle: Arc<OperationHandle>,
}

#[uniffi::export(async_runtime = "tokio")]
impl DatasetInfoListingFFI {
    pub async fn next(&self) -> FFIResult<Option<DatasetInfoDTO>> {
        let mut rx = self.rx.lock().await;
        match rx.recv().await {
            Some(Ok(item)) => Ok(Some(item)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    pub fn cancel(&self) {
        self.handle.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.handle.is_cancelled()
    }
}

/// Eager-listing safety cap. The Hub has hundreds of thousands of models;
/// `try_collect`-ing the full pagination stream into a single `Vec` is a
/// trivial way to OOM a host process. Default callers (limit unset) land
/// on 1000 entries (one Hub page). Callers requesting more are clamped to
/// 10_000 – beyond that, the streaming variants (`list_models_stream` /
/// `list_datasets_stream`) are the right tool.
const DEFAULT_EAGER_LISTING_LIMIT: usize = 1000;
const MAX_EAGER_LISTING_LIMIT: usize = 10_000;

fn clamp_eager_listing_limit(limit: Option<u64>) -> usize {
    limit
        .map(u64_to_usize_saturating)
        .unwrap_or(DEFAULT_EAGER_LISTING_LIMIT)
        .min(MAX_EAGER_LISTING_LIMIT)
}

/// Background drain task body for [`HFClientFFI::list_models_stream`].
/// Polls hf-hub's stream and forwards each entry through `tx`. The
/// channel's bounded capacity is what enforces backpressure: `tx.send`
/// awaits when the consumer hasn't pulled yet, so the upstream Hub
/// pagination only advances when the Swift iterator does.
#[allow(clippy::too_many_arguments)]
async fn drain_model_listing(
    client: HFClient,
    search: Option<String>,
    author: Option<String>,
    filter: Option<String>,
    sort: Option<String>,
    pipeline_tag: Option<String>,
    full: Option<bool>,
    card_data: Option<bool>,
    fetch_config: Option<bool>,
    limit: Option<usize>,
    tx: tokio::sync::mpsc::Sender<FFIResult<ModelInfoDTO>>,
    token: tokio_util::sync::CancellationToken,
) {
    use futures::stream::StreamExt;
    let stream = match client
        .list_models()
        .maybe_search(search)
        .maybe_author(author)
        .maybe_filter(filter)
        .maybe_sort(sort)
        .maybe_pipeline_tag(pipeline_tag)
        .maybe_full(full)
        .maybe_card_data(card_data)
        .maybe_fetch_config(fetch_config)
        .maybe_limit(limit)
        .send()
        .map_err(HFErrorFFI::from)
    {
        Ok(s) => s,
        Err(e) => {
            // Surface the builder-side error as the first (and only)
            // pull. Receiver might already be dropped; ignore the send
            // error in that case.
            let _ = tx.send(Err(e)).await;
            return;
        }
    };
    futures::pin_mut!(stream);
    loop {
        tokio::select! {
            biased;
            () = token.cancelled() => break,
            // `tx.closed()` resolves the moment the receiver is dropped, so
            // the drain task tears down at the next await boundary even if
            // the Swift consumer dropped the listing without calling
            // `cancel()`. Without this arm, cleanup waits until the next
            // `tx.send()` attempt, which can leave an in-flight HTTP page
            // request alive for seconds after the consumer is gone.
            () = tx.closed() => break,
            next = stream.next() => {
                let Some(result) = next else { break };
                let mapped = result.map(ModelInfoDTO::from).map_err(HFErrorFFI::from);
                if tx.send(mapped).await.is_err() {
                    break;
                }
            }
        }
    }
}

/// Background drain task body for [`HFClientFFI::list_datasets_stream`].
/// Mirrors [`drain_model_listing`].
#[allow(clippy::too_many_arguments)]
async fn drain_dataset_listing(
    client: HFClient,
    search: Option<String>,
    author: Option<String>,
    filter: Option<String>,
    sort: Option<String>,
    full: Option<bool>,
    limit: Option<usize>,
    tx: tokio::sync::mpsc::Sender<FFIResult<DatasetInfoDTO>>,
    token: tokio_util::sync::CancellationToken,
) {
    use futures::stream::StreamExt;
    let stream = match client
        .list_datasets()
        .maybe_search(search)
        .maybe_author(author)
        .maybe_filter(filter)
        .maybe_sort(sort)
        .maybe_full(full)
        .maybe_limit(limit)
        .send()
        .map_err(HFErrorFFI::from)
    {
        Ok(s) => s,
        Err(e) => {
            let _ = tx.send(Err(e)).await;
            return;
        }
    };
    futures::pin_mut!(stream);
    loop {
        tokio::select! {
            biased;
            () = token.cancelled() => break,
            () = tx.closed() => break,
            next = stream.next() => {
                let Some(result) = next else { break };
                let mapped = result.map(DatasetInfoDTO::from).map_err(HFErrorFFI::from);
                if tx.send(mapped).await.is_err() {
                    break;
                }
            }
        }
    }
}
