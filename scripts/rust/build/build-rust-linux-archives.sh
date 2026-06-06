#!/usr/bin/env bash
# Build the Linux Rust slices (x86_64 + aarch64, both *-unknown-linux-gnu)
# and stage them under ${REPO_ROOT}/rust/target/linux-build/ in the layout
# the artifactbundle assembler expects.
#
# The release pipeline runs this on Ubuntu 22.04 (jammy) so the resulting
# binaries are forward-compatible with the glibc shipped in newer Ubuntu
# LTS images. Cross-compiling to the non-host target requires `gcc-<triple>`
# plus a Cargo `[target.<triple>] linker = "..."` config entry – without
# that mapping cargo invokes the host `gcc` and link fails. Both come from
# the calling workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CRATE_DIR="${REPO_ROOT}/rust"
LINUX_OUT="${REPO_ROOT}/rust/target/linux-build"
UNIFFI_BINDINGS_DIR="${CRATE_DIR}/target/uniffi-bindings"
LOCKFILE_PATH="${CRATE_DIR}/Cargo.lock"
TOOLCHAIN_FILE="${REPO_ROOT}/rust-toolchain.toml"

export CARGO_TARGET_DIR="${CRATE_DIR}/target"

if [[ ! -f "${LOCKFILE_PATH}" ]]; then
  echo "Missing ${LOCKFILE_PATH}. Commit the lockfile before building release artifacts." >&2
  exit 1
fi

if [[ ! -f "${TOOLCHAIN_FILE}" ]]; then
  echo "Missing ${TOOLCHAIN_FILE}. Pin the Rust toolchain before building release artifacts." >&2
  exit 1
fi

TOOLCHAIN="$(awk -F'"' '/^[[:space:]]*channel[[:space:]]*=/ {print $2; exit}' "${TOOLCHAIN_FILE}")"
if [[ -z "${TOOLCHAIN}" ]]; then
  echo "Failed to parse toolchain channel from ${TOOLCHAIN_FILE}." >&2
  exit 1
fi

# Default to building both Linux targets, which is what the release pipeline
# wants. PR CI's host-only Linux job can narrow the list via the env override
# below to skip the cross-compile and the cross-toolchain install.
if [[ -n "${HFAPI_LINUX_TARGETS:-}" ]]; then
  IFS=',' read -ra TARGETS <<< "${HFAPI_LINUX_TARGETS}"
else
  TARGETS=(
    x86_64-unknown-linux-gnu
    aarch64-unknown-linux-gnu
  )
fi

rustup toolchain install "${TOOLCHAIN}" --profile minimal
rustup target add --toolchain "${TOOLCHAIN}" "${TARGETS[@]}"

for target in "${TARGETS[@]}"; do
  echo "Building for ${target}..."
  cargo +"${TOOLCHAIN}" build \
    --manifest-path "${CRATE_DIR}/Cargo.toml" \
    --locked \
    --release \
    --target "${target}"
done

# Stage the cross-platform `include/` next to the Linux slices so the
# Linux PR CI job can run this script standalone and feed `assemble-
# artifactbundle.sh` without macOS being in the loop.
bash "${SCRIPT_DIR}/build-uniffi-bindings.sh"

if [[ "${LINUX_OUT}" != *"/rust/target/linux-build" ]]; then
  echo "Refusing to rm LINUX_OUT=${LINUX_OUT}: does not end with /rust/target/linux-build." >&2
  exit 1
fi
rm -rf "${LINUX_OUT}"
mkdir -p "${LINUX_OUT}/include"
cp "${UNIFFI_BINDINGS_DIR}/HFAPIRust.h" "${LINUX_OUT}/include/HFAPIRust.h"
bash "${SCRIPT_DIR}/strip-modulemap-uses.sh" \
  "${UNIFFI_BINDINGS_DIR}/module.modulemap" \
  "${LINUX_OUT}/include/module.modulemap"

# Map cargo target triples to the bundle's variant directory names.
declare -A VARIANT_DIRS=(
  [x86_64-unknown-linux-gnu]=linux-x86_64
  [aarch64-unknown-linux-gnu]=linux-aarch64
)

for target in "${TARGETS[@]}"; do
  variant="${VARIANT_DIRS[${target}]:-}"
  if [[ -z "${variant}" ]]; then
    echo "Unknown Linux target ${target}; expected one of: ${!VARIANT_DIRS[*]}." >&2
    exit 1
  fi
  mkdir -p "${LINUX_OUT}/${variant}"
  cp "${CRATE_DIR}/target/${target}/release/libhf_api_rust.a" \
    "${LINUX_OUT}/${variant}/libhf_api_rust.a"
done

echo
echo "Linux slices staged at ${LINUX_OUT}:"
find "${LINUX_OUT}" -mindepth 1 -maxdepth 2 -print
