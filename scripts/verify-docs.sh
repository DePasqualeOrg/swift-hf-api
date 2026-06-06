#!/usr/bin/env bash
# Build documentation for every public library target in combined mode.
# Combined documentation lets articles in one target use absolute symbol
# links to sibling targets — e.g., the `HFAPIHubAuth` glue refers to
# ``/HFAPI/HFClient`` and ``/HFAPIOAuth/OAuthManager`` via absolute paths,
# which only resolve when DocC sees the full multi-target symbol graph.
#
# Treats doc warnings (broken DocC links, missing symbols, malformed code
# blocks) as errors so rename / refactor regressions are caught in CI.
#
# Requires HFAPI_ENABLE_DOCS=1 so Package.swift resolves the
# swift-docc-plugin dependency. Without this guard, end users resolving the
# package would pull in the plugin unnecessarily.

set -euo pipefail

cd "$(dirname "$0")/.."

export HFAPI_ENABLE_DOCS=1

TARGETS=(HFAPI HFAPIShared HFAPIOAuth HFAPIHubAuth)

TARGET_ARGS=()
for target in "${TARGETS[@]}"; do
    TARGET_ARGS+=(--target "${target}")
done

echo "=== Generating combined documentation for: ${TARGETS[*]} ==="
mkdir -p .build/docs
swift package \
    --allow-writing-to-directory .build/docs \
    generate-documentation \
    --enable-experimental-combined-documentation \
    "${TARGET_ARGS[@]}" \
    --warnings-as-errors \
    --output-path .build/docs
