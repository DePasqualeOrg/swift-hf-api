#!/usr/bin/env bash
# Assemble the unified HFAPIRust.artifactbundle from the per-platform
# build outputs and emit a zipped archive plus a SHA-256 checksum file.
#
# Inputs:
#   - Apple slices staged under <APPLE_BUILD_DIR> by build-rust-apple-slices.sh:
#       apple-macos/libhf_api_rust.a
#       apple-ios-device/libhf_api_rust.a
#       apple-ios-simulator/libhf_api_rust.a
#       include/HFAPIRust.h
#       include/module.modulemap          # cross-platform
#   - Linux slices staged under <LINUX_BUILD_DIR> by build-rust-linux-archives.sh:
#       linux-x86_64/libhf_api_rust.a
#       linux-aarch64/libhf_api_rust.a
#
# Outputs:
#   <STAGING_DIR>/HFAPIRust.artifactbundle/
#   <ARCHIVE_PATH>                        (.zip of the artifactbundle)
#   <ARCHIVE_PATH>.checksum               (SwiftPM compute-checksum format)
#
# Usage:
#   assemble-artifactbundle.sh <version> [<apple-build-dir>] [<linux-build-dir>] [<archive-out-path>]
#
# Defaults wire up to the conventional paths so a maintainer running the
# pipeline locally can assemble after building both halves; CI invokes the
# script with explicit paths after downloading workflow artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

VERSION="${1:?usage: scripts/rust/build/assemble-artifactbundle.sh <version> [<apple-build-dir>] [<linux-build-dir>] [<archive-out-path>]}"
APPLE_BUILD_DIR="${2:-${REPO_ROOT}/rust/target/apple-build}"
LINUX_BUILD_DIR="${3:-${REPO_ROOT}/rust/target/linux-build}"
ARCHIVE_OUT_PATH="${4:-${REPO_ROOT}/Artifacts/HFAPIRust-${VERSION}.artifactbundle.zip}"

STAGING_DIR="${REPO_ROOT}/rust/target/artifactbundle"
BUNDLE_NAME="HFAPIRust.artifactbundle"
BUNDLE_DIR="${STAGING_DIR}/${BUNDLE_NAME}"

# The variant manifest. Each entry is "<bundle-dir>|<source-path>|<triples>"
# where <triples> is a comma-separated list of LLVM-style triples – note
# that Rust target names (e.g. `aarch64-apple-ios-sim`, `x86_64-apple-ios`)
# do not match the LLVM triples SwiftPM compares against
# (`arm64-apple-ios-simulator`, `x86_64-apple-ios-simulator`), so the
# strings below are deliberately the LLVM forms. The release pipeline
# always passes both build dirs, but local development on macOS and the
# host-only Phase 2 PR CI job each pass a subset; info.json lists only the
# variants whose .a is on disk, so SwiftPM's variant selection sees the
# available host triples and consumers building for an unsupported triple
# fail loudly rather than silently linking nothing.
manifest=(
  "apple-macos|${APPLE_BUILD_DIR}/apple-macos/libhf_api_rust.a|arm64-apple-macosx,x86_64-apple-macosx"
  "apple-ios-device|${APPLE_BUILD_DIR}/apple-ios-device/libhf_api_rust.a|arm64-apple-ios"
  "apple-ios-simulator|${APPLE_BUILD_DIR}/apple-ios-simulator/libhf_api_rust.a|arm64-apple-ios-simulator,x86_64-apple-ios-simulator"
  "linux-x86_64|${LINUX_BUILD_DIR}/linux-x86_64/libhf_api_rust.a|x86_64-unknown-linux-gnu"
  "linux-aarch64|${LINUX_BUILD_DIR}/linux-aarch64/libhf_api_rust.a|aarch64-unknown-linux-gnu"
)

present=()
for entry in "${manifest[@]}"; do
  IFS='|' read -r _dir src _triples <<< "${entry}"
  [[ -f "${src}" ]] && present+=("${entry}")
done

if [[ ${#present[@]} -eq 0 ]]; then
  echo "No slices found. Build at least one platform's slices first." >&2
  echo "  Looked for Apple slices under: ${APPLE_BUILD_DIR}" >&2
  echo "  Looked for Linux slices under: ${LINUX_BUILD_DIR}" >&2
  exit 1
fi

# Both build scripts stage the cross-platform `include/` (header + modulemap)
# next to their slices. Pick whichever is present, preferring the Apple build
# dir for backward compatibility with prior-release tooling. The post-strip
# modulemap is identical regardless of which build script produced it.
include_src=""
for candidate in "${APPLE_BUILD_DIR}/include" "${LINUX_BUILD_DIR}/include"; do
  if [[ -f "${candidate}/HFAPIRust.h" && -f "${candidate}/module.modulemap" ]]; then
    include_src="${candidate}"
    break
  fi
done

if [[ -z "${include_src}" ]]; then
  echo "Missing bindgen header or modulemap. Looked under:" >&2
  echo "  ${APPLE_BUILD_DIR}/include/" >&2
  echo "  ${LINUX_BUILD_DIR}/include/" >&2
  echo "Run build-rust-apple-slices.sh or build-rust-linux-archives.sh to stage them." >&2
  exit 1
fi

# Defensive suffix check: BUNDLE_DIR derives from REPO_ROOT via several
# path joins. If any path resolution ever slips (e.g., a refactor of where
# this script lives), a bare `rm -rf "${BUNDLE_DIR}"` could nuke a parent
# directory. Asserting the suffix matches what we expect makes the
# destructive operation safe under future moves.
if [[ "${BUNDLE_DIR}" != *"/${BUNDLE_NAME}" ]]; then
  echo "Refusing to rm BUNDLE_DIR=${BUNDLE_DIR}: does not end with /${BUNDLE_NAME}." >&2
  exit 1
fi
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/include"
cp "${include_src}/HFAPIRust.h"  "${BUNDLE_DIR}/include/HFAPIRust.h"
cp "${include_src}/module.modulemap"  "${BUNDLE_DIR}/include/module.modulemap"

included_dirs=()
for entry in "${present[@]}"; do
  IFS='|' read -r dir src _triples <<< "${entry}"
  mkdir -p "${BUNDLE_DIR}/${dir}"
  cp "${src}" "${BUNDLE_DIR}/${dir}/libhf_api_rust.a"
  included_dirs+=("${dir}")
done
echo "Including variants: ${included_dirs[*]}"

# Write info.json. The schema is defined by SE-0482 (staticLibrary artifact
# type, schemaVersion 1.0). The Python helper reads the manifest entries
# from PRESENT_VARIANTS (one per line) so the variant table only lives in
# one place.
VERSION="${VERSION}" \
PRESENT_VARIANTS="$(printf '%s\n' "${present[@]}")" \
python3 - "${BUNDLE_DIR}/info.json" <<'PY'
import json
import os
import sys

variants = []
for entry in os.environ["PRESENT_VARIANTS"].splitlines():
    if not entry:
        continue
    bundle_dir, _src, triples = entry.split("|")
    variants.append({
        "path": f"{bundle_dir}/libhf_api_rust.a",
        "supportedTriples": triples.split(","),
        "staticLibraryMetadata": {
            "headerPaths": ["include"],
            "moduleMapPath": "include/module.modulemap",
        },
    })

info = {
    "schemaVersion": "1.0",
    "artifacts": {
        "HFAPIRust": {
            "type": "staticLibrary",
            "version": os.environ["VERSION"],
            "variants": variants,
        }
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(info, f, indent=2)
    f.write("\n")
PY

mkdir -p "$(dirname "${ARCHIVE_OUT_PATH}")"
rm -f "${ARCHIVE_OUT_PATH}" "${ARCHIVE_OUT_PATH}.checksum"

# Zip the bundle. We `cd` into the staging dir so the archive contains
# `HFAPIRust.artifactbundle/...` at the top level rather than the full
# path. `ditto` is macOS-only; fall back to `zip` so the assemble step works
# inside Linux runners too.
(
  cd "${STAGING_DIR}"
  if command -v ditto >/dev/null 2>&1; then
    ditto -c -k --sequesterRsrc --keepParent "${BUNDLE_NAME}" "${ARCHIVE_OUT_PATH}"
  else
    zip -r -q "${ARCHIVE_OUT_PATH}" "${BUNDLE_NAME}"
  fi
)

# Prefer `swift package compute-checksum` because that is the exact value
# `binaryTarget(checksum:)` will compare against at resolve time. Fall back
# to a plain `sha256sum`/`shasum` if Swift isn't on PATH (which can happen
# inside slim Linux containers used purely for assembly).
if command -v swift >/dev/null 2>&1; then
  swift package --package-path "${REPO_ROOT}" compute-checksum "${ARCHIVE_OUT_PATH}" \
    | tee "${ARCHIVE_OUT_PATH}.checksum"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${ARCHIVE_OUT_PATH}" | awk '{print $1}' | tee "${ARCHIVE_OUT_PATH}.checksum"
else
  shasum -a 256 "${ARCHIVE_OUT_PATH}" | awk '{print $1}' | tee "${ARCHIVE_OUT_PATH}.checksum"
fi

echo
echo "Assembled ${BUNDLE_NAME}/ at ${BUNDLE_DIR}"
echo "Created ${ARCHIVE_OUT_PATH}"
echo "Saved checksum to ${ARCHIVE_OUT_PATH}.checksum"
