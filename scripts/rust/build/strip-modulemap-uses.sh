#!/usr/bin/env bash
# Strip Apple-only `use "..."` directives from a clang modulemap.
#
# UniFFI's bindgen template emits `use "Darwin"`, `use "_Builtin_stdbool"`,
# etc. unconditionally. Those clang modules only exist on Apple, so the
# `use` lines break the module load on Linux. The directive is advisory
# (clang resolves `<stdint.h>` etc. through the platform header search
# path on every target without it), so stripping is safe on Apple too.
#
# Usage: strip-modulemap-uses.sh <src> <dst>

set -euo pipefail

src="${1:?usage: strip-modulemap-uses.sh <src> <dst>}"
dst="${2:?usage: strip-modulemap-uses.sh <src> <dst>}"

sed -E '/^[[:space:]]*use[[:space:]]+"[^"]+"[[:space:]]*$/d' "${src}" > "${dst}"
