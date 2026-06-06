#!/usr/bin/env bash
# Reject PRs targeting main whose rust/Pin.json.version is a semantic
# pre-release (i.e. contains a "-" suffix such as "0.4.0-rc.1").
#
# Pre-release pins are useful for iterating on the release workflow itself
# on a branch, but must not settle on main. Set the repository variable
# ALLOW_PRERELEASE_PIN=1 (e.g. on a release-prep branch's workflow run) to
# bypass this guard intentionally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PIN_FILE="${REPO_ROOT}/rust/Pin.json"

pin_version="$(jq -r '.version' "${PIN_FILE}")"

if [[ "${pin_version}" != *-* ]]; then
    echo "rust/Pin.json pins a stable version (${pin_version})."
    exit 0
fi

if [[ "${ALLOW_PRERELEASE_PIN:-}" == "1" ]]; then
    echo "rust/Pin.json pins pre-release ${pin_version}; allowed by ALLOW_PRERELEASE_PIN=1."
    exit 0
fi

cat >&2 <<EOF
rust/Pin.json pins pre-release ${pin_version}, but this PR targets main.
Cut a stable Rust release before merging:

    scripts/rust/release/cut-release.sh <stable-version>

To merge a pre-release pin intentionally (e.g. on a release-prep branch),
set the repository variable ALLOW_PRERELEASE_PIN=1.
EOF
exit 1
