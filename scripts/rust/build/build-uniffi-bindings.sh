#!/usr/bin/env bash
set -euo pipefail

# Builds the UniFFI Swift wrapper, generated C header, and modulemap into
# `rust/target/uniffi-bindings/`.
#
# This is the cheap subset of the Apple/Linux build scripts: it builds only
# the host static library plus the `uniffi-bindgen-swift` binary, not the
# full per-target matrix or the artifactbundle assembly. UniFFI's library-
# mode bindgen reads metadata from one static library, and the metadata is
# identical across the per-target slices we ship, so a single host-target
# build is enough to regenerate the wrapper.
#
# Callers:
# - `scripts/rust/regenerate-wrapper.sh` (developer command that copies the
#    generated wrapper over the committed copy).
# - `scripts/rust/check-wrapper-drift.sh` (CI drift guard).
# - `scripts/rust/build/build-rust-apple-slices.sh` and
#   `scripts/rust/build/build-rust-linux-archives.sh` (release builds, after
#    the per-target `cargo build` invocations).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CRATE_DIR="${REPO_ROOT}/rust"
UNIFFI_BINDINGS_DIR="${CRATE_DIR}/target/uniffi-bindings"
LOCKFILE_PATH="${CRATE_DIR}/Cargo.lock"
TOOLCHAIN_FILE="${REPO_ROOT}/rust-toolchain.toml"

export CARGO_TARGET_DIR="${CRATE_DIR}/target"

if [[ ! -f "${LOCKFILE_PATH}" ]]; then
  echo "Missing ${LOCKFILE_PATH}. Commit the lockfile before building bindgen artifacts." >&2
  exit 1
fi

if [[ ! -f "${TOOLCHAIN_FILE}" ]]; then
  echo "Missing ${TOOLCHAIN_FILE}. Pin the Rust toolchain before building bindgen artifacts." >&2
  exit 1
fi

TOOLCHAIN="$(awk -F'"' '/^[[:space:]]*channel[[:space:]]*=/ {print $2; exit}' "${TOOLCHAIN_FILE}")"
if [[ -z "${TOOLCHAIN}" ]]; then
  echo "Failed to parse toolchain channel from ${TOOLCHAIN_FILE}." >&2
  exit 1
fi

# We feed bindgen the host static library. The metadata is identical across
# the per-target builds, so any one slice works. Detect the host triple from
# rustc rather than hardcoding it so this script works on every machine that
# runs the release pipeline (Apple Silicon and Intel macOS for Apple builds,
# x86_64 and arm64 Linux for Linux builds and PR CI).
rustup toolchain install "${TOOLCHAIN}" --profile minimal
# `awk … exit` would close the pipe early and SIGPIPE rustc, which
# `pipefail` then turns into a non-zero exit status even though awk
# captured the host triple successfully. Read all of rustc's output
# instead – it is only a handful of lines.
HOST_TARGET="$(rustc +"${TOOLCHAIN}" -vV | awk '/^host:/ {print $2}')"
if [[ -z "${HOST_TARGET}" ]]; then
  echo "Failed to detect host triple from rustc." >&2
  exit 1
fi
rustup target add --toolchain "${TOOLCHAIN}" "${HOST_TARGET}"

cargo +"${TOOLCHAIN}" build \
  --manifest-path "${CRATE_DIR}/Cargo.toml" \
  --locked \
  --release \
  --target "${HOST_TARGET}"

cargo +"${TOOLCHAIN}" build \
  --manifest-path "${CRATE_DIR}/Cargo.toml" \
  --locked \
  --release \
  --features uniffi-cli \
  --bin uniffi-bindgen-swift

BINDGEN_BIN="${CRATE_DIR}/target/release/uniffi-bindgen-swift"
HOST_STATIC_LIB="${CRATE_DIR}/target/${HOST_TARGET}/release/libhf_api_rust.a"

rm -rf "${UNIFFI_BINDINGS_DIR}"
mkdir -p "${UNIFFI_BINDINGS_DIR}"

# UniFFI's library-mode bindgen reads metadata from the static library. The
# Swift wrapper goes alongside the headers in `target/uniffi-bindings/`; this
# script never copies it into `Sources/HFAPIFFI/Generated/` – that's
# `scripts/rust/regenerate-wrapper.sh`'s job.
#
# UniFFI v0.31.x discovers `uniffi.toml` via `cargo metadata`, which must run
# from a directory inside the crate's manifest tree, so we invoke bindgen with
# `cd "${CRATE_DIR}"`.
(
  cd "${CRATE_DIR}"
  "${BINDGEN_BIN}" \
    --swift-sources \
    "${HOST_STATIC_LIB}" \
    "${UNIFFI_BINDINGS_DIR}"

  # The HFAPIRust artifactbundle ships `include/` + per-platform
  # `libhf_api_rust.a` (not a `.framework` bundle), so the modulemap must
  # be a plain `module`, not `framework module`. We omit `--xcframework`,
  # which is the flag that flips UniFFI's bindgen template to emit the
  # framework form.
  "${BINDGEN_BIN}" \
    --headers --modulemap \
    --module-name HFAPIRust \
    --modulemap-filename module.modulemap \
    "${HOST_STATIC_LIB}" \
    "${UNIFFI_BINDINGS_DIR}"
)
