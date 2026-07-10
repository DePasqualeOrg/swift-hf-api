---
name: sync-upstream
description: Evaluate and adapt upstream huggingface/swift-huggingface changes for the independently maintained swift-hf-api fork. Use when the user explicitly asks to inspect, plan, or perform an upstream synchronization.
---

# Sync Upstream

## Preserve the fork model

This repository has no `upstream` remote. Fetch the upstream default branch directly into the pull-only `upstream-main` branch:

```text
git fetch https://github.com/huggingface/swift-huggingface.git main:upstream-main
```

Never push `upstream-main`. The local `dev` branch is also never pushed and must not be recreated on `origin`.

## Maintain the tracking documents

Use `docs/upstream-commits-analysis.md` as the concise persistent ledger, with one row per upstream pull request and its commit, description, judgment, and action. For each sync session, use a separate dated working document under `docs/` for detailed comparisons, Python/API investigation, and implementation notes. Update the ledger's last-sync date and last-checked commit after the analysis is complete.

Read the fork's design documents before judging related changes:

- `docs/differences-from-upstream/download-cache-design.md`
- `docs/differences-from-upstream/pagination-design.md`

## Evaluate before applying

1. Read each upstream diff and identify its behavioral intent.
2. Check whether the fork already provides equivalent functionality, especially where its download/cache or pagination architecture differs.
3. Cross-check API behavior against Python `huggingface_hub`. When Python lacks an equivalent, inspect other Hugging Face libraries or actual API responses.
4. Use realistic mock formats and real-API checks when mocks cannot establish correctness.
5. Record the judgment before applying changes. Skip reimplementations that do not fit the fork, and explain why.

## Adapt selected changes

Use `git cherry-pick <hash> --no-commit` to inspect and adapt a selected change without creating a commit. Keep the fork's implementation when the upstream architecture does not apply. Record nontrivial conflict choices and place fork-specific improvements, realistic mocks, integration coverage, or response-shape corrections alongside the adapted change as appropriate.

Build and test through the project's supported containerized workflow. Do not create a commit unless the user explicitly authorizes it in the current conversation. For an authorized cherry-pick commit, preserve the original author, document nontrivial adaptations, and reference the upstream pull request and commit. Keep separate fork-authored improvements in a separate authorized commit when that history is useful.

Creating or pushing branches, opening pull requests, or changing GitHub state requires separate explicit authorization. Prepare one pull request description per logical upstream change under `docs/` when asked, and update the ledger as work progresses.

## Copyright headers

Ensure modified Swift files have the correct headers:

- Upstream-only content: `// Copyright © Hugging Face SAS`
- Anthony-only content: `// Copyright © Anthony DePasquale`
- Mixed content: Hugging Face first, then Anthony

Add Anthony's line when the fork makes substantive modifications to upstream code. Do not add AI attribution or AI co-author metadata.
