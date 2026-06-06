// Copyright © Anthony DePasquale

//! Repository-ID validation surface for the Swift `RepositoryID` value type.
//!
//! The Swift wrapper preserves its public `ValidationError` enum and continues
//! to throw at construction time; this module only routes the actual rule
//! check through `hf_hub::repository::validate_repo_id_segment` so the rules
//! stay in lockstep with the rest of the Rust crate (and, ultimately, with
//! `huggingface_hub`'s `REPO_ID_REGEX`).

use hf_hub::repository::{RepoIdValidationError, SegmentRole, validate_repo_id_segment};

/// FFI mirror of [`SegmentRole`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SegmentRoleDTO {
    Owner,
    Name,
}

impl From<SegmentRoleDTO> for SegmentRole {
    fn from(role: SegmentRoleDTO) -> Self {
        match role {
            SegmentRoleDTO::Owner => SegmentRole::Owner,
            SegmentRoleDTO::Name => SegmentRole::Name,
        }
    }
}

impl From<SegmentRole> for SegmentRoleDTO {
    fn from(role: SegmentRole) -> Self {
        match role {
            SegmentRole::Owner => SegmentRoleDTO::Owner,
            SegmentRole::Name => SegmentRoleDTO::Name,
        }
    }
}

/// FFI mirror of [`RepoIdValidationError`]. The role is carried on every
/// variant where it applies; `GitSuffix` is name-only and therefore carries
/// no role.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum RepoIdValidationErrorFFI {
    #[error("the {role:?} segment must not be empty")]
    Empty { role: SegmentRoleDTO },
    #[error("the {role:?} segment must be at most 96 characters (got {length})")]
    TooLong { role: SegmentRoleDTO, length: u32 },
    #[error("the {role:?} segment contains an invalid character: '{character}'")]
    InvalidCharacter {
        role: SegmentRoleDTO,
        character: String,
    },
    #[error("the {role:?} segment must not start or end with '.'")]
    LeadingOrTrailingDot { role: SegmentRoleDTO },
    #[error("the {role:?} segment must not start or end with '-'")]
    LeadingOrTrailingHyphen { role: SegmentRoleDTO },
    #[error("the {role:?} segment must not contain '--'")]
    DoubleHyphen { role: SegmentRoleDTO },
    #[error("the {role:?} segment must not contain '..'")]
    DoubleDot { role: SegmentRoleDTO },
    #[error("the name segment must not end with '.git'")]
    GitSuffix,
}

impl From<RepoIdValidationError> for RepoIdValidationErrorFFI {
    fn from(err: RepoIdValidationError) -> Self {
        match err {
            RepoIdValidationError::Empty { role } => Self::Empty { role: role.into() },
            RepoIdValidationError::TooLong { role, length } => Self::TooLong {
                role: role.into(),
                length: length as u32,
            },
            RepoIdValidationError::InvalidCharacter { role, character } => Self::InvalidCharacter {
                role: role.into(),
                character: character.to_string(),
            },
            RepoIdValidationError::LeadingOrTrailingDot { role } => {
                Self::LeadingOrTrailingDot { role: role.into() }
            }
            RepoIdValidationError::LeadingOrTrailingHyphen { role } => {
                Self::LeadingOrTrailingHyphen { role: role.into() }
            }
            RepoIdValidationError::DoubleHyphen { role } => {
                Self::DoubleHyphen { role: role.into() }
            }
            RepoIdValidationError::DoubleDot { role } => Self::DoubleDot { role: role.into() },
            RepoIdValidationError::GitSuffix => Self::GitSuffix,
        }
    }
}

/// Validate a single owner or name segment against the Hugging Face Hub naming
/// rules. Returns `Ok(())` if the segment is well-formed for the role,
/// otherwise the typed error.
#[uniffi::export]
pub fn validate_repo_id_segment_ffi(
    segment: String,
    role: SegmentRoleDTO,
) -> Result<(), RepoIdValidationErrorFFI> {
    validate_repo_id_segment(&segment, role.into()).map_err(Into::into)
}
