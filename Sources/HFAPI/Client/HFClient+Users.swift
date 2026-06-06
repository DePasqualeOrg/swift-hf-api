// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

extension HFClient {
    /// Fetch the profile of the user that owns the current token.
    ///
    /// Returns the authenticated ``User``, including private fields like
    /// ``User/email`` and the caller's ``User/orgs`` list. Throws
    /// ``HFError/authRequired(context:)`` when no valid token is configured.
    ///
    /// Endpoint: `GET /api/whoami-v2`.
    public func currentUser() async throws -> User {
        try await mapHFError { User(try await ffi.whoami()) }
    }
}
