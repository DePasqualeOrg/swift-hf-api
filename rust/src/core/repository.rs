// Copyright © Anthony DePasquale

//! `HFRepositoryFFI` – a single UniFFI Object that erases the `RepoType<T>`
//! generic parameter behind a runtime [`RepoTypeDTO`] tag. UniFFI cannot
//! express generics; the Swift wrapper restores the compile-time distinction
//! by exposing different concrete types (`HFModelRepository`,
//! `HFDatasetRepository`, `HFSpaceRepository`, `HFKernelRepository`) that all
//! wrap a `HFRepositoryFFI` underneath. Per-kind methods (`info_model`,
//! `info_dataset`, …) check the runtime tag and return
//! `HFErrorFFI::InvalidParameter` if the Swift wrapper somehow routes a call
//! to the wrong handle – that path should be unreachable in practice.

use std::sync::Arc;

use futures::TryStreamExt;
use hf_hub::HFClient;
use hf_hub::repository::{AddSource, CommitOperation, RepoTreeEntry};

use crate::core::cancellation::{OperationHandle, run_cancellable};
use crate::core::client::HFClientFFI;
use crate::core::dto::{
    CommitInfoDTO, DatasetInfoDTO, FileMetadataDTO, GatedApprovalModeDTO, GatedNotificationsDTO,
    GitCommitInfoDTO, GitRefsDTO, HFFileDiffDTO, ModelInfoDTO, RepoTreeEntryDTO,
};
use crate::core::error::{FFIResult, HFErrorFFI};
use crate::core::progress::{
    DownloadProgressBridge, FFIByteChunkHandler, FFIDownloadProgressHandler,
    FFIUploadProgressHandler, UploadProgressBridge,
};

/// Dispatch a call against either a model or dataset repo handle. The body
/// expression is pasted into both match arms so each arm sees the correct
/// per-kind handle type (`client.model(...)` returns a different type than
/// `client.dataset(...)`). The expansion is mechanically equivalent to the
/// hand-written `match self.kind { Model => …, Dataset => … }` blocks it
/// replaces – every per-method call site needs the same two-arm dispatch,
/// so collapsing them here keeps the FFI surface from growing in lockstep
/// with the number of repo-kind variants.
///
/// Usage:
/// ```ignore
/// let result = dispatch_repo_kind!(
///     self.kind, client, self.owner.clone(), self.name.clone(),
///     |repo| repo.exists().send().await
/// );
/// ```
// `|$repo|` reads like a closure but is *macro-paste syntax*, not a closure.
// `$repo` becomes a let-binding in the body's lexical scope, so `$body` is an
// expression that uses `repo` directly – it is not invoked as a closure. The
// borrow checker therefore sees a straight let-binding plus expression, not a
// captured borrow, which is what makes the dispatch zero-overhead.
macro_rules! dispatch_repo_kind {
    ($kind:expr, $client:expr, $owner:expr, $name:expr, |$repo:ident| $body:expr) => {{
        let __owner = $owner;
        let __name = $name;
        match $kind {
            RepoTypeDTO::Model => {
                let $repo = $client.model(__owner, __name);
                $body
            }
            RepoTypeDTO::Dataset => {
                let $repo = $client.dataset(__owner, __name);
                $body
            }
        }
    }};
}

/// FFI mirror of [`hf_hub::repository::AddSource`]. Two variants:
/// - `Path`: the file is read from disk at commit time. Cheap to construct,
///   suitable for large payloads.
/// - `Bytes`: in-memory contents owned by the operation. Suitable for small
///   payloads or content generated at runtime.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum UploadSourceDTO {
    Path { path: String },
    Bytes { bytes: Vec<u8> },
}

impl From<UploadSourceDTO> for AddSource {
    fn from(s: UploadSourceDTO) -> Self {
        match s {
            UploadSourceDTO::Path { path } => AddSource::file(std::path::PathBuf::from(path)),
            UploadSourceDTO::Bytes { bytes } => AddSource::bytes(bytes),
        }
    }
}

/// FFI mirror of [`hf_hub::repository::CommitOperation`].
///
/// `Add` carries the destination path in the repo and the content source
/// (reusing [`UploadSourceDTO`] from `upload_file`); `Delete` carries the
/// repo-relative path to remove.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum CommitOperationDTO {
    Add {
        path_in_repo: String,
        source: UploadSourceDTO,
    },
    Delete {
        path_in_repo: String,
    },
}

impl From<CommitOperationDTO> for CommitOperation {
    fn from(op: CommitOperationDTO) -> Self {
        match op {
            CommitOperationDTO::Add {
                path_in_repo,
                source,
            } => CommitOperation::Add {
                path_in_repo,
                source: AddSource::from(source),
            },
            CommitOperationDTO::Delete { path_in_repo } => CommitOperation::Delete { path_in_repo },
        }
    }
}

/// Runtime tag identifying which repository kind a handle refers to.
///
/// Mirrors `hf_hub::RepoType`'s zero-sized markers. Stored on the FFI handle
/// so the Swift wrapper can construct each handle once and dispatch to the
/// appropriate per-kind FFI method below.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RepoTypeDTO {
    Model,
    Dataset,
}

#[derive(uniffi::Object)]
pub struct HFRepositoryFFI {
    /// Back-reference to the FFI client. Each operation calls
    /// [`HFClientFFI::active_client`] before running so foreign token-provider
    /// rotations propagate transparently.
    client_ffi: Arc<HFClientFFI>,
    kind: RepoTypeDTO,
    owner: String,
    name: String,
}

impl HFRepositoryFFI {
    pub(crate) fn new(
        client_ffi: Arc<HFClientFFI>,
        kind: RepoTypeDTO,
        owner: String,
        name: String,
    ) -> Self {
        Self {
            client_ffi,
            kind,
            owner,
            name,
        }
    }

    /// Convenience: get the current `hf_hub::HFClient` via the parent FFI
    /// client. Refreshes the inner client if a foreign token provider has
    /// rotated the token.
    async fn active_client(&self) -> FFIResult<HFClient> {
        self.client_ffi.active_client().await
    }
}

#[uniffi::export]
impl HFRepositoryFFI {
    pub fn kind(&self) -> RepoTypeDTO {
        self.kind
    }

    pub fn owner(&self) -> String {
        self.owner.clone()
    }

    pub fn name(&self) -> String {
        self.name.clone()
    }

    pub fn repo_id(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }
}

impl HFRepositoryFFI {
    /// Reject calls on the wrong kind handle. Used by `info_model` and
    /// `info_dataset`, which dispatch directly to `client.model()` /
    /// `client.dataset()` rather than going through the
    /// `dispatch_repo_kind!` macro: without this guard, calling
    /// `info_model` on a `Dataset` handle would silently query the model
    /// endpoint for that owner/name (which may legitimately exist as a
    /// different repository) instead of the dataset the caller meant.
    /// Every other per-kind method routes through `dispatch_repo_kind!`,
    /// which inspects `self.kind` and picks the right typed builder
    /// automatically.
    fn require_kind(&self, expected: RepoTypeDTO, method: &str) -> FFIResult<()> {
        if self.kind == expected {
            Ok(())
        } else {
            Err(HFErrorFFI::InvalidParameter {
                message: format!(
                    "{} called on {:?} handle for {}/{}",
                    method, self.kind, self.owner, self.name
                ),
            })
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl HFRepositoryFFI {
    /// Returns `true` if the repository exists. Dispatches to the
    /// per-`RepoType` `exists()` method on `hf_hub::HFRepository<T>`. A 404
    /// from the Hub returns `Ok(false)`; auth errors propagate as `HFErrorFFI`.
    pub async fn exists(&self) -> FFIResult<bool> {
        let client = self.active_client().await?;
        let result = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo.exists().send().await
        );
        result.map_err(HFErrorFFI::from)
    }

    /// Fetch [`ModelInfoDTO`] for a model repository.
    ///
    /// Returns `HFErrorFFI::InvalidParameter` if the handle was not built for
    /// a model. The Swift wrapper guarantees the right method by surfacing
    /// `HFModelRepository`, `HFDatasetRepository`, etc. as distinct types.
    pub async fn info_model(
        &self,
        revision: Option<String>,
        expand: Option<Vec<String>>,
    ) -> FFIResult<ModelInfoDTO> {
        // Check kind before pulling a fresh client – a misrouted call would
        // otherwise fire the dynamic-token provider for a request that's
        // about to be rejected.
        self.require_kind(RepoTypeDTO::Model, "info_model")?;
        let client = self.active_client().await?;

        let info = client
            .model(self.owner.clone(), self.name.clone())
            .info()
            .maybe_revision(revision)
            .maybe_expand(expand)
            .send()
            .await
            .map_err(HFErrorFFI::from)?;

        Ok(ModelInfoDTO::from(info))
    }

    /// Fetch [`DatasetInfoDTO`] for a dataset repository.
    pub async fn info_dataset(
        &self,
        revision: Option<String>,
        expand: Option<Vec<String>>,
    ) -> FFIResult<DatasetInfoDTO> {
        self.require_kind(RepoTypeDTO::Dataset, "info_dataset")?;
        let client = self.active_client().await?;

        let info = client
            .dataset(self.owner.clone(), self.name.clone())
            .info()
            .maybe_revision(revision)
            .maybe_expand(expand)
            .send()
            .await
            .map_err(HFErrorFFI::from)?;

        Ok(DatasetInfoDTO::from(info))
    }

    /// List files and directories at a revision. The underlying `hf_hub` API
    /// returns a `Stream`; the FFI eagerly collects into a `Vec` because UniFFI
    /// cannot express streaming pagination directly. The Swift wrapper can
    /// expose its own `AsyncSequence` over a sequence of `list_tree` calls if a
    /// laziness layer is needed in the future.
    pub async fn list_tree(
        &self,
        revision: Option<String>,
        recursive: bool,
        expand: bool,
        limit: Option<u64>,
    ) -> FFIResult<Vec<RepoTreeEntryDTO>> {
        let client = self.active_client().await?;
        let limit = limit.map(u64_to_usize_saturating);
        let entries: Vec<RepoTreeEntry> = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .list_tree()
                .maybe_revision(revision)
                .recursive(recursive)
                .expand(expand)
                .maybe_limit(limit)
                .send()
                .map_err(HFErrorFFI::from)?
                .try_collect()
                .await
                .map_err(HFErrorFFI::from)?
        );

        Ok(entries.into_iter().map(RepoTreeEntryDTO::from).collect())
    }

    /// Get info for the specified paths. Use this when the set of paths is
    /// known up front; it is cheaper than `list_tree` for targeted lookups.
    pub async fn get_paths_info(
        &self,
        paths: Vec<String>,
        revision: Option<String>,
    ) -> FFIResult<Vec<RepoTreeEntryDTO>> {
        let client = self.active_client().await?;
        let entries = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .get_paths_info()
                .paths(paths)
                .maybe_revision(revision)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)?;

        Ok(entries.into_iter().map(RepoTreeEntryDTO::from).collect())
    }

    /// Fetch metadata for a single file via a HEAD request on its resolve URL.
    /// Returns the resolved commit hash, ETag, file size, and Xet hash without
    /// downloading the contents.
    pub async fn get_file_metadata(
        &self,
        filepath: String,
        revision: Option<String>,
    ) -> FFIResult<FileMetadataDTO> {
        let client = self.active_client().await?;
        let info = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .get_file_metadata()
                .filepath(filepath)
                .maybe_revision(revision)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)?;

        Ok(FileMetadataDTO::from(info))
    }

    /// Stream commit history at a revision. The underlying `hf_hub` API
    /// returns a `Stream`; the FFI eagerly collects into a `Vec` because
    /// UniFFI cannot bridge streaming pagination.
    pub async fn list_commits(
        &self,
        revision: Option<String>,
        limit: Option<u64>,
    ) -> FFIResult<Vec<GitCommitInfoDTO>> {
        let client = self.active_client().await?;
        let limit = limit.map(u64_to_usize_saturating);
        let entries: Vec<hf_hub::repository::GitCommitInfo> = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .list_commits()
                .maybe_revision(revision)
                .maybe_limit(limit)
                .send()
                .map_err(HFErrorFFI::from)?
                .try_collect()
                .await
                .map_err(HFErrorFFI::from)?
        );

        Ok(entries.into_iter().map(GitCommitInfoDTO::from).collect())
    }

    /// Fetch all branches, tags, and optionally pull-request refs for the
    /// repository.
    pub async fn list_refs(&self, include_pull_requests: bool) -> FFIResult<GitRefsDTO> {
        let client = self.active_client().await?;
        let refs = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .list_refs()
                .include_pull_requests(include_pull_requests)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)?;

        Ok(GitRefsDTO::from(refs))
    }

    /// Fetch the Hub's non-raw compare payload as text. Use [`get_raw_diff`]
    /// for raw git-style diff text or [`get_raw_diff_stream`] for parsed
    /// per-file entries.
    pub async fn get_commit_diff(&self, compare: String) -> FFIResult<String> {
        let client = self.active_client().await?;
        let text = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo.get_commit_diff().compare(compare).send().await
        )
        .map_err(HFErrorFFI::from)?;

        Ok(text)
    }

    /// Fetch the raw diff payload between two revisions as a string.
    pub async fn get_raw_diff(&self, compare: String) -> FFIResult<String> {
        let client = self.active_client().await?;
        let text = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo.get_raw_diff().compare(compare).send().await
        )
        .map_err(HFErrorFFI::from)?;

        Ok(text)
    }

    /// Fetch the raw diff between two revisions as a parsed `Vec` of file
    /// entries. Eagerly drains the underlying `Stream` because UniFFI cannot
    /// bridge streaming pagination.
    pub async fn get_raw_diff_stream(&self, compare: String) -> FFIResult<Vec<HFFileDiffDTO>> {
        let client = self.active_client().await?;
        let entries: Vec<hf_hub::repository::HFFileDiff> = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .get_raw_diff_stream()
                .compare(compare)
                .send()
                .await
                .map_err(HFErrorFFI::from)?
                .try_collect()
                .await
                .map_err(HFErrorFFI::from)?
        );

        Ok(entries.into_iter().map(HFFileDiffDTO::from).collect())
    }

    /// Download a file from the repository into the local cache. Returns
    /// the on-disk path of the downloaded blob. Works for every
    /// [`RepoTypeDTO`] – `hf_hub::HFRepository<T>::download_file` is
    /// generic over `T: RepoType`.
    ///
    /// `handle`, when supplied, lets the caller fire `cancel()` independent of
    /// `Task.cancel()`. The operation also exits when the in-flight Rust
    /// future is dropped (either via `Task.cancel()` or via Swift consumer
    /// drop on the progress stream).
    ///
    /// `progress`, when supplied, receives [`DownloadEventDTO`] events on
    /// tokio worker threads. The Swift implementation must yield to a
    /// `Continuation` and return without blocking – see the migration doc
    /// for the threading and lifetime contract.
    #[allow(clippy::too_many_arguments)]
    pub async fn download_file_to_cache(
        &self,
        filename: String,
        revision: Option<String>,
        local_dir: Option<String>,
        force_download: bool,
        local_files_only: bool,
        handle: Option<Arc<OperationHandle>>,
        progress: Option<Arc<dyn FFIDownloadProgressHandler>>,
    ) -> FFIResult<String> {
        let client = self.active_client().await?;
        let progress = wrap_progress(progress);
        let local_dir = local_dir.map(std::path::PathBuf::from);

        let kind = self.kind;
        let owner = self.owner.clone();
        let name = self.name.clone();
        // `Box::pin` the future to keep its stack frame off the caller –
        // see the matching note in `upload_folder` for the dispatch-macro
        // expansion that drives the size.
        let download_future = Box::pin(async move {
            let result = dispatch_repo_kind!(kind, client, owner, name, |repo| repo
                .download_file()
                .filename(filename)
                .maybe_revision(revision)
                .maybe_local_dir(local_dir)
                .force_download(force_download)
                .local_files_only(local_files_only)
                .maybe_progress(progress)
                .send()
                .await);
            result
                .map(|path| path.to_string_lossy().into_owned())
                .map_err(HFErrorFFI::from)
        });

        // Cancellation contract is uniform across every long-running op –
        // see `cancellation::run_cancellable`. When the Swift Task is
        // dropped, UniFFI drops this future and `download_future` aborts
        // via reqwest/tokio I/O drop; the explicit `OperationHandle`
        // covers the AsyncStream `onTermination` consumer-drop case.
        run_cancellable(handle, download_future).await
    }

    /// Stream a file chunk-by-chunk via a foreign chunk handler. Returns the
    /// content length reported by the server.
    pub async fn download_file_stream(
        &self,
        filename: String,
        revision: Option<String>,
        handle: Option<Arc<OperationHandle>>,
        progress: Option<Arc<dyn FFIDownloadProgressHandler>>,
        chunks: Arc<dyn FFIByteChunkHandler>,
    ) -> FFIResult<Option<u64>> {
        let client = self.active_client().await?;
        let progress = wrap_progress(progress);

        let kind = self.kind;
        let owner = self.owner.clone();
        let name = self.name.clone();
        let drain_future = async move {
            use futures::stream::StreamExt;
            let (content_length, mut stream) =
                dispatch_repo_kind!(kind, client, owner, name, |repo| repo
                    .download_file_stream()
                    .filename(filename)
                    .maybe_revision(revision)
                    .maybe_progress(progress)
                    .send()
                    .await)
                .map_err(HFErrorFFI::from)?;

            while let Some(chunk) = stream.next().await {
                let chunk = chunk.map_err(HFErrorFFI::from)?;
                chunks.on_chunk(chunk.to_vec());
            }
            Ok(content_length)
        };

        run_cancellable(handle, drain_future).await
    }

    /// Download all selected files for a resolved revision. Reuses hf-hub's
    /// `snapshot_download` builder; returns the snapshot directory path.
    /// Works for every [`RepoTypeDTO`].
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_download(
        &self,
        revision: Option<String>,
        allow_patterns: Option<Vec<String>>,
        ignore_patterns: Option<Vec<String>>,
        local_dir: Option<String>,
        force_download: bool,
        local_files_only: bool,
        max_workers: Option<u32>,
        handle: Option<Arc<OperationHandle>>,
        progress: Option<Arc<dyn FFIDownloadProgressHandler>>,
    ) -> FFIResult<String> {
        let client = self.active_client().await?;
        let progress = wrap_progress(progress);
        let local_dir = local_dir.map(std::path::PathBuf::from);
        // `u32` always fits in `usize` on every supported target (32-bit
        // `usize` is itself 32 bits), so a plain `as` cast is correct here.
        let max_workers = max_workers.map(|n| n as usize);

        let kind = self.kind;
        let owner = self.owner.clone();
        let name = self.name.clone();
        let download_future = Box::pin(async move {
            let result = dispatch_repo_kind!(kind, client, owner, name, |repo| repo
                .snapshot_download()
                .maybe_revision(revision)
                .maybe_allow_patterns(allow_patterns)
                .maybe_ignore_patterns(ignore_patterns)
                .maybe_local_dir(local_dir)
                .force_download(force_download)
                .local_files_only(local_files_only)
                .maybe_max_workers(max_workers)
                .maybe_progress(progress)
                .send()
                .await);
            result
                .map(|path| path.to_string_lossy().into_owned())
                .map_err(HFErrorFFI::from)
        });

        run_cancellable(handle, download_future).await
    }

    /// Update repository settings. Mirrors `HFRepository::update_settings`,
    /// dispatched per-`RepoTypeDTO`. Each parameter is `Option<…>` – `None`
    /// leaves the corresponding setting untouched on the Hub.
    pub async fn update_settings(
        &self,
        private: Option<bool>,
        gated: Option<GatedApprovalModeDTO>,
        description: Option<String>,
        discussions_disabled: Option<bool>,
        gated_notifications: Option<GatedNotificationsDTO>,
    ) -> FFIResult<()> {
        let client = self.active_client().await?;
        let gated = gated.map(hf_hub::repository::GatedApprovalMode::from);
        let gated_notifications =
            gated_notifications.map(hf_hub::repository::GatedNotifications::from);
        dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .update_settings()
                .maybe_private(private)
                .maybe_gated(gated)
                .maybe_description(description)
                .maybe_discussions_disabled(discussions_disabled)
                .maybe_gated_notifications(gated_notifications)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)
    }

    /// Create a branch on this repository, optionally starting from a specific
    /// revision. Mirrors `HFRepository::create_branch`.
    pub async fn create_branch(&self, branch: String, revision: Option<String>) -> FFIResult<()> {
        let client = self.active_client().await?;
        dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .create_branch()
                .branch(branch)
                .maybe_revision(revision)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)
    }

    /// Delete a branch from this repository. Mirrors `HFRepository::delete_branch`.
    pub async fn delete_branch(&self, branch: String) -> FFIResult<()> {
        let client = self.active_client().await?;
        dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo.delete_branch().branch(branch).send().await
        )
        .map_err(HFErrorFFI::from)
    }

    /// Create a tag on this repository, optionally pinned to a specific
    /// revision and with an optional annotation message. Mirrors
    /// `HFRepository::create_tag`.
    pub async fn create_tag(
        &self,
        tag: String,
        revision: Option<String>,
        message: Option<String>,
    ) -> FFIResult<()> {
        let client = self.active_client().await?;
        dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .create_tag()
                .tag(tag)
                .maybe_revision(revision)
                .maybe_message(message)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)
    }

    /// Delete a file from this repository. Mirrors `HFRepository::delete_file`.
    /// Creates a single-op delete commit; returns the resulting `CommitInfo`.
    pub async fn delete_file(
        &self,
        path_in_repo: String,
        revision: Option<String>,
        commit_message: Option<String>,
        create_pr: bool,
    ) -> FFIResult<CommitInfoDTO> {
        let client = self.active_client().await?;
        let info = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .delete_file()
                .path_in_repo(path_in_repo)
                .maybe_revision(revision)
                .maybe_commit_message(commit_message)
                .create_pr(create_pr)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)?;
        Ok(CommitInfoDTO::from(info))
    }

    /// Delete every file under a folder path. Mirrors
    /// `HFRepository::delete_folder` – recursively lists the tree at
    /// `path_in_repo` and stages a delete operation per file in a single
    /// commit.
    pub async fn delete_folder(
        &self,
        path_in_repo: String,
        revision: Option<String>,
        commit_message: Option<String>,
        create_pr: bool,
    ) -> FFIResult<CommitInfoDTO> {
        let client = self.active_client().await?;
        let info = dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo
                .delete_folder()
                .path_in_repo(path_in_repo)
                .maybe_revision(revision)
                .maybe_commit_message(commit_message)
                .create_pr(create_pr)
                .send()
                .await
        )
        .map_err(HFErrorFFI::from)?;
        Ok(CommitInfoDTO::from(info))
    }

    /// Delete a tag from this repository. Mirrors `HFRepository::delete_tag`.
    pub async fn delete_tag(&self, tag: String) -> FFIResult<()> {
        let client = self.active_client().await?;
        dispatch_repo_kind!(
            self.kind,
            client,
            self.owner.clone(),
            self.name.clone(),
            |repo| repo.delete_tag().tag(tag).send().await
        )
        .map_err(HFErrorFFI::from)
    }

    /// Upload a single file to this repository in a one-op commit. Mirrors
    /// `HFRepository::upload_file`. The source is either a local file path
    /// or in-memory bytes via [`UploadSourceDTO`]. Optional `handle` enables
    /// foreign cancellation; optional `progress` receives `UploadEvent`s.
    #[allow(clippy::too_many_arguments)]
    pub async fn upload_file(
        &self,
        source: UploadSourceDTO,
        path_in_repo: String,
        revision: Option<String>,
        commit_message: Option<String>,
        commit_description: Option<String>,
        create_pr: bool,
        parent_commit: Option<String>,
        handle: Option<Arc<OperationHandle>>,
        progress: Option<Arc<dyn FFIUploadProgressHandler>>,
    ) -> FFIResult<CommitInfoDTO> {
        let client = self.active_client().await?;
        let source = AddSource::from(source);
        let progress = wrap_upload_progress(progress);
        let kind = self.kind;
        let owner = self.owner.clone();
        let name = self.name.clone();

        let upload_future = Box::pin(async move {
            let info = dispatch_repo_kind!(kind, client, owner, name, |repo| repo
                .upload_file()
                .source(source)
                .path_in_repo(path_in_repo)
                .maybe_revision(revision)
                .maybe_commit_message(commit_message)
                .maybe_commit_description(commit_description)
                .create_pr(create_pr)
                .maybe_parent_commit(parent_commit)
                .maybe_progress(progress)
                .send()
                .await)
            .map_err(HFErrorFFI::from)?;
            Ok(CommitInfoDTO::from(info))
        });

        run_cancellable(handle, upload_future).await
    }

    /// Recursively upload every file under a local folder in a single commit.
    /// Mirrors `HFRepository::upload_folder`. The optional `allow_patterns` /
    /// `ignore_patterns` globs are matched against each discovered file's path
    /// relative to `folder_path`. `delete_patterns` matches against existing
    /// remote paths relative to repo root.
    #[allow(clippy::too_many_arguments)]
    pub async fn upload_folder(
        &self,
        folder_path: String,
        path_in_repo: Option<String>,
        revision: Option<String>,
        commit_message: Option<String>,
        commit_description: Option<String>,
        create_pr: bool,
        allow_patterns: Option<Vec<String>>,
        ignore_patterns: Option<Vec<String>>,
        delete_patterns: Option<Vec<String>>,
        handle: Option<Arc<OperationHandle>>,
        progress: Option<Arc<dyn FFIUploadProgressHandler>>,
    ) -> FFIResult<CommitInfoDTO> {
        let client = self.active_client().await?;
        let folder_path = std::path::PathBuf::from(folder_path);
        let progress = wrap_upload_progress(progress);
        let kind = self.kind;
        let owner = self.owner.clone();
        let name = self.name.clone();

        // The `dispatch_repo_kind!` expansion inlines the full
        // upload-folder builder chain into both the Model and Dataset
        // arms, doubling the future's stack frame to ~58 KB.
        // `Box::pin` moves it to the heap so concurrent uploads don't pin
        // huge tokio-worker stack frames.
        let upload_future = Box::pin(async move {
            let info = dispatch_repo_kind!(kind, client, owner, name, |repo| repo
                .upload_folder()
                .folder_path(folder_path)
                .maybe_path_in_repo(path_in_repo)
                .maybe_revision(revision)
                .maybe_commit_message(commit_message)
                .maybe_commit_description(commit_description)
                .create_pr(create_pr)
                .maybe_allow_patterns(allow_patterns)
                .maybe_ignore_patterns(ignore_patterns)
                .maybe_delete_patterns(delete_patterns)
                .maybe_progress(progress)
                .send()
                .await)
            .map_err(HFErrorFFI::from)?;
            Ok(CommitInfoDTO::from(info))
        });

        run_cancellable(handle, upload_future).await
    }

    /// Lowest-level mutation primitive. Mirrors `HFRepository::create_commit`,
    /// taking an arbitrary mix of [`CommitOperationDTO::Add`] /
    /// [`CommitOperationDTO::Delete`] entries that land in a single commit.
    ///
    /// Use the higher-level convenience wrappers (`upload_file`,
    /// `upload_folder`, `delete_file`, `delete_folder`) for one-shot
    /// workflows. Use this when the operation set is genuinely heterogeneous.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_commit(
        &self,
        operations: Vec<CommitOperationDTO>,
        commit_message: String,
        commit_description: Option<String>,
        revision: Option<String>,
        create_pr: bool,
        parent_commit: Option<String>,
        handle: Option<Arc<OperationHandle>>,
        progress: Option<Arc<dyn FFIUploadProgressHandler>>,
    ) -> FFIResult<CommitInfoDTO> {
        let client = self.active_client().await?;
        let operations: Vec<CommitOperation> =
            operations.into_iter().map(CommitOperation::from).collect();
        let progress = wrap_upload_progress(progress);
        let kind = self.kind;
        let owner = self.owner.clone();
        let name = self.name.clone();

        // Same large-future concern as `upload_folder`: the macro inlines
        // a ~56 KB builder chain into both repo-kind arms. Heap-allocate.
        let commit_future = Box::pin(async move {
            let info = dispatch_repo_kind!(kind, client, owner, name, |repo| repo
                .create_commit()
                .operations(operations)
                .commit_message(commit_message)
                .maybe_commit_description(commit_description)
                .maybe_revision(revision)
                .create_pr(create_pr)
                .maybe_parent_commit(parent_commit)
                .maybe_progress(progress)
                .send()
                .await)
            .map_err(HFErrorFFI::from)?;
            Ok(CommitInfoDTO::from(info))
        });

        run_cancellable(handle, commit_future).await
    }
}

/// Wrap a foreign progress handler in the upstream `ProgressHandler` newtype.
fn wrap_progress(
    progress: Option<Arc<dyn FFIDownloadProgressHandler>>,
) -> Option<hf_hub::progress::Progress> {
    progress.map(|inner| {
        let bridge: Arc<dyn hf_hub::progress::ProgressHandler> =
            Arc::new(DownloadProgressBridge { inner });
        hf_hub::progress::Progress::from(bridge)
    })
}

/// Upload counterpart of [`wrap_progress`].
fn wrap_upload_progress(
    progress: Option<Arc<dyn FFIUploadProgressHandler>>,
) -> Option<hf_hub::progress::Progress> {
    progress.map(|inner| {
        let bridge: Arc<dyn hf_hub::progress::ProgressHandler> =
            Arc::new(UploadProgressBridge { inner });
        hf_hub::progress::Progress::from(bridge)
    })
}

/// Saturating `u64` → `usize` cast. On 64-bit targets the conversion is
/// always lossless; on 32-bit targets (Apple Watch's armv7k) a value above
/// `usize::MAX` saturates rather than truncating, which keeps consumers
/// who pass an upper-bound limit from silently receiving "no results"
/// when they meant "as many as possible".
pub(crate) fn u64_to_usize_saturating(value: u64) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}
