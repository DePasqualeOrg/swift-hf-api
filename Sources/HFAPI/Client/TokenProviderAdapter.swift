// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Bridges a Swift-side `@Sendable () async throws -> String?` closure to
/// the FFI's `FfiTokenProvider` protocol so the Rust facade can call back
/// across the FFI boundary to fetch the current Hub token.
///
/// Internal implementation detail of ``HFClient``. Constructed when the
/// caller selects ``Auth/provider(_:)-(_)`` or ``Auth/unauthenticated``; the
/// resulting adapter is owned by the Rust side via UniFFI's reference-
/// counting machinery.
///
/// Errors thrown by the wrapped closure are caught here, stringified via
/// `localizedDescription`, and surfaced through `TokenProviderErrorFFI` so
/// the Rust facade can convert them to ``HFError/tokenProviderFailed(message:)``
/// at the Hub-call site.
final class TokenProviderAdapter: FfiTokenProvider, @unchecked Sendable {
    // The closure is `@Sendable () async throws -> String?` – its captures
    // are therefore `Sendable`. The class wraps a single immutable `let` of
    // that type, so the storage is itself Sendable. We declare `@unchecked
    // Sendable` only because the generated `FfiTokenProvider` protocol
    // requires `AnyObject + Sendable` and Swift cannot mechanically prove
    // a non-final class with a closure-typed property is Sendable. The
    // class is `final` and the property is `let`, so the proof is
    // structural.
    let provider: @Sendable () async throws -> String?

    init(_ provider: @escaping @Sendable () async throws -> String?) {
        self.provider = provider
    }

    func getToken() async throws -> String? {
        do {
            let raw = try await provider()
            // Trim and treat empty / whitespace-only as `nil`. The static-token
            // path (`Auth.token`) rejects empty values at init; matching the
            // contract here keeps the two paths consistent so a provider that
            // returns `""` produces an unauthenticated request rather than a
            // 401-with-empty-Bearer.
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return raw
        } catch {
            throw TokenProviderErrorFfi.Failed(message: Self.message(for: error))
        }
    }

    /// `Error.localizedDescription` on a Swift error that doesn't conform to
    /// `LocalizedError` returns "The operation couldn't be completed.
    /// (MyApp.OAuthError error 0.)" – useless for diagnosis. When the wrapped
    /// error is `LocalizedError` we forward its message; otherwise we fall
    /// through to `String(describing:)` so the consumer sees the variant name
    /// and any associated payload.
    private static func message(for error: Error) -> String {
        if error is LocalizedError {
            return error.localizedDescription
        }
        return String(describing: error)
    }
}
