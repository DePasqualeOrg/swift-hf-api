#!/usr/bin/env bash
set -euo pipefail

# Regenerates the committed UniFFI Swift wrapper at
# `Sources/HFAPIFFI/Generated/HFAPIFFI.swift` from the current Rust
# source.
#
# This is the only command that should ever write to that committed file. CI
# and the release workflow only ever read it (the wrapper-drift check
# regenerates into a temp directory and `git diff --no-index` against the
# committed copy). Run this after touching `rust/src/` or `rust/uniffi.toml`,
# then commit the regenerated wrapper alongside the Rust changes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

bash "${SCRIPT_DIR}/build/build-uniffi-bindings.sh"

GENERATED_WRAPPER="${REPO_ROOT}/rust/target/uniffi-bindings/HFAPIFFI.swift"
COMMITTED_WRAPPER="${REPO_ROOT}/Sources/HFAPIFFI/Generated/HFAPIFFI.swift"

if [[ ! -f "${GENERATED_WRAPPER}" ]]; then
  echo "Expected generated wrapper at ${GENERATED_WRAPPER} but it does not exist." >&2
  exit 1
fi

mkdir -p "$(dirname "${COMMITTED_WRAPPER}")"

# Prepend `// swift-format-ignore-file` so the generated wrapper is exempt from
# the project's swift-format lint without us having to hand-edit thousands of
# lines. `.swift-format-ignore` files would be a cleaner mechanism but that
# support landed too recently to be in the swift-format that ships with the
# stable Swift toolchain we target.
# TODO: drop this prepend (and the corresponding block in
# `scripts/rust/check-wrapper-drift.sh`) and use a `.swift-format-ignore` file
# at the repo root once a swift-format release including
# apple/swift-format#1197 ships in our stable Swift toolchain.
{
    echo "// swift-format-ignore-file"
    cat "${GENERATED_WRAPPER}"
} > "${COMMITTED_WRAPPER}"

echo "Wrote ${COMMITTED_WRAPPER}"
