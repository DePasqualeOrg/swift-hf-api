// Copyright © Anthony DePasquale

import Foundation

/// Resolves the on-disk cache directory passed to the Rust-backed ``HFClient``.
///
/// Path discovery is owned by Swift on Apple platforms because the platform default
/// depends on whether the host app runs in an App Sandbox container – a fact the
/// Rust crate cannot detect on its own. Resolution order:
///
/// 1. `HF_HUB_CACHE` env var, if set and writable by the current process.
/// 2. `HF_HOME` env var with `/hub` appended, same writability gate.
/// 3. Sandbox-aware default: `~/.cache/huggingface/hub` for non-sandboxed processes,
///    the app container's `Library/Caches/huggingface/hub` for sandboxed Apple apps.
///
/// The writability gate matters because in sandboxed apps the env-var path may exist
/// but be unreachable; silently falling back is better than letting Rust attempt I/O
/// against an unreachable path.
public enum CachePathResolver {
    /// The user caches directory, resolved cross-platform. `URL.cachesDirectory`
    /// is Apple-only; the `FileManager` search-path API works on both Apple
    /// Foundation and swift-corelibs-foundation (Linux → `$XDG_CACHE_HOME` or
    /// `~/.cache`), and still respects the App Sandbox container on Apple
    /// platforms. Falls back to `~/.cache` if the lookup fails.
    public static var platformCachesDirectory: URL {
        (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ))
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cache")
    }

    /// Resolves the cache directory using the precedence rule above.
    ///
    /// - Parameters:
    ///   - env: Process environment to read. Defaults to `ProcessInfo.processInfo.environment`.
    ///   - homeDirectory: Home directory used by the non-sandboxed default. Injectable for tests.
    ///   - cachesDirectory: Caches directory used by the sandboxed default. Injectable for tests.
    ///   - fileManager: File manager used to test writability. Injectable for tests.
    /// - Returns: The cache directory URL.
    public static func resolve(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        cachesDirectory: URL = platformCachesDirectory,
        fileManager: FileManager = .default
    ) -> URL {
        if let envURL = expandedURL(from: env["HF_HUB_CACHE"]),
            isWritable(envURL, fileManager: fileManager)
        {
            return envURL
        }

        if let hfHome = expandedURL(from: env["HF_HOME"]) {
            let candidate = hfHome.appendingPathComponent("hub")
            if isWritable(candidate, fileManager: fileManager) {
                return candidate
            }
        }

        return defaultCacheDirectory(
            environment: env,
            homeDirectory: homeDirectory,
            cachesDirectory: cachesDirectory
        )
    }

    /// Returns the platform default cache directory, ignoring the env-var precedence above.
    static func defaultCacheDirectory(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        cachesDirectory: URL = platformCachesDirectory
    ) -> URL {
        #if os(macOS)
            let isSandboxed = env["APP_SANDBOX_CONTAINER_ID"] != nil
            if isSandboxed {
                return
                    cachesDirectory
                    .appendingPathComponent("huggingface")
                    .appendingPathComponent("hub")
            }
            return
                homeDirectory
                .appendingPathComponent(".cache")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
        #else
            return
                cachesDirectory
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
        #endif
    }

    private static func expandedURL(from value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let expanded = NSString(string: value).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Returns true when the directory exists and is writable, or when its nearest
    /// existing parent is writable (so a yet-to-be-created leaf still counts).
    private static func isWritable(_ url: URL, fileManager: FileManager) -> Bool {
        var probe = url
        while !fileManager.fileExists(atPath: probe.path(percentEncoded: false)) {
            let parent = probe.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == probe.path(percentEncoded: false) {
                return false
            }
            probe = parent
        }
        return fileManager.isWritableFile(atPath: probe.path(percentEncoded: false))
    }
}
