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

# Localize every global symbol except the UniFFI C surface (uniffi_* / ffi_*).
# Rust staticlibs export Rust runtime symbols (rust_eh_personality,
# std::panicking::EMPTY_PANIC) as globals, so two Rust staticlibs in one
# binary collide with duplicate-symbol link errors.
#
# The merge is root-driven: the FFI symbols are passed to `ld -r` as `-u`
# roots, so only the archive members needed to satisfy them are loaded — the
# same selective loading consumers' final links performed against the plain
# archive. Merging every member instead turns a dead member's dangling extern
# into a consumer-side link error (aws-lc's hrss.o references an x86-64 asm
# routine that is never built, which broke the 0.4.1 Linux slice). A link
# smoke test against the localized archive guards the result.
localize_archive_symbols() {
  echo "Localizing non-FFI symbols in $1..."
  local archive="$1" ld_tool="$2" nm_tool="$3" objcopy_tool="$4" ar_tool="$5" cc_tool="$6"
  echo "  using: ${ld_tool} ($("${ld_tool}" --version | head -1)), ${objcopy_tool}"
  local workdir
  workdir="$(mktemp -d)"
  (
    cd "${workdir}"
    # Fat LTO leaves embedded bitcode (.llvmbc/.llvmcmd) in the members.
    # GNU ld auto-loads the LLVM gold plugin when it sees bitcode sections,
    # and a plugin older than the bitcode's producer crashes with
    # "LLVM ERROR: Invalid encoding". The bitcode is only useful for further
    # LTO, so strip it before merging; objcopy rewrites each archive member.
    "${objcopy_tool}" --remove-section=.llvmbc --remove-section=.llvmcmd "${archive}" stripped.a
    "${nm_tool}" -g --defined-only stripped.a | awk '{print $3}' | grep -E '^(uniffi|ffi)_' | sort -u > keep.txt
    local kept
    kept="$(wc -l < keep.txt | tr -d ' ')"
    # The full UniFFI surface is ~201 symbols; a much smaller count means the
    # keep-list extraction broke and localization would strip the public API.
    if [[ "${kept}" -lt 100 ]]; then
      echo "Symbol localization for ${archive} would keep only ${kept} FFI symbols; aborting." >&2
      exit 1
    fi
    local -a uflags=()
    local sym
    while IFS= read -r sym; do uflags+=(-u "${sym}"); done < keep.txt
    "${ld_tool}" -r "${uflags[@]}" stripped.a -o merged.o
    local resolved
    resolved="$("${nm_tool}" -g --defined-only merged.o | awk '{print $3}' | grep -cE '^(uniffi|ffi)_')"
    if [[ "${resolved}" -ne "${kept}" ]]; then
      echo "Root-driven merge of ${archive} resolved ${resolved} of ${kept} FFI symbols; aborting." >&2
      exit 1
    fi
    "${objcopy_tool}" --keep-global-symbols=keep.txt merged.o
    rm -f "${archive}"
    "${ar_tool}" rcs "${archive}" merged.o
    # Link an executable against the localized archive to prove the merge
    # left no dangling references. The library list mirrors Package.swift's
    # Linux linker settings for the FFI target.
    local contract_sym
    contract_sym="$(grep '_uniffi_contract_version$' keep.txt)"
    printf 'extern unsigned int %s(void);\nint main(void) { return 0 * (int)%s(); }\n' \
      "${contract_sym}" "${contract_sym}" > smoke.c
    "${cc_tool}" smoke.c "${archive}" -o smoke.bin -lpthread -ldl -lm -lrt -lutil -lgcc_s
    echo "  link smoke test passed"
  )
  rm -rf "${workdir}"
}

for target in "${TARGETS[@]}"; do
  archive="${CRATE_DIR}/target/${target}/release/libhf_api_rust.a"
  case "${target}" in
    x86_64-unknown-linux-gnu)
      localize_archive_symbols "${archive}" /usr/bin/ld /usr/bin/nm /usr/bin/objcopy /usr/bin/ar /usr/bin/gcc
      ;;
    aarch64-unknown-linux-gnu)
      localize_archive_symbols "${archive}" /usr/bin/aarch64-linux-gnu-ld /usr/bin/aarch64-linux-gnu-nm /usr/bin/aarch64-linux-gnu-objcopy /usr/bin/aarch64-linux-gnu-ar /usr/bin/aarch64-linux-gnu-gcc
      ;;
    *)
      echo "No symbol-localization toolchain mapping for ${target}." >&2
      exit 1
      ;;
  esac
done

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
