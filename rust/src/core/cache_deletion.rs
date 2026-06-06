// Copyright © Anthony DePasquale

//! Cache deletion surface for the Swift `DeleteCacheStrategy` wrapper.
//!
//! The Rust `hf_hub::cache::DeleteCacheStrategy` carries `PathBuf` and
//! `HashSet<PathBuf>` fields and an `io::Error`-returning `execute` method.
//! UniFFI can't bridge those directly, so this module re-shapes them as
//! string-based records and provides two free functions:
//!
//! * `compute_delete_cache_strategy` — turn an existing
//!   `HFCacheInfoDTO` plus a set of commit hashes into the plan.
//! * `execute_delete_cache_strategy` — apply the plan, returning per-path
//!   tolerated failures.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use hf_hub::cache::{
    CachedFileInfo, CachedRepoInfo, CachedRevisionInfo, DeleteCacheStrategy, ExecuteResult,
    Failure, HFCacheInfo, PathKind,
};

use crate::core::dto::HFCacheInfoDTO;

/// FFI mirror of [`DeleteCacheStrategy`]. All path fields are absolute
/// filesystem paths encoded as strings; the Swift wrapper reconstructs `URL`
/// instances.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeleteCacheStrategyDTO {
    pub expected_freed_size: u64,
    pub blobs: Vec<String>,
    pub refs: Vec<String>,
    pub repos: Vec<String>,
    pub snapshots: Vec<String>,
    pub locks: Vec<String>,
    pub missing_revisions: Vec<String>,
}

/// FFI mirror of [`ExecuteResult`]. `failures` is a flat list of per-path
/// tolerated outcomes (`NotFound`, `PermissionDenied`); non-tolerated I/O
/// errors are surfaced as `Err(CacheDeletionErrorFFI::Io)` from
/// [`execute_delete_cache_strategy`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExecuteResultDTO {
    pub failures: Vec<FailureDTO>,
}

/// FFI mirror of [`Failure`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct FailureDTO {
    pub path: String,
    pub kind: PathKindDTO,
    pub message: String,
}

/// FFI mirror of [`PathKind`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PathKindDTO {
    Repo,
    Snapshot,
    Ref,
    Blob,
    Locks,
}

/// Errors surfaced from cache deletion that aren't covered by the per-path
/// failures list. Currently only non-tolerated I/O errors.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum CacheDeletionErrorFFI {
    #[error("I/O error during cache deletion: {message}")]
    Io { message: String },
}

/// Compute the deletion strategy without touching the filesystem.
///
/// The cache snapshot is provided as a DTO (typically the result of
/// `HFClient::scan_cache` round-tripped through the FFI) so the Swift
/// wrapper can compute the plan without holding a Rust handle.
#[uniffi::export]
pub fn compute_delete_cache_strategy(
    cache_info: HFCacheInfoDTO,
    commit_hashes: Vec<String>,
) -> DeleteCacheStrategyDTO {
    let rust_cache_info: HFCacheInfo = (&cache_info).into();
    let strategy = rust_cache_info.delete_revisions(&commit_hashes);
    strategy_to_dto(&strategy)
}

/// Apply the strategy to the filesystem.
///
/// Per-path tolerated outcomes (`NotFound`, `PermissionDenied`) populate
/// `ExecuteResultDTO::failures`; non-tolerated I/O errors propagate as
/// `Err`.
#[uniffi::export]
pub fn execute_delete_cache_strategy(
    strategy: DeleteCacheStrategyDTO,
) -> Result<ExecuteResultDTO, CacheDeletionErrorFFI> {
    let rust_strategy = dto_to_strategy(&strategy);
    match rust_strategy.execute() {
        Ok(result) => Ok(execute_result_to_dto(&result)),
        Err(err) => Err(CacheDeletionErrorFFI::Io {
            message: err.to_string(),
        }),
    }
}

fn strategy_to_dto(strategy: &DeleteCacheStrategy) -> DeleteCacheStrategyDTO {
    DeleteCacheStrategyDTO {
        expected_freed_size: strategy.expected_freed_size,
        blobs: paths_to_strings(strategy.blobs.iter()),
        refs: paths_to_strings(strategy.refs.iter()),
        repos: paths_to_strings(strategy.repos.iter()),
        snapshots: paths_to_strings(strategy.snapshots.iter()),
        locks: paths_to_strings(strategy.locks.iter()),
        missing_revisions: strategy.missing_revisions.clone(),
    }
}

fn dto_to_strategy(dto: &DeleteCacheStrategyDTO) -> DeleteCacheStrategy {
    DeleteCacheStrategy {
        expected_freed_size: dto.expected_freed_size,
        blobs: dto.blobs.iter().map(PathBuf::from).collect(),
        refs: dto.refs.iter().map(PathBuf::from).collect(),
        repos: dto.repos.iter().map(PathBuf::from).collect(),
        snapshots: dto.snapshots.iter().map(PathBuf::from).collect(),
        locks: dto.locks.iter().map(PathBuf::from).collect(),
        missing_revisions: dto.missing_revisions.clone(),
    }
}

fn execute_result_to_dto(result: &ExecuteResult) -> ExecuteResultDTO {
    ExecuteResultDTO {
        failures: result.failures.iter().map(failure_to_dto).collect(),
    }
}

fn failure_to_dto(failure: &Failure) -> FailureDTO {
    FailureDTO {
        path: failure.path.to_string_lossy().into_owned(),
        kind: path_kind_to_dto(failure.kind),
        message: failure.error.to_string(),
    }
}

fn path_kind_to_dto(kind: PathKind) -> PathKindDTO {
    match kind {
        PathKind::Repo => PathKindDTO::Repo,
        PathKind::Snapshot => PathKindDTO::Snapshot,
        PathKind::Ref => PathKindDTO::Ref,
        PathKind::Blob => PathKindDTO::Blob,
        PathKind::Locks => PathKindDTO::Locks,
    }
}

fn paths_to_strings<'a, I>(paths: I) -> Vec<String>
where
    I: Iterator<Item = &'a PathBuf>,
{
    paths.map(|p| p.to_string_lossy().into_owned()).collect()
}

// `HFCacheInfoDTO` → `HFCacheInfo` reconstruction. The algorithm only reads
// `cache_dir`, `repos`, `repo.repo_path`, `repo.revisions`, `repo.size_on_disk`,
// `revision.commit_hash`, `revision.snapshot_path`, `revision.refs`,
// `revision.files`, `file.blob_path`, and `file.size_on_disk`. The remaining
// fields are filled with reasonable defaults (`SystemTime::UNIX_EPOCH`,
// empty strings) — the algorithm does not consult them.
impl From<&HFCacheInfoDTO> for HFCacheInfo {
    fn from(dto: &HFCacheInfoDTO) -> Self {
        HFCacheInfo {
            cache_dir: PathBuf::from(&dto.cache_dir),
            repos: dto
                .repos
                .iter()
                .map(|r| CachedRepoInfo {
                    repo_id: r.repo_id.clone(),
                    repo_type: repo_type_to_static(&r.repo_type),
                    repo_path: PathBuf::from(&r.repo_path),
                    revisions: r
                        .revisions
                        .iter()
                        .map(|rev| CachedRevisionInfo {
                            commit_hash: rev.commit_hash.clone(),
                            snapshot_path: PathBuf::from(&rev.snapshot_path),
                            files: rev
                                .files
                                .iter()
                                .map(|f| CachedFileInfo {
                                    file_name: f.file_name.clone(),
                                    file_path: PathBuf::from(&f.file_path),
                                    blob_path: PathBuf::from(&f.blob_path),
                                    size_on_disk: f.size_on_disk,
                                    blob_last_accessed: unix_seconds_to_system_time(
                                        f.blob_last_accessed_secs,
                                    ),
                                    blob_last_modified: unix_seconds_to_system_time(
                                        f.blob_last_modified_secs,
                                    ),
                                })
                                .collect(),
                            size_on_disk: rev.size_on_disk,
                            refs: rev.refs.clone(),
                            last_modified: unix_seconds_to_system_time(rev.last_modified_secs),
                        })
                        .collect(),
                    nb_files: r.nb_files as usize,
                    size_on_disk: r.size_on_disk,
                    last_accessed: unix_seconds_to_system_time(r.last_accessed_secs),
                    last_modified: unix_seconds_to_system_time(r.last_modified_secs),
                })
                .collect(),
            size_on_disk: dto.size_on_disk,
            warnings: dto.warnings.clone(),
        }
    }
}

fn unix_seconds_to_system_time(secs: u64) -> SystemTime {
    UNIX_EPOCH + std::time::Duration::from_secs(secs)
}

/// Map the FFI `repo_type` string to one of the `&'static str` values the
/// Rust crate uses for the `CachedRepoInfo::repo_type` field. The algorithm
/// does not read this field, but it's part of the struct, so something has
/// to fill it.
fn repo_type_to_static(repo_type: &str) -> &'static str {
    match repo_type {
        "model" => "model",
        "dataset" => "dataset",
        "space" => "space",
        "kernel" => "kernel",
        // Unknown / forward-compat values flow through as `"unknown"`. The
        // deletion algorithm doesn't inspect this field, so the loss is
        // harmless.
        _ => "unknown",
    }
}
