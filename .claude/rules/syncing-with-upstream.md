# Syncing with Upstream

This repo is a fork of [huggingface/swift-huggingface](https://github.com/huggingface/swift-huggingface). There is no `upstream` remote — syncing is done by fetching directly from the URL to avoid `gh` and GitHub Desktop associating the repo with the upstream account:

```
git fetch https://github.com/huggingface/swift-huggingface.git main:upstream-main
```

The local `upstream-main` branch is a pull-only reference to the original repo's main branch.

## Tracking documents

**`docs/upstream-commits-analysis.md`** is the persistent ledger of all upstream commits and our judgment/action on each. Keep it concise — one table row per upstream PR with commit hash, description, and action taken.

For each sync session, create a fresh working document (e.g., `docs/upstream-sync-2026-03-15.md`) for detailed analysis, comparisons with Python, API investigation notes, etc. Update the main ledger with judgments/actions as you go. The working document can be discarded or kept for reference after the sync is complete.

After completing a sync, update the last sync date and last checked commit hash at the top of the ledger.

## Philosophy

Our goal is to align closely with the Python `huggingface_hub` library. When upstream introduces new designs or strategies that diverge from how Python does things, we prefer to follow Python's approach instead. Some differences from upstream are also due to improvements we've made on top of cherry-picked commits (e.g., fixing mock tests to use realistic API response formats, handling response shapes the upstream code missed).

## Design documents

Our fork makes different architectural choices from upstream in several areas. Refer to these when evaluating whether an upstream change applies:

- `docs/differences-from-upstream/download-cache-design.md` — our download/cache architecture (explains why many of Mattt's download-related PRs don't apply)
- `docs/differences-from-upstream/pagination-design.md` — our pagination implementation

## Evaluating upstream changes

Before cherry-picking, evaluate each upstream PR:

1. **Read the diff** to understand what it does.
2. **Check if we already have equivalent functionality.** Our download/cache architecture differs significantly from upstream (Mattt's rewrite). Many upstream changes are reimplementations of features we already have.
3. **Cross-reference with Python `huggingface_hub`** when the change involves API behavior. Verify that the Swift implementation matches what Python does. If Python doesn't have an equivalent function, check other Hugging Face libraries (e.g., `datasets`, Dataset Viewer API) or the actual API responses.
4. **Test against the real API** when mock tests alone can't verify correctness. Mock responses should use realistic formats that match what the API actually returns.

## Cherry-picking workflow

1. Fetch the latest upstream commits into `upstream-main` before starting:
   ```
   git fetch https://github.com/huggingface/swift-huggingface.git main:upstream-main
   ```
2. Use `git cherry-pick <hash> --no-commit` to inspect changes before committing.
2. Resolve conflicts:
   - Keep our version when upstream changes don't apply to our architecture.
   - For non-trivial conflict resolution, note what was dropped in the commit message.
4. Build and run tests before committing.
5. Commit the cherry-pick preserving original authorship with `--author="Name <email>"`. Add `Co-Authored-By: Anthony DePasquale <anthony@depasquale.org>` when we make modifications beyond trivial conflict resolution. Reference the upstream PR in the commit message: `Cherry-picked from huggingface/swift-huggingface#XX (hash).`
6. If we need to make additional improvements on top of the cherry-pick (e.g., fixing tests to use realistic API responses, handling edge cases the upstream missed), commit those as **separate commits** under Anthony's authorship (the default git config).

## PRs and documentation

- Create a **separate PR for each logical change** (one upstream PR or a small group of related changes).
- Write a PR description in `docs/` as a markdown file before opening the PR.
- Update the checklist in `docs/upstream-commits-analysis.md` after each item.

## Copyright headers

All `.swift` files should have copyright headers. If a file is missing them, add them at the top of the file. The rules for which copyright lines to include:

- **Upstream-only content** (pure cherry-picks with no significant modifications): `// Copyright © Hugging Face SAS`
- **Anthony-only content** (entirely new files written by us): `// Copyright © Anthony DePasquale`
- **Mixed content** (upstream code with our modifications, or files with contributions from both): both lines, with Hugging Face first:
  ```swift
  // Copyright © Hugging Face SAS
  // Copyright © Anthony DePasquale
  ```

For any files modified during the sync process, check the copyright headers. If `// Copyright © Anthony DePasquale` is not already present, add it below the existing copyright lines.

## Changes on top of cherry-picks

When upstream changes are incomplete or incorrect, fix them in the same PR rather than deferring:
- Update mock tests to use realistic API response formats.
- Add integration tests gated behind `SKIP_INTEGRATION_TESTS` for important API behavior.
- Fix response handling to match actual API behavior (e.g., the parquet endpoint returns different response shapes depending on parameters).
