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
# binary collide with duplicate-symbol link errors.
#
# The merge is root-driven: a stub object references every FFI symbol and
# `ld -r` loads only the archive members needed to satisfy them — the same
# selective loading consumers' final links performed against the plain
# archive. Merging every member instead turns a dead member's dangling extern
# into a consumer-side link error (aws-lc's hrss.o references an x86-64 asm
# routine that is never built, which broke the 0.4.1 Linux slice). The data
# stub is required because Apple's `ld -r` silently loads nothing from
# archives given only `-u` roots or `-all_load`. `-S` drops the debug map
# (N_OSO stabs); without it the merged object references the original .o
# files in this temp dir, and every consumer's debug build warns "unable to
# open object file" for each of them.
localize_archive_symbols() {
  echo "Localizing non-FFI symbols in $1..."
  local archive="$1" arch="$2" platform="$3" min_version="$4" sdk_version="$5"
  local target
  case "${platform}" in
    macos) target="${arch}-apple-macos${min_version}" ;;
    ios) target="${arch}-apple-ios${min_version}" ;;
    ios-simulator) target="${arch}-apple-ios${min_version}-simulator" ;;
    *)
      echo "No clang target mapping for platform ${platform}." >&2
      exit 1
      ;;
  esac
  local workdir
  workdir="$(mktemp -d)"
  (
    cd "${workdir}"
    # Harvest the FFI keep list from a throwaway full merge. Apple's nm
    # cannot read members whose embedded LLVM bitcode is newer than its
    # reader (Xcode 16's nm vs Rust 1.94's LLVM 21 bitcode), but ld -r
    # copies those members without parsing the bitcode, and nm reads the
    # merged output fine.
    mkdir extract
    (cd extract && ar -x "${archive}")
    ld -r -S -arch "${arch}" \
      -platform_version "${platform}" "${min_version}" "${sdk_version}" \
      extract/*.o -o probe.o
    nm -gU probe.o | awk '{print $3}' | grep -E '^_(uniffi|ffi)_' | sort -u > keep.txt
    local kept
    kept="$(wc -l < keep.txt | tr -d ' ')"
    # The full UniFFI surface is ~201 symbols; a much smaller count means the
    # keep-list extraction broke and localization would strip the public API.
    if [[ "${kept}" -lt 100 ]]; then
      echo "Symbol localization for ${archive} would keep only ${kept} FFI symbols; aborting." >&2
      exit 1
    fi
    {
      printf '\t.section __DATA,__ffi_roots\n\t.p2align 3\n'
      awk '{print "\t.quad " $0}' keep.txt
    } > stub.s
    clang -target "${target}" -c stub.s -o stub.o
    ld -r -S -arch "${arch}" \
      -platform_version "${platform}" "${min_version}" "${sdk_version}" \
      stub.o "${archive}" -o merged.o
    local resolved
    resolved="$(nm -gU merged.o | awk '{print $3}' | grep -cE '^_(uniffi|ffi)_')"
    if [[ "${resolved}" -ne "${kept}" ]]; then
      echo "Root-driven merge of ${archive} resolved ${resolved} of ${kept} FFI symbols; aborting." >&2
      exit 1
    fi
    nmedit -s keep.txt -o edited.o merged.o
    libtool -static -o "${archive}" edited.o
  )
  rm -rf "${workdir}"
}

# Link an executable against a localized macOS slice to prove the merge left
# no dangling references. With a plain archive the linker loads only
# referenced members, so a member with an unresolvable extern is harmless;
# after merging it would fail every consumer link. The iOS slices share the
# same Rust code graph, so the two macOS link checks cover them. The
# frameworks and libraries mirror Package.swift's Apple linker settings.
smoke_test_link() {
  echo "Link-testing $1..."
  local archive="$1" arch="$2"
  local workdir
  workdir="$(mktemp -d)"
  (
    cd "${workdir}"
    local contract_sym
    contract_sym="$(nm -gU "${archive}" | awk '{print $3}' | grep '_uniffi_contract_version$')"
    printf 'extern unsigned int %s(void);\nint main(void) { return 0 * (int)%s(); }\n' \
      "${contract_sym#_}" "${contract_sym#_}" > smoke.c
    clang -arch "${arch}" smoke.c "${archive}" -o smoke.bin \
      -framework SystemConfiguration -framework CoreFoundation \
      -framework Security -framework IOKit -lobjc -liconv
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

smoke_test_link "${CRATE_DIR}/target/aarch64-apple-darwin/release/libhf_api_rust.a" arm64
smoke_test_link "${CRATE_DIR}/target/x86_64-apple-darwin/release/libhf_api_rust.a" x86_64

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
