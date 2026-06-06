// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

/// A cross-platform mechanism for storing and retrieving OAuth tokens.
///
/// This provides a file-based storage implementation that works on all platforms,
/// including Linux. For Apple platforms, the ``OAuthManager``
/// provides keychain-based storage through its own ``OAuthManager/TokenStorage`` type.
///
/// Example usage:
/// ```swift
/// let storage = FileTokenStorage.default
/// try storage.store(token)
/// let retrieved = try storage.retrieve()
/// ```
public struct FileTokenStorage: Sendable {
    private let fileURL: URL

    /// Creates a new file-based token storage at the specified URL.
    /// - Parameter fileURL: The URL where tokens will be stored.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default token storage location.
    ///
    /// On Linux/Unix: `$XDG_CACHE_HOME/huggingface/token.json` if
    ///   `XDG_CACHE_HOME` is set, otherwise `~/.cache/huggingface/token.json`.
    /// On macOS / iOS: `~/Library/Caches/huggingface/token.json`
    public static var `default`: FileTokenStorage {
        let cacheDir: URL
        #if os(macOS) || os(iOS)
            cacheDir =
                FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        #else
            // Linux/Unix: Use XDG_CACHE_HOME or ~/.cache
            if let xdgCache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] {
                cacheDir = URL(fileURLWithPath: xdgCache)
            } else {
                let home =
                    ProcessInfo.processInfo.environment["HOME"]
                    ?? NSHomeDirectory()
                cacheDir = URL(fileURLWithPath: home).appendingPathComponent(".cache")
            }
        #endif

        let tokenDir = cacheDir.appendingPathComponent("huggingface")
        let tokenFile = tokenDir.appendingPathComponent("token.json")

        return FileTokenStorage(fileURL: tokenFile)
    }

    /// Stores an OAuth token to the file.
    /// - Parameter token: The token to store.
    /// - Throws: An error if the token cannot be encoded or written.
    public func store(_ token: OAuthToken) throws {
        // Create directory if needed
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // Encode the token.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(token)

        // On Unix, shrink the umask to 0o077 across the atomic write so the
        // briefly-existing temp file the OS creates as part of `.atomic`
        // never has world-readable permissions. Restoring afterwards keeps
        // unrelated callers unaffected. This closes the window between
        // `write(to:options:.atomic)` finalizing the rename and the
        // explicit `setAttributes(0o600)` below.
        #if !os(Windows)
            let previousMask = umask(0o077)
            defer { _ = umask(previousMask) }
        #endif

        try data.write(to: fileURL, options: .atomic)

        // Belt-and-suspenders: explicit chmod to 0600 after the rename so
        // the final-named file matches the contract even if the umask
        // mechanism is bypassed by a future refactor.
        #if !os(Windows)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path(percentEncoded: false)
            )
        #endif
    }

    /// Retrieves the stored OAuth token.
    /// - Returns: The stored token, or `nil` if no token is stored.
    /// - Throws: An error if the token file exists but cannot be read or decoded.
    public func retrieve() throws -> OAuthToken? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(OAuthToken.self, from: data)
    }

    /// Deletes the stored OAuth token.
    /// - Throws: An error if the token file exists but cannot be deleted.
    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Whether a token is currently stored.
    public var hasStoredToken: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }
}
