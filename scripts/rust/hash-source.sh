#!/usr/bin/env bash
# Emit a canonical SHA-256 hash of the Rust source tree and related build
# inputs, as a single hex string to stdout.
#
# Used by the release workflow to pin the published artifactbundle manifest
# to the exact source state that produced it, and by the CI drift guard to
# detect when the pinned binary no longer matches the source tree.
#
# Inputs: all git-tracked files under the paths in ALLOWLIST below.
# Output: plain hex SHA-256 to stdout.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

ALLOWLIST=(
    rust/Cargo.lock
    rust/Cargo.toml
    rust/src
    rust/uniffi.toml
    rust-toolchain.toml
    Sources/HFAPIFFI/Generated
    scripts/rust/build
    scripts/rust/regenerate-wrapper.sh
    .github/workflows/rust-release.yml
)

# Fail loudly if an ALLOWLIST entry no longer exists. Without this check, a
# renamed or deleted path silently disappears from the hash input – the
# resulting hash changes (because fewer files contribute), but no operator
# can tell whether the change is intentional or accidental.
for entry in "${ALLOWLIST[@]}"; do
    if [[ ! -e "${entry}" ]]; then
        echo "hash-source.sh: ALLOWLIST entry missing: ${entry}" >&2
        echo "Update the ALLOWLIST in scripts/rust/hash-source.sh if this path was renamed or removed intentionally." >&2
        exit 1
    fi
done

(
    git ls-files -z "${ALLOWLIST[@]}" \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' path; do
            content_hash=$(shasum -a 256 "$path" | awk '{print $1}')
            printf '%s %s\0' "$content_hash" "$path"
        done
) | shasum -a 256 | awk '{print $1}'
