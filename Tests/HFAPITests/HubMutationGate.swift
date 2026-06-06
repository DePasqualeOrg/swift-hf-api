// Copyright © Anthony DePasquale

import Foundation
@testable import HFAPI

/// Integration (live-Hub) suites are gated behind this env var so they don't
/// run in CI, which has no token and shouldn't depend on the live Hub. Set
/// `HFAPI_ENABLE_INTEGRATION_TESTS=1` to run them locally. Every `– live Hub`
/// `@Suite` carries `.enabled(if: integrationTestsEnabled)`. Mirrors the
/// `TOKENIZERS_ENABLE_BENCHMARKS` gate in swift-tokenizers.
let integrationTestsEnabled = ProcessInfo.processInfo.environment["HFAPI_ENABLE_INTEGRATION_TESTS"] == "1"

/// Live-Hub *mutation* tests (create/upload/commit/delete/move/branches/tags)
/// are gated behind the `HFAPI_RUN_HUB_MUTATION_TESTS` environment variable
/// to prevent accidental side effects on the developer's Hub account.
///
/// Without the gate set, any test whose `makeOrSkip` calls
/// ``hubMutationsAllowed()`` returns `nil` and the test skips cleanly,
/// even when a valid token is configured. Read-only tests (model info,
/// downloads, user/org overviews) are unaffected and continue to run on
/// token presence alone – they have no Hub-visible side effects.
///
/// To opt in:
/// ```
/// HFAPI_RUN_HUB_MUTATION_TESTS=1 swift test
/// ```
///
/// Truthy values: `1`, `true`, `yes`, `on` (case-insensitive). Anything
/// else – including the variable being absent – skips.
func hubMutationsAllowed() -> Bool {
    guard let raw = ProcessInfo.processInfo.environment["HFAPI_RUN_HUB_MUTATION_TESTS"] else {
        return false
    }
    switch raw.lowercased() {
    case "1", "true", "yes", "on": return true
    default: return false
    }
}

/// Print a visible notice that mutation tests are being skipped
/// because the gate was not set, then return `false` so callers can
/// early-exit. Returns `true` when mutations are permitted – the call
/// site uses the boolean to decide whether to proceed.
///
/// Without this, a maintainer running `swift test` without
/// `HFAPI_RUN_HUB_MUTATION_TESTS=1` sees a green suite with no indication
/// that any test was skipped – every mutation test silently `return`s
/// from its `guard let ctx = ...` line. Printing the notice keeps the
/// suite green (we don't want missing-token CI runs to fail) while
/// surfacing the skip in the test output.
///
/// The warning is emitted at most **once per process** so a run with
/// ~30 gated tests produces one informational line instead of thirty
/// identical ones. The single warning still attaches to whichever test
/// hit the gate first, which is enough for a maintainer to find the
/// opt-in instructions.
func mutationGatePassesOrLogsSkip() -> Bool {
    if hubMutationsAllowed() { return true }
    if mutationSkipLogger.recordOnce() {
        print(
            """
            Mutation test(s) skipped: set HFAPI_RUN_HUB_MUTATION_TESTS=1 to opt in. \
            See Tests/HFAPITests/HubMutationGate.swift for details.
            """
        )
    }
    return false
}

/// One-shot latch: returns `true` exactly once across all callers and
/// `false` thereafter. Used to deduplicate the mutation-gate skip warning
/// across a `swift test` run. `NSLock`-backed for portability across
/// Apple and Linux without pulling in `Synchronization.Mutex` (Swift 6.0+
/// Apple-only).
private final class SkipLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var logged = false

    func recordOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if logged { return false }
        logged = true
        return true
    }
}

private let mutationSkipLogger = SkipLogger()

/// Returns the value of the `HF_TOKEN` environment variable, or `nil` if it
/// isn't set. On the first nil-return per process, prints one notice so a
/// `swift test` run without a token surfaces a single "skipped" line in the
/// output instead of N silent green tests.
///
/// Tests that exercise authenticated paths (whoami, owner-scoped mutations,
/// 403 from authorization) wrap their entry with this helper:
/// ```
/// guard let token = tokenOrLogsSkip() else { return }
/// ```
/// Mirrors ``mutationGatePassesOrLogsSkip`` in tone and dedup behavior.
func tokenOrLogsSkip() -> String? {
    if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] { return token }
    if tokenSkipLogger.recordOnce() {
        print(
            """
            Token-gated test(s) skipped: set HF_TOKEN to opt in. \
            See Tests/HFAPITests/HubMutationGate.swift for details.
            """
        )
    }
    return nil
}

private let tokenSkipLogger = SkipLogger()

/// Run `body`; if it throws a transient ``HFError``, return `nil` so the
/// caller can early-`return` rather than fail the test on a network blip
/// or rate-limit response. All other thrown errors propagate.
///
/// Use the `guard let value = try await fetchOrSkip({ … }) else { return }`
/// pattern at every entry into the live-Hub network path that the test
/// doesn't itself construct.
func fetchOrSkip<T>(_ body: () async throws -> T) async throws -> T? {
    do {
        return try await body()
    } catch let error as HFError where error.isTransient {
        return nil
    }
}
