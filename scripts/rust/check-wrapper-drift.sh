#!/usr/bin/env bash
# Verify that the bindgen-derived artifacts match the current Rust source.
#
# Always checks:
#   - Committed UniFFI Swift wrapper at
#     Sources/HFAPIFFI/Generated/HFAPIFFI.swift matches what the
#     bindgen would emit for the current Rust source.
#
# Additionally, when either Apple- or Linux-build staging directory already
# exists at rust/target/apple-build/ or rust/target/linux-build/ (because
# the release workflow or PR CI just ran the corresponding build script),
# this script also diffs the staged C header and modulemap against a fresh
# bindgen run. That guards against the staged bundle picking up an edited
# or stale header even though the wrapper itself is in sync.
#
# The bindgen-only build (host static library + bindgen binary, no
# per-target matrix or artifactbundle assembly) is fast enough to run as
# a PR CI gate. On drift, the script fails with instructions to run
# scripts/rust/regenerate-wrapper.sh and rebuild the affected slices.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

bash "${SCRIPT_DIR}/build/build-uniffi-bindings.sh"

GENERATED_WRAPPER="${REPO_ROOT}/rust/target/uniffi-bindings/HFAPIFFI.swift"
GENERATED_HEADER="${REPO_ROOT}/rust/target/uniffi-bindings/HFAPIRust.h"
GENERATED_MODULEMAP="${REPO_ROOT}/rust/target/uniffi-bindings/module.modulemap"

COMMITTED_WRAPPER="${REPO_ROOT}/Sources/HFAPIFFI/Generated/HFAPIFFI.swift"

APPLE_BUILD_DIR="${REPO_ROOT}/rust/target/apple-build"
LINUX_BUILD_DIR="${REPO_ROOT}/rust/target/linux-build"

if [[ ! -f "${GENERATED_WRAPPER}" ]]; then
  echo "Expected generated wrapper at ${GENERATED_WRAPPER} but it does not exist." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

# TODO: drop this prepend (see the matching block in
# `scripts/rust/regenerate-wrapper.sh`) once a swift-format release including
# apple/swift-format#1197 ships in our stable Swift toolchain – at that point
# a `.swift-format-ignore` file at the repo root replaces it.
{
    echo "// swift-format-ignore-file"
    cat "${GENERATED_WRAPPER}"
} > "${TEMP_DIR}/HFAPIFFI.swift"

if ! git diff --no-index --exit-code "${TEMP_DIR}/HFAPIFFI.swift" "${COMMITTED_WRAPPER}"; then
  cat >&2 <<EOF

Generated UniFFI Swift wrapper drifted from the committed copy. Run

    scripts/rust/regenerate-wrapper.sh

and commit the resulting changes to ${COMMITTED_WRAPPER#${REPO_ROOT}/}.
EOF
  exit 1
fi

# Optional second pass: diff the artifactbundle's staged C header and
# cross-platform modulemap against a fresh bindgen run. The build scripts
# strip Apple-only `use "..."` directives from the bindgen-emitted
# modulemap before staging, so apply the same transform to the freshly
# regenerated copy once and reuse it for every staged comparison.
STRIPPED_MODULEMAP="${TEMP_DIR}/module.modulemap"
bash "${SCRIPT_DIR}/build/strip-modulemap-uses.sh" \
  "${GENERATED_MODULEMAP}" \
  "${STRIPPED_MODULEMAP}"

check_staged_include() {
  local staged_dir="$1"
  local source_script="$2"
  local staged_header="${staged_dir}/include/HFAPIRust.h"
  local staged_modulemap="${staged_dir}/include/module.modulemap"

  if [[ ! -d "${staged_dir}" ]]; then
    return 0
  fi

  if [[ -f "${staged_header}" ]]; then
    if ! git diff --no-index --exit-code "${GENERATED_HEADER}" "${staged_header}"; then
      cat >&2 <<EOF

Staged HFAPIRust.h drifted from the bindgen output. Re-run

    ${source_script}

before assembling the bundle.
EOF
      exit 1
    fi
  fi

  if [[ -f "${staged_modulemap}" ]]; then
    if ! git diff --no-index --exit-code "${STRIPPED_MODULEMAP}" "${staged_modulemap}"; then
      cat >&2 <<EOF

Staged module.modulemap drifted from the (use-stripped) bindgen output.
Re-run

    ${source_script}

before assembling the bundle.
EOF
      exit 1
    fi
  fi
}

check_staged_include "${APPLE_BUILD_DIR}" "scripts/rust/build/build-rust-apple-slices.sh"
check_staged_include "${LINUX_BUILD_DIR}" "scripts/rust/build/build-rust-linux-archives.sh"
