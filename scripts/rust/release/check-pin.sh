#!/usr/bin/env bash
# Verify rust/Pin.json matches the current Rust source tree.
#
# Recomputes the canonical source hash via scripts/rust/hash-source.sh and
# compares it against rust/Pin.json.source_hash_sha256. Also verifies
# hash_schema_version matches what this repo's tooling currently supports.
#
# Run in CI on every PR. On drift, the maintainer must cut a new Rust
# release with scripts/rust/release/cut-release.sh to refresh the pin.

set -euo pipefail

SUPPORTED_HASH_SCHEMA_VERSION=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PIN_FILE="${REPO_ROOT}/rust/Pin.json"
HASH_SCRIPT="${REPO_ROOT}/scripts/rust/hash-source.sh"

if [[ ! -f "${PIN_FILE}" ]]; then
    echo "rust/Pin.json is missing. The drift guard cannot run without a pin." >&2
    exit 1
fi

pin_schema_version="$(jq -r '.hash_schema_version' "${PIN_FILE}")"
pin_source_hash="$(jq -r '.source_hash_sha256' "${PIN_FILE}")"
pin_version="$(jq -r '.version' "${PIN_FILE}")"

if [[ "${pin_schema_version}" != "${SUPPORTED_HASH_SCHEMA_VERSION}" ]]; then
    cat >&2 <<EOF
rust/Pin.json.hash_schema_version is ${pin_schema_version}, but this repo's drift
guard supports ${SUPPORTED_HASH_SCHEMA_VERSION}. Cut a new release under the current
hash scheme:

    scripts/rust/release/cut-release.sh <new-version>
EOF
    exit 1
fi

actual_hash="$(bash "${HASH_SCRIPT}")"

if [[ "${actual_hash}" != "${pin_source_hash}" ]]; then
    cat >&2 <<EOF
Rust source has drifted from the pinned artifactbundle (hfapi-rust-${pin_version}).

    Pin.json.source_hash_sha256: ${pin_source_hash}
    Recomputed source hash:      ${actual_hash}

Before merging, cut a new Rust release on this branch so Pin.json matches
the source:

    scripts/rust/release/cut-release.sh <new-version>
EOF
    exit 1
fi

echo "Rust source hash matches rust/Pin.json (hfapi-rust-${pin_version})."
