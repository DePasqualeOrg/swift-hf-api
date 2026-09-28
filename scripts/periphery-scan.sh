#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
jobs=$("$HOME/.agents/bin/agent-build-jobs")
scratch="$root/.test-harness/periphery/index-build"
module_cache="$root/.test-harness/periphery/module-cache"
mkdir -p "$scratch" "$module_cache"
touch "$root/.test-harness/.metadata_never_index"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"

echo 'START package and test index build' >&2
swift build --build-system native --scratch-path "$scratch" --skip-update --build-tests --enable-index-store -j "$jobs"
echo 'FINISH package and test index build' >&2
echo 'START Periphery scan' >&2
periphery scan --config .periphery.yml --index-store-path "$scratch/debug/index/store" "$@"
echo 'FINISH Periphery scan' >&2
