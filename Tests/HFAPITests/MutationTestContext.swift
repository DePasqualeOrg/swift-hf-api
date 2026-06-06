// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Shared setup for live-Hub mutation tests. Wraps the mutation-gate check,
/// the `whoami` probe that names a unique-per-user repo prefix, and the
/// best-effort cleanup pattern that every mutation suite needs.
///
/// Every mutation suite (lifecycle, upload, upload-folder, create-commit,
/// branches/tags, delete-file) used to duplicate this scaffolding. The
/// duplicates drifted in subtle ways – some passed `kind` through, some
/// hardcoded `.model`, some did multi-repo cleanup, some didn't – and a
/// future maintainer fixing one had to remember to fix all six. Folding
/// them into one helper here makes that class of drift impossible.
struct MutationTestContext: Sendable {
    let client: HFClient
    let username: String
    let repoPrefix: String

    struct FreshModelRepo {
        let repo: ModelRepository
        let repoID: String
    }

    /// Build the context if the mutation gate is open and a usable token is
    /// configured. Returns `nil` to signal a clean test skip in both cases.
    ///
    /// - Parameter prefix: A short identifier embedded in the per-test repo
    ///   name. Helps an operator inspecting a leaked repo on the Hub
    ///   identify which suite created it.
    static func makeOrSkip(prefix: String) async throws -> MutationTestContext? {
        guard mutationGatePassesOrLogsSkip() else { return nil }
        let client: HFClient
        do {
            client = try HFClient()
        } catch {
            return nil
        }
        do {
            let user = try await client.currentUser()
            return MutationTestContext(
                client: client,
                username: user.username,
                repoPrefix: prefix
            )
        } catch let error as HFError {
            switch error {
            case .authRequired, .http, .request:
                return nil
            default:
                throw error
            }
        }
    }

    /// Generate a unique repo ID under the authenticated user's namespace,
    /// with a random 8-char suffix so concurrent runs don't collide.
    func uniqueRepoID() -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(username)/swift-hf-api-test-\(repoPrefix)-\(suffix)"
    }

    /// Strip the `owner/` prefix from a repo ID.
    func shortName(_ repoID: String) -> String {
        if let slash = repoID.firstIndex(of: "/") {
            return String(repoID[repoID.index(after: slash)...])
        }
        return repoID
    }

    /// Create a fresh empty model repo and return a typed handle for it.
    func makeFreshModelRepo() async throws -> FreshModelRepo {
        let repoID = uniqueRepoID()
        try await client.createRepository(type: .model, repoID: repoID, private: true)
        let name = shortName(repoID)
        return FreshModelRepo(repo: client.model(owner: username, name: name), repoID: repoID)
    }

    /// Best-effort cleanup; swallows transport errors and missing-repo 404s.
    /// Always awaited via `runWithCleanup(...)` – `defer { Task { … } }`
    /// would race the test return and let deletions outlive the process,
    /// leaking repos on the live Hub.
    func deleteIfPresent(repoID: String, type: RepoType = .model) async {
        try? await client.deleteRepository(
            type: type,
            repoID: repoID,
            missingOk: true
        )
    }

    /// Run `body`, then await deletion of every repo in `repoIDs` —
    /// regardless of whether `body` threw. Any thrown error is re-raised
    /// after cleanup so the surrounding test still fails, but Hub-side
    /// state is reset before the test process exits.
    func runWithCleanup<T>(
        repoIDs: [String],
        type: RepoType = .model,
        body: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await body()
            for id in repoIDs {
                await deleteIfPresent(repoID: id, type: type)
            }
            return result
        } catch {
            for id in repoIDs {
                await deleteIfPresent(repoID: id, type: type)
            }
            throw error
        }
    }

    /// Single-repo convenience for the common case.
    func runWithCleanup<T>(
        repoID: String,
        type: RepoType = .model,
        body: () async throws -> T
    ) async throws -> T {
        try await runWithCleanup(repoIDs: [repoID], type: type, body: body)
    }
}
