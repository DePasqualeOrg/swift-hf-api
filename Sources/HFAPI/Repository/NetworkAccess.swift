// Copyright © Anthony DePasquale

import Foundation

/// Controls whether a download call may touch the network on a cache
/// miss. The cache-hit fast path is identical across all cases — this
/// only affects behavior when the requested file is not already cached
/// locally.
///
/// Replaces the pre-0.4.0 tristate `localFilesOnly: Bool?` where `nil`
/// triggered automatic detection, `true` forced cache-only, and `false`
/// forced network. Named cases read more clearly than a `Bool?` at every
/// call site.
public enum NetworkAccess: Sendable, Equatable, Hashable {
    /// Use the network. On a cache miss, fetch from the Hub.
    case use
    /// Bypass the network. On a cache miss, throw
    /// ``HFError/localEntryNotFound(path:)``; the Hub is never contacted.
    case bypass
    #if canImport(Network)
        /// Consult ``NetworkMonitor`` and behave as ``use`` when the
        /// network is reachable, ``bypass`` when it isn't.
        ///
        /// Apple-only. The case is gated by `canImport(Network)`
        /// because the detection is backed by `NWPathMonitor`, which
        /// has no portable Linux equivalent. Linux consumers who want
        /// connectivity-aware behavior can implement their own check
        /// and pass ``use`` or ``bypass`` accordingly.
        case useIfAvailable
    #endif
}

extension NetworkAccess {
    /// Platform-appropriate default for download calls.
    /// ``useIfAvailable`` on Apple (auto-detect via
    /// ``NetworkMonitor``); ``use`` on Linux, where the case isn't
    /// available because there's no portable connectivity API to back
    /// it. Linux consumers wanting cache-only or app-driven
    /// connectivity handling should pass ``bypass`` or ``use``
    /// explicitly.
    #if canImport(Network)
        public static let `default`: NetworkAccess = .useIfAvailable
    #else
        public static let `default`: NetworkAccess = .use
    #endif
}
