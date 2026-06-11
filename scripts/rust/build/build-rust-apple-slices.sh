#!/usr/bin/env bash
# Build the Apple-platform Rust slices (macOS + iOS device + iOS simulator)
# and stage them in the layout the artifactbundle assembler expects.
#
# Outputs (under ${REPO_ROOT}/rust/target/apple-build/):
#   apple-macos/libhf_api_rust.a            # fat: arm64 + x86_64
#   apple-ios-device/libhf_api_rust.a       # arm64 only
#   apple-ios-simulator/libhf_api_rust.a    # fat: arm64 + x86_64
#   include/HFAPIRust.h
#   include/module.modulemap                # cross-platform (Apple-specific
#                                             use directives stripped)
#
# The companion Linux slices come from build-rust-linux-archives.sh; the
# assemble-artifactbundle.sh step combines both into a single bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CRATE_DIR="${REPO_ROOT}/rust"
APPLE_OUT="${REPO_ROOT}/rust/target/apple-build"
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

TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)

rustup toolchain install "${TOOLCHAIN}" --profile minimal
rustup target add --toolchain "${TOOLCHAIN}" "${TARGETS[@]}"

# Match Package.swift's minimum deployment targets so consumers linking at
# those minimums don't get "object file was built for newer version" warnings.
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0

for target in "${TARGETS[@]}"; do
  echo "Building for ${target}..."
  cargo +"${TOOLCHAIN}" build \
    --manifest-path "${CRATE_DIR}/Cargo.toml" \
    --locked \
    --release \
    --target "${target}"
done

# Reuses the host static library we just built – `cargo build` inside is a
# no-op with a warm target dir.
bash "${SCRIPT_DIR}/build-uniffi-bindings.sh"

# Localize every global symbol except the UniFFI C surface (uniffi_* / ffi_*).
# Rust staticlibs export Rust runtime symbols (rust_eh_personality,
# std::panicking::EMPTY_PANIC) as globals, so two Rust staticlibs in one
# binary collide with duplicate-symbol link errors. Merging the archive into
# one relocatable object binds cross-member references internally; nmedit
# then demotes the non-FFI globals to locals.
localize_archive_symbols() {
  local archive="$1" arch="$2" platform="$3" min_version="$4" sdk_version="$5"
  local workdir
  workdir="$(mktemp -d)"
  (
    cd "${workdir}"
    ar -x "${archive}"
    ld -r -arch "${arch}" \
      -platform_version "${platform}" "${min_version}" "${sdk_version}" \
      ./*.o -o merged.o
    nm -gU merged.o | awk '{print $3}' | grep -E '^_(uniffi|ffi)_' > keep.txt
    local kept
    kept="$(wc -l < keep.txt | tr -d ' ')"
    if [[ "${kept}" -lt 100 ]]; then
      echo "Symbol localization for ${archive} would keep only ${kept} FFI symbols; aborting." >&2
      exit 1
    fi
    nmedit -s keep.txt -o edited.o merged.o
    libtool -static -o "${archive}" edited.o
  )
  rm -rf "${workdir}"
}

MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
IOS_SIM_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"

localize_archive_symbols "${CRATE_DIR}/target/aarch64-apple-darwin/release/libhf_api_rust.a" arm64 macos 14.0 "${MACOS_SDK_VERSION}"
localize_archive_symbols "${CRATE_DIR}/target/x86_64-apple-darwin/release/libhf_api_rust.a" x86_64 macos 14.0 "${MACOS_SDK_VERSION}"
localize_archive_symbols "${CRATE_DIR}/target/aarch64-apple-ios/release/libhf_api_rust.a" arm64 ios 17.0 "${IOS_SDK_VERSION}"
localize_archive_symbols "${CRATE_DIR}/target/aarch64-apple-ios-sim/release/libhf_api_rust.a" arm64 ios-simulator 17.0 "${IOS_SIM_SDK_VERSION}"
localize_archive_symbols "${CRATE_DIR}/target/x86_64-apple-ios/release/libhf_api_rust.a" x86_64 ios-simulator 17.0 "${IOS_SIM_SDK_VERSION}"

if [[ "${APPLE_OUT}" != *"/rust/target/apple-build" ]]; then
  echo "Refusing to rm APPLE_OUT=${APPLE_OUT}: does not end with /rust/target/apple-build." >&2
  exit 1
fi
rm -rf "${APPLE_OUT}"
mkdir -p "${APPLE_OUT}/apple-macos" "${APPLE_OUT}/apple-ios-device" "${APPLE_OUT}/apple-ios-simulator" "${APPLE_OUT}/include"

cp "${UNIFFI_BINDINGS_DIR}/HFAPIRust.h" "${APPLE_OUT}/include/HFAPIRust.h"
bash "${SCRIPT_DIR}/strip-modulemap-uses.sh" \
  "${UNIFFI_BINDINGS_DIR}/module.modulemap" \
  "${APPLE_OUT}/include/module.modulemap"

lipo -create \
  "${CRATE_DIR}/target/aarch64-apple-darwin/release/libhf_api_rust.a" \
  "${CRATE_DIR}/target/x86_64-apple-darwin/release/libhf_api_rust.a" \
  -output "${APPLE_OUT}/apple-macos/libhf_api_rust.a"

cp "${CRATE_DIR}/target/aarch64-apple-ios/release/libhf_api_rust.a" \
  "${APPLE_OUT}/apple-ios-device/libhf_api_rust.a"

lipo -create \
  "${CRATE_DIR}/target/aarch64-apple-ios-sim/release/libhf_api_rust.a" \
  "${CRATE_DIR}/target/x86_64-apple-ios/release/libhf_api_rust.a" \
  -output "${APPLE_OUT}/apple-ios-simulator/libhf_api_rust.a"

echo
echo "Apple slices staged at ${APPLE_OUT}:"
find "${APPLE_OUT}" -mindepth 1 -maxdepth 2 -print
