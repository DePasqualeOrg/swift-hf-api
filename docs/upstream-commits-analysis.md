# Upstream Commits Analysis

- **Last sync:** 2026-04-01
- **Last checked commit:** `b721959` (version 0.9.0)

Tracking upstream commits from [huggingface/swift-huggingface](https://github.com/huggingface/swift-huggingface) and our action on each.

| Upstream PR | Upstream commit | Description | Action |
|----|--------|-------------|--------|
| #26 | `0cafd98` | Pagination | Skip – already have our own implementation |
| #28 | `928f33d` | Harmonize with `huggingface_hub` | **Done** (PR #3) |
| #29 | `38299d3` | File locking reentrancy | Skip – we use `swift-filelock` |
| #30 | `b9ae5a7` | Replace FileProgressReporter on Linux | Skip – our own progress implementation |
| #31 | `b0f2286` | Xet metadata before CDN redirect | Skip – already have HEAD preflight, `SameHostRedirectDelegate`, path traversal validation |
| #32 | `15c5cd7` | CI container change | Skip – different CI setup |
| #33 | `7edf91e` | Cache-backed snapshot paths | Skip – already have `resolveCachedSnapshot` |
| #34 | `cc6ea51` | Cache-first downloads, resume, offline | Skip – already have all of these |
| #35 | `95fb37a` | Parallelize LFS downloads | Skip – already have parallel downloads |
| #36 | `11ae702` | Locks under `.locks` hierarchy | Skip – already use `.locks` hierarchy |
| #37 | `5882b64` | Benchmarks test target | Skip – already have benchmarks |
| #38 | `eaac2c8` | Expand test coverage | **Done** (PR #4) |
| #39 | `7b09cef` | URL-only parquet responses | **Done** (PR #5) – also fixed nested response shape handling |
| #40 | `9b2f377` | iOS/sandboxed cache paths | **Done** (PR #6) |
| #42 | `de01c0a` | Same-blob snapshot copy fix | Skip – our architecture avoids this bug |
| #43 | `9ca2e54` | Download destinations as file paths | Skip – our destination is consistently a directory |
| — | `7198b06` | Version bump to 0.8.0 | Skip |
| #44 | `f724f92` | Update swift-xet dependency location | Skip – we use our own fork |
| #46 | `169d588` | Conditionalize swift-xet behind "Xet" trait | Skip – we always include Xet |
| #45 | `f2b0353` | Fix Mac Catalyst build: duplicate presentation context provider | **Done** – applied to our code |
| — | `b721959` | Version bump to 0.9.0 | Skip |
