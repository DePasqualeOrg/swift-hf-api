// Copyright © Anthony DePasquale

//! FFI data-transfer objects for repository info responses.
//!
//! UniFFI cannot bridge `serde_json::Value`, so the rich JSON-typed fields on
//! `hf_hub::ModelInfo` (`card_data`, `config`, `gated`, `gguf`, `model_index`,
//! `resource_group`, `security_repo_status`, `widget_data`, `eval_results`,
//! `inference_provider_mapping`) are surfaced as JSON-encoded strings. Swift
//! consumers decode them with `JSONSerialization` or a strongly typed Codable
//! struct, depending on the field. Structured sub-records that have a fixed
//! schema (`siblings`, `safetensors`, `transformers_info`) are mapped 1:1.

use std::collections::HashMap;

use hf_hub::cache::{CachedFileInfo, CachedRepoInfo, CachedRevisionInfo, HFCacheInfo};
use hf_hub::repository::{
    BlobLfsInfo, BlobSecurityInfo, CommitAuthor, CommitInfo, DatasetInfo, FileMetadataInfo,
    GatedApprovalMode, GatedNotifications, GatedNotificationsMode, GitCommitInfo, GitRefInfo,
    GitRefs, GitStatus, HFFileDiff, InferenceProviderMapping, LastCommitInfo, ModelInfo,
    RepoSibling, RepoTreeEntry, RepoUrl, SafeTensorsInfo, TransformersInfo,
};
use hf_hub::users::{OrgMembership, User};
use serde_json::Value as JsonValue;
use std::time::{SystemTime, UNIX_EPOCH};

/// Slim DTO for `RepoSibling` – flat enough to cross the FFI without nested options.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RepoSiblingDTO {
    pub rfilename: String,
    pub size: Option<u64>,
    pub lfs: Option<BlobLfsInfoDTO>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BlobLfsInfoDTO {
    pub size: Option<u64>,
    pub sha256: Option<String>,
    pub pointer_size: Option<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SafeTensorsInfoDTO {
    pub parameters: HashMap<String, u64>,
    pub total: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TransformersInfoDTO {
    pub auto_model: String,
    pub custom_class: Option<String>,
    pub pipeline_tag: Option<String>,
    pub processor: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct InferenceProviderMappingDTO {
    pub provider: String,
    pub provider_id: String,
    pub status: String,
    pub task: String,
    pub adapter: Option<String>,
    pub adapter_weights_path: Option<String>,
    pub kind: Option<String>,
}

/// FFI mirror of [`hf_hub::ModelInfo`] with JSON-typed fields encoded as strings.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelInfoDTO {
    pub id: String,
    pub internal_id: Option<String>,
    pub author: Option<String>,
    pub base_models: Option<Vec<String>>,
    /// JSON-encoded model card metadata, when present.
    pub card_data_json: Option<String>,
    pub children_model_count: Option<u64>,
    /// JSON-encoded model configuration, when present.
    pub config_json: Option<String>,
    pub created_at: Option<String>,
    pub disabled: Option<bool>,
    pub downloads: Option<u64>,
    pub downloads_all_time: Option<u64>,
    /// JSON-encoded list of `EvalResultEntry`, when present.
    pub eval_results_json: Option<String>,
    /// JSON-encoded gated-access state. Either `false` (open) or `"auto"` / `"manual"`.
    pub gated_json: Option<String>,
    /// JSON-encoded GGUF metadata, when the repo contains GGUF files.
    pub gguf_json: Option<String>,
    pub inference: Option<String>,
    pub inference_provider_mapping: Option<Vec<InferenceProviderMappingDTO>>,
    pub last_modified: Option<String>,
    pub library_name: Option<String>,
    pub likes: Option<u64>,
    pub mask_token: Option<String>,
    /// JSON-encoded `model-index` benchmark entries.
    pub model_index_json: Option<String>,
    pub pipeline_tag: Option<String>,
    pub private: Option<bool>,
    /// JSON-encoded resource-group descriptor.
    pub resource_group_json: Option<String>,
    pub safetensors: Option<SafeTensorsInfoDTO>,
    /// JSON-encoded security-scan summary.
    pub security_repo_status_json: Option<String>,
    pub sha: Option<String>,
    pub siblings: Option<Vec<RepoSiblingDTO>>,
    pub spaces: Option<Vec<String>>,
    pub tags: Option<Vec<String>>,
    pub transformers_info: Option<TransformersInfoDTO>,
    pub trending_score: Option<f64>,
    pub used_storage: Option<u64>,
    /// JSON-encoded inference-widget configuration.
    pub widget_data_json: Option<String>,
}

/// Serialize a `serde_json::Value` to its canonical JSON string. Returns
/// `None` both for missing input and for serialization failure – the empty
/// string is reserved for "field present, value was `null`/empty", so we
/// can't use it as a failure sentinel without losing that distinction.
/// Serialization of an already-parsed `Value` only fails on map keys that
/// aren't strings, which `serde_json::Value` cannot represent – this is
/// effectively unreachable but we surface `None` instead of corrupting the
/// payload.
fn encode_json(value: Option<JsonValue>) -> Option<String> {
    value.and_then(|v| serde_json::to_string(&v).ok())
}

/// Same contract as [`encode_json`] but for typed `Vec<T>` payloads. `T` is
/// always a serializable struct in practice; failure is unreachable but we
/// return `None` rather than emit `""`.
fn encode_json_iter<T: serde::Serialize>(value: Option<Vec<T>>) -> Option<String> {
    value.and_then(|v| serde_json::to_string(&v).ok())
}

impl From<RepoSibling> for RepoSiblingDTO {
    fn from(s: RepoSibling) -> Self {
        Self {
            rfilename: s.rfilename,
            size: s.size,
            lfs: s.lfs.map(BlobLfsInfoDTO::from),
        }
    }
}

impl From<BlobLfsInfo> for BlobLfsInfoDTO {
    fn from(l: BlobLfsInfo) -> Self {
        Self {
            size: l.size,
            sha256: l.sha256,
            pointer_size: l.pointer_size,
        }
    }
}

impl From<SafeTensorsInfo> for SafeTensorsInfoDTO {
    fn from(s: SafeTensorsInfo) -> Self {
        Self {
            parameters: s.parameters,
            total: s.total,
        }
    }
}

impl From<TransformersInfo> for TransformersInfoDTO {
    fn from(t: TransformersInfo) -> Self {
        Self {
            auto_model: t.auto_model,
            custom_class: t.custom_class,
            pipeline_tag: t.pipeline_tag,
            processor: t.processor,
        }
    }
}

impl From<InferenceProviderMapping> for InferenceProviderMappingDTO {
    fn from(m: InferenceProviderMapping) -> Self {
        Self {
            provider: m.provider,
            provider_id: m.provider_id,
            status: m.status,
            task: m.task,
            adapter: m.adapter,
            adapter_weights_path: m.adapter_weights_path,
            kind: m.r#type,
        }
    }
}

/// FFI mirror of [`hf_hub::DatasetInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct DatasetInfoDTO {
    pub id: String,
    pub internal_id: Option<String>,
    pub author: Option<String>,
    pub sha: Option<String>,
    pub private: Option<bool>,
    /// JSON-encoded gated-access state. Either `false` (open) or `"auto"` / `"manual"`.
    pub gated_json: Option<String>,
    pub disabled: Option<bool>,
    pub downloads: Option<u64>,
    pub downloads_all_time: Option<u64>,
    pub likes: Option<u64>,
    pub tags: Option<Vec<String>>,
    pub created_at: Option<String>,
    pub last_modified: Option<String>,
    pub siblings: Option<Vec<RepoSiblingDTO>>,
    /// JSON-encoded dataset-card metadata.
    pub card_data_json: Option<String>,
    pub citation: Option<String>,
    pub paperswithcode_id: Option<String>,
    /// JSON-encoded resource-group descriptor.
    pub resource_group_json: Option<String>,
    pub trending_score: Option<f64>,
    pub description: Option<String>,
    pub used_storage: Option<u64>,
}

impl From<DatasetInfo> for DatasetInfoDTO {
    fn from(d: DatasetInfo) -> Self {
        Self {
            id: d.id,
            internal_id: d.internal_id,
            author: d.author,
            sha: d.sha,
            private: d.private,
            gated_json: encode_json(d.gated),
            disabled: d.disabled,
            downloads: d.downloads,
            downloads_all_time: d.downloads_all_time,
            likes: d.likes,
            tags: d.tags,
            created_at: d.created_at,
            last_modified: d.last_modified,
            siblings: d.siblings.map(|v| v.into_iter().map(Into::into).collect()),
            card_data_json: encode_json(d.card_data),
            citation: d.citation,
            paperswithcode_id: d.paperswithcode_id,
            resource_group_json: encode_json(d.resource_group),
            trending_score: d.trending_score,
            description: d.description,
            used_storage: d.used_storage,
        }
    }
}

impl From<ModelInfo> for ModelInfoDTO {
    fn from(m: ModelInfo) -> Self {
        Self {
            id: m.id,
            internal_id: m.internal_id,
            author: m.author,
            base_models: m.base_models,
            card_data_json: encode_json(m.card_data),
            children_model_count: m.children_model_count,
            config_json: encode_json(m.config),
            created_at: m.created_at,
            disabled: m.disabled,
            downloads: m.downloads,
            downloads_all_time: m.downloads_all_time,
            eval_results_json: encode_json_iter(m.eval_results),
            gated_json: encode_json(m.gated),
            gguf_json: encode_json(m.gguf),
            inference: m.inference,
            inference_provider_mapping: m
                .inference_provider_mapping
                .map(|v| v.into_iter().map(Into::into).collect()),
            last_modified: m.last_modified,
            library_name: m.library_name,
            likes: m.likes,
            mask_token: m.mask_token,
            model_index_json: encode_json(m.model_index),
            pipeline_tag: m.pipeline_tag,
            private: m.private,
            resource_group_json: encode_json(m.resource_group),
            safetensors: m.safetensors.map(SafeTensorsInfoDTO::from),
            security_repo_status_json: encode_json(m.security_repo_status),
            sha: m.sha,
            siblings: m.siblings.map(|v| v.into_iter().map(Into::into).collect()),
            spaces: m.spaces,
            tags: m.tags,
            transformers_info: m.transformers_info.map(TransformersInfoDTO::from),
            trending_score: m.trending_score,
            used_storage: m.used_storage,
            widget_data_json: encode_json(m.widget_data),
        }
    }
}

/// FFI mirror of [`hf_hub::repository::LastCommitInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct LastCommitInfoDTO {
    pub id: Option<String>,
    pub title: Option<String>,
    pub date: Option<String>,
}

impl From<LastCommitInfo> for LastCommitInfoDTO {
    fn from(c: LastCommitInfo) -> Self {
        Self {
            id: c.id,
            title: c.title,
            date: c.date,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::BlobSecurityInfo`]. The `av_scan` and
/// `pickle_import_scan` payloads are free-form JSON in the Hub response; the
/// FFI surfaces them as encoded strings.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BlobSecurityInfoDTO {
    pub status: String,
    pub av_scan_json: Option<String>,
    pub pickle_import_scan_json: Option<String>,
}

impl From<BlobSecurityInfo> for BlobSecurityInfoDTO {
    fn from(b: BlobSecurityInfo) -> Self {
        Self {
            status: b.status,
            av_scan_json: encode_json(b.av_scan),
            pickle_import_scan_json: encode_json(b.pickle_import_scan),
        }
    }
}

/// FFI mirror of [`hf_hub::repository::RepoTreeEntry`]. UniFFI flattens the
/// tagged enum into a Swift `enum` with associated values per variant.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum RepoTreeEntryDTO {
    File {
        oid: String,
        size: u64,
        path: String,
        lfs: Option<BlobLfsInfoDTO>,
        last_commit: Option<LastCommitInfoDTO>,
        xet_hash: Option<String>,
        security: Option<BlobSecurityInfoDTO>,
    },
    Directory {
        oid: String,
        path: String,
        last_commit: Option<LastCommitInfoDTO>,
    },
}

impl From<RepoTreeEntry> for RepoTreeEntryDTO {
    fn from(entry: RepoTreeEntry) -> Self {
        match entry {
            RepoTreeEntry::File {
                oid,
                size,
                path,
                lfs,
                last_commit,
                xet_hash,
                security,
            } => Self::File {
                oid,
                size,
                path,
                lfs: lfs.map(BlobLfsInfoDTO::from),
                last_commit: last_commit.map(LastCommitInfoDTO::from),
                xet_hash,
                security: security.map(BlobSecurityInfoDTO::from),
            },
            RepoTreeEntry::Directory {
                oid,
                path,
                last_commit,
            } => Self::Directory {
                oid,
                path,
                last_commit: last_commit.map(LastCommitInfoDTO::from),
            },
        }
    }
}

/// FFI mirror of [`hf_hub::users::OrgMembership`]. The lighter-weight shape
/// returned inside [`UserDTO::orgs`] for the authenticated caller.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OrgMembershipDTO {
    pub name: Option<String>,
    pub fullname: Option<String>,
    pub avatar_url: Option<String>,
}

impl From<OrgMembership> for OrgMembershipDTO {
    fn from(m: OrgMembership) -> Self {
        Self {
            name: m.name,
            fullname: m.fullname,
            avatar_url: m.avatar_url,
        }
    }
}

/// FFI mirror of [`hf_hub::users::User`]. Only [`username`](Self::username) is
/// guaranteed to be set; the remaining fields populate based on whether the
/// caller is looking at their own `whoami` response or another user's
/// publicly visible profile.
///
/// `Debug` is implemented manually below to redact the `email` field so any
/// `tracing` call that captures a `UserDTO` doesn't accidentally log PII.
#[derive(Clone, uniffi::Record)]
pub struct UserDTO {
    pub username: String,
    pub fullname: Option<String>,
    pub avatar_url: Option<String>,
    pub user_type: Option<String>,
    pub details: Option<String>,
    pub is_following: Option<bool>,
    pub is_pro: Option<bool>,
    pub num_models: Option<u64>,
    pub num_datasets: Option<u64>,
    pub num_spaces: Option<u64>,
    pub num_discussions: Option<u64>,
    pub num_papers: Option<u64>,
    pub num_upvotes: Option<u64>,
    pub num_likes: Option<u64>,
    pub num_following: Option<u64>,
    pub num_followers: Option<u64>,
    pub email: Option<String>,
    pub email_verified: Option<bool>,
    pub plan: Option<String>,
    pub can_pay: Option<bool>,
    pub orgs: Option<Vec<OrgMembershipDTO>>,
}

impl std::fmt::Debug for UserDTO {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UserDTO")
            .field("username", &self.username)
            .field("fullname", &self.fullname)
            .field("avatar_url", &self.avatar_url)
            .field("user_type", &self.user_type)
            .field("details", &self.details)
            .field("is_following", &self.is_following)
            .field("is_pro", &self.is_pro)
            .field("num_models", &self.num_models)
            .field("num_datasets", &self.num_datasets)
            .field("num_spaces", &self.num_spaces)
            .field("num_discussions", &self.num_discussions)
            .field("num_papers", &self.num_papers)
            .field("num_upvotes", &self.num_upvotes)
            .field("num_likes", &self.num_likes)
            .field("num_following", &self.num_following)
            .field("num_followers", &self.num_followers)
            .field("email", &self.email.as_ref().map(|_| "<redacted>"))
            .field("email_verified", &self.email_verified)
            .field("plan", &self.plan)
            .field("can_pay", &self.can_pay)
            .field("orgs", &self.orgs)
            .finish()
    }
}

impl From<User> for UserDTO {
    fn from(u: User) -> Self {
        Self {
            username: u.username,
            fullname: u.fullname,
            avatar_url: u.avatar_url,
            user_type: u.user_type,
            details: u.details,
            is_following: u.is_following,
            is_pro: u.is_pro,
            num_models: u.num_models,
            num_datasets: u.num_datasets,
            num_spaces: u.num_spaces,
            num_discussions: u.num_discussions,
            num_papers: u.num_papers,
            num_upvotes: u.num_upvotes,
            num_likes: u.num_likes,
            num_following: u.num_following,
            num_followers: u.num_followers,
            email: u.email,
            email_verified: u.email_verified,
            plan: u.plan,
            can_pay: u.can_pay,
            orgs: u.orgs.map(|v| v.into_iter().map(Into::into).collect()),
        }
    }
}

/// Convert a [`SystemTime`] to seconds since the Unix epoch, suitable for
/// FFI transport. Times older than 1970 (which should never appear in cache
/// metadata) collapse to 0.
fn system_time_to_unix_secs(t: SystemTime) -> u64 {
    t.duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// FFI mirror of [`hf_hub::cache::CachedFileInfo`].
///
/// The `file_path` and `blob_path` fields surface as strings; the Swift side
/// reconstructs `URL` instances. `blob_last_accessed_secs` and
/// `blob_last_modified_secs` are seconds since the Unix epoch.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CachedFileInfoDTO {
    pub file_name: String,
    pub file_path: String,
    pub blob_path: String,
    pub size_on_disk: u64,
    pub blob_last_accessed_secs: u64,
    pub blob_last_modified_secs: u64,
}

impl From<CachedFileInfo> for CachedFileInfoDTO {
    fn from(f: CachedFileInfo) -> Self {
        Self {
            file_name: f.file_name,
            file_path: f.file_path.to_string_lossy().into_owned(),
            blob_path: f.blob_path.to_string_lossy().into_owned(),
            size_on_disk: f.size_on_disk,
            blob_last_accessed_secs: system_time_to_unix_secs(f.blob_last_accessed),
            blob_last_modified_secs: system_time_to_unix_secs(f.blob_last_modified),
        }
    }
}

/// FFI mirror of [`hf_hub::cache::CachedRevisionInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct CachedRevisionInfoDTO {
    pub commit_hash: String,
    pub snapshot_path: String,
    pub files: Vec<CachedFileInfoDTO>,
    pub size_on_disk: u64,
    pub refs: Vec<String>,
    pub last_modified_secs: u64,
}

impl From<CachedRevisionInfo> for CachedRevisionInfoDTO {
    fn from(r: CachedRevisionInfo) -> Self {
        Self {
            commit_hash: r.commit_hash,
            snapshot_path: r.snapshot_path.to_string_lossy().into_owned(),
            files: r.files.into_iter().map(Into::into).collect(),
            size_on_disk: r.size_on_disk,
            refs: r.refs,
            last_modified_secs: system_time_to_unix_secs(r.last_modified),
        }
    }
}

/// FFI mirror of [`hf_hub::cache::CachedRepoInfo`]. The repo kind is surfaced
/// as a string ([`repo_type`]). The Swift wrapper translates this to a typed
/// `CachedRepoType` enum.
///
/// In practice values are `"model"` or `"dataset"` – the only kinds this
/// library supports – but the cache directory may contain entries written
/// by other tooling (the Python `huggingface_hub` CLI, for instance, can
/// stash `"space"` entries in the same tree). Those flow through the FFI
/// verbatim as strings rather than being dropped, so consumers can detect
/// them; the Swift `CachedRepoType` enum has a `.other(String)` case for
/// exactly this purpose.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CachedRepoInfoDTO {
    pub repo_id: String,
    pub repo_type: String,
    pub repo_path: String,
    pub revisions: Vec<CachedRevisionInfoDTO>,
    pub nb_files: u64,
    pub size_on_disk: u64,
    pub last_accessed_secs: u64,
    pub last_modified_secs: u64,
}

impl From<CachedRepoInfo> for CachedRepoInfoDTO {
    fn from(r: CachedRepoInfo) -> Self {
        Self {
            repo_id: r.repo_id,
            repo_type: r.repo_type.to_string(),
            repo_path: r.repo_path.to_string_lossy().into_owned(),
            revisions: r.revisions.into_iter().map(Into::into).collect(),
            nb_files: r.nb_files as u64,
            size_on_disk: r.size_on_disk,
            last_accessed_secs: system_time_to_unix_secs(r.last_accessed),
            last_modified_secs: system_time_to_unix_secs(r.last_modified),
        }
    }
}

/// FFI mirror of [`hf_hub::cache::HFCacheInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct HFCacheInfoDTO {
    pub cache_dir: String,
    pub repos: Vec<CachedRepoInfoDTO>,
    pub size_on_disk: u64,
    pub warnings: Vec<String>,
}

impl From<HFCacheInfo> for HFCacheInfoDTO {
    fn from(c: HFCacheInfo) -> Self {
        Self {
            cache_dir: c.cache_dir.to_string_lossy().into_owned(),
            repos: c.repos.into_iter().map(Into::into).collect(),
            size_on_disk: c.size_on_disk,
            warnings: c.warnings,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::CommitAuthor`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct CommitAuthorDTO {
    pub user: Option<String>,
    pub name: Option<String>,
    pub email: Option<String>,
}

impl From<CommitAuthor> for CommitAuthorDTO {
    fn from(a: CommitAuthor) -> Self {
        Self {
            user: a.user,
            name: a.name,
            email: a.email,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::GitCommitInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct GitCommitInfoDTO {
    pub id: String,
    pub authors: Vec<CommitAuthorDTO>,
    pub date: Option<String>,
    pub title: String,
    pub message: String,
    pub formatted_title: Option<String>,
    pub formatted_message: Option<String>,
    pub parents: Vec<String>,
}

impl From<GitCommitInfo> for GitCommitInfoDTO {
    fn from(c: GitCommitInfo) -> Self {
        Self {
            id: c.id,
            authors: c.authors.into_iter().map(Into::into).collect(),
            date: c.date,
            title: c.title,
            message: c.message,
            formatted_title: c.formatted_title,
            formatted_message: c.formatted_message,
            parents: c.parents,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::GitRefInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct GitRefInfoDTO {
    pub name: String,
    pub git_ref: String,
    pub target_commit: String,
}

impl From<GitRefInfo> for GitRefInfoDTO {
    fn from(r: GitRefInfo) -> Self {
        Self {
            name: r.name,
            git_ref: r.git_ref,
            target_commit: r.target_commit,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::GitRefs`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct GitRefsDTO {
    pub branches: Vec<GitRefInfoDTO>,
    pub tags: Vec<GitRefInfoDTO>,
    pub converts: Vec<GitRefInfoDTO>,
    pub pull_requests: Vec<GitRefInfoDTO>,
}

impl From<GitRefs> for GitRefsDTO {
    fn from(r: GitRefs) -> Self {
        Self {
            branches: r.branches.into_iter().map(Into::into).collect(),
            tags: r.tags.into_iter().map(Into::into).collect(),
            converts: r.converts.into_iter().map(Into::into).collect(),
            pull_requests: r.pull_requests.into_iter().map(Into::into).collect(),
        }
    }
}

/// FFI mirror of [`hf_hub::repository::GitStatus`]. Mirrors the single-letter
/// git raw diff status codes (`A`/`C`/`D`/`M`/`R`/`T`/`U`/`X`).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum GitStatusDTO {
    Addition,
    Copy,
    Deletion,
    Modification,
    FileTypeChange,
    Rename,
    Unknown,
    Unmerged,
}

impl From<GitStatus> for GitStatusDTO {
    fn from(s: GitStatus) -> Self {
        match s {
            GitStatus::Addition => Self::Addition,
            GitStatus::Copy => Self::Copy,
            GitStatus::Deletion => Self::Deletion,
            GitStatus::Modification => Self::Modification,
            GitStatus::FileTypeChange => Self::FileTypeChange,
            GitStatus::Rename => Self::Rename,
            GitStatus::Unknown => Self::Unknown,
            GitStatus::Unmerged => Self::Unmerged,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::HFFileDiff`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct HFFileDiffDTO {
    pub old_blob_id: String,
    pub new_blob_id: String,
    pub status: GitStatusDTO,
    pub file_path: String,
    pub new_file_path: Option<String>,
    pub is_binary: bool,
    pub new_file_size: u64,
}

impl From<HFFileDiff> for HFFileDiffDTO {
    fn from(d: HFFileDiff) -> Self {
        Self {
            old_blob_id: d.old_blob_id,
            new_blob_id: d.new_blob_id,
            status: d.status.into(),
            file_path: d.file_path,
            new_file_path: d.new_file_path,
            is_binary: d.is_binary,
            new_file_size: d.new_file_size,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::FileMetadataInfo`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct FileMetadataDTO {
    pub filename: String,
    pub etag: String,
    pub commit_hash: String,
    pub xet_hash: Option<String>,
    pub file_size: u64,
    pub location: Option<String>,
}

impl From<FileMetadataInfo> for FileMetadataDTO {
    fn from(f: FileMetadataInfo) -> Self {
        Self {
            filename: f.filename,
            etag: f.etag,
            commit_hash: f.commit_hash,
            xet_hash: f.xet_hash,
            file_size: f.file_size,
            location: f.location,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::CommitInfo`] – returned by the
/// upload and delete commit-creating endpoints.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CommitInfoDTO {
    pub commit_url: Option<String>,
    pub commit_message: Option<String>,
    pub commit_description: Option<String>,
    pub commit_oid: Option<String>,
    pub pr_url: Option<String>,
    pub pr_num: Option<u64>,
}

impl From<CommitInfo> for CommitInfoDTO {
    fn from(c: CommitInfo) -> Self {
        Self {
            commit_url: c.commit_url,
            commit_message: c.commit_message,
            commit_description: c.commit_description,
            commit_oid: c.commit_oid,
            pr_url: c.pr_url,
            pr_num: c.pr_num,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::RepoUrl`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct RepoUrlDTO {
    pub url: String,
}

impl From<RepoUrl> for RepoUrlDTO {
    fn from(r: RepoUrl) -> Self {
        Self { url: r.url }
    }
}

/// FFI mirror of [`hf_hub::repository::GatedApprovalMode`]. The upstream type
/// serializes [`Disabled`](GatedApprovalMode::Disabled) as `false` rather than
/// a string, but on the FFI surface we expose all three variants explicitly.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum GatedApprovalModeDTO {
    Disabled,
    Auto,
    Manual,
}

impl From<GatedApprovalModeDTO> for GatedApprovalMode {
    fn from(m: GatedApprovalModeDTO) -> Self {
        match m {
            GatedApprovalModeDTO::Disabled => GatedApprovalMode::Disabled,
            GatedApprovalModeDTO::Auto => GatedApprovalMode::Auto,
            GatedApprovalModeDTO::Manual => GatedApprovalMode::Manual,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::GatedNotificationsMode`].
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum GatedNotificationsModeDTO {
    Bulk,
    RealTime,
}

impl From<GatedNotificationsModeDTO> for GatedNotificationsMode {
    fn from(m: GatedNotificationsModeDTO) -> Self {
        match m {
            GatedNotificationsModeDTO::Bulk => GatedNotificationsMode::Bulk,
            GatedNotificationsModeDTO::RealTime => GatedNotificationsMode::RealTime,
        }
    }
}

/// FFI mirror of [`hf_hub::repository::GatedNotifications`]. Unlike the
/// upstream type, the email is captured as `Option<String>` and forwarded
/// straight through.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GatedNotificationsDTO {
    pub mode: GatedNotificationsModeDTO,
    pub email: Option<String>,
}

impl From<GatedNotificationsDTO> for GatedNotifications {
    fn from(g: GatedNotificationsDTO) -> Self {
        let mut out = GatedNotifications::new(g.mode.into());
        if let Some(email) = g.email {
            out = out.with_email(email);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::{encode_json, encode_json_iter, system_time_to_unix_secs};
    use serde_json::json;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn encode_json_none_returns_none() {
        assert!(encode_json(None).is_none());
    }

    #[test]
    fn encode_json_object_round_trips() {
        let value = json!({"key": "value", "n": 42});
        let encoded = encode_json(Some(value.clone())).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(parsed, value);
    }

    #[test]
    fn encode_json_bool_round_trips() {
        let encoded = encode_json(Some(json!(false))).unwrap();
        assert_eq!(encoded, "false");
    }

    #[test]
    fn encode_json_iter_typed_payload() {
        #[derive(serde::Serialize)]
        struct Entry {
            name: String,
        }
        let entries = vec![Entry { name: "a".into() }, Entry { name: "b".into() }];
        let encoded = encode_json_iter(Some(entries)).unwrap();
        assert_eq!(encoded, r#"[{"name":"a"},{"name":"b"}]"#);
    }

    #[test]
    fn encode_json_iter_none_returns_none() {
        let none: Option<Vec<u32>> = None;
        assert!(encode_json_iter(none).is_none());
    }

    #[test]
    fn system_time_post_epoch_returns_seconds() {
        let t = UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        assert_eq!(system_time_to_unix_secs(t), 1_700_000_000);
    }

    #[test]
    fn system_time_pre_epoch_collapses_to_zero() {
        // Times before 1970 are not expected in cache metadata, but the
        // helper guards against them. Verify the guard kicks in rather than
        // panicking on `duration_since`'s error path.
        let t = UNIX_EPOCH - Duration::from_secs(1);
        assert_eq!(system_time_to_unix_secs(t), 0);
    }
}
