# AGENTS.md

Repo-specific instructions for coding agents working in swift-hf-api.

## The `dev` branch is never pushed

The `dev` branch is a local-only integration branch. Never push it to any remote — no `git push origin dev`, and do not recreate `origin/dev` (which was intentionally deleted). Rebase `dev` onto `main` as needed, but keep it strictly local.

`dev` carries the project's documentation (`docs/`), which is intentionally kept off `main`. That is why the docs are untracked on `main` and only committed on `dev`.

## Upstream synchronization

When asked to synchronize with `huggingface/swift-huggingface`, use the project-local `$sync-upstream` skill. Analyze and adapt changes using the fork's ledgers and design documents; commits, pushes, and pull requests each require explicit authorization.
