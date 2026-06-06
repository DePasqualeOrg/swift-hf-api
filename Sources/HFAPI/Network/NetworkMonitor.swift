// Copyright © Anthony DePasquale

import Foundation

#if canImport(Network)
    import Network

    /// Monitors network connectivity to determine whether requests should fall back to the local cache.
    ///
    /// The download APIs consult `NetworkMonitor` automatically when their
    /// `networkAccess:` is left at `.useIfAvailable` (the Apple default).
    /// Use the monitor directly only when you need to inspect
    /// connectivity outside of a Hub call – e.g., to gate a "Sync" button
    /// in the UI:
    ///
    /// ```swift
    /// let offline = await NetworkMonitor.shared.state.shouldUseOfflineMode()
    /// let url = try await client.model(owner: owner, name: name)
    ///     .snapshotDownload(networkAccess: offline ? .bypass : .use)
    /// ```
    ///
    /// Set the `CI_DISABLE_NETWORK_MONITOR=1` environment variable to disable
    /// offline-mode detection in CI.
    public final class NetworkMonitor: Sendable {
        private let monitor: NWPathMonitor
        private let queue: DispatchQueue

        /// The current network state.
        public let state: NetworkStateActor = .init()

        /// Shared singleton instance.
        public static let shared = NetworkMonitor()

        // `private` to enforce the singleton: a consumer constructing a
        // second `NetworkMonitor` would start a second `NWPathMonitor` and
        // dispatch queue, neither of which is reachable from the download
        // path. Access through ``shared``.
        private init() {
            monitor = NWPathMonitor()
            queue = DispatchQueue(label: "HuggingFace.NetworkMonitor")
            startMonitoring()
        }

        private func startMonitoring() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                Task {
                    await self.state.update(path: path)
                }
            }
            monitor.start(queue: queue)
            // `isConnected` defaults to `true`; an offline device may
            // report online for the first ~10 ms until the first
            // `pathUpdateHandler` fires. `monitor.currentPath` is not a
            // synchronous fix – it reports `.requiresConnection` before
            // initialization and would lie about an online device.
        }

        private func stopMonitoring() {
            monitor.cancel()
        }

        deinit {
            stopMonitoring()
        }
    }

    /// Actor that safely holds network state.
    public actor NetworkStateActor {
        /// Whether the network is connected. Assumes connected until updated.
        public private(set) var isConnected: Bool = true

        /// Whether the connection is expensive (e.g., cellular).
        public private(set) var isExpensive: Bool = false

        /// Whether the connection is constrained (e.g., Low Data Mode).
        public private(set) var isConstrained: Bool = false

        // Only `NetworkMonitor.init` constructs the actor; consumers reach
        // it through ``NetworkMonitor/state``.
        init() {}

        // Driven by ``NetworkMonitor``'s `pathUpdateHandler`. Not part of
        // the public surface – consumers read state, never write it.
        func update(path: NWPath) {
            isConnected = path.status == .satisfied
            isExpensive = path.isExpensive
            isConstrained = path.isConstrained
        }

        /// Returns whether offline mode should be used based on network state.
        public func shouldUseOfflineMode() -> Bool {
            if ProcessInfo.processInfo.environment["CI_DISABLE_NETWORK_MONITOR"] == "1" {
                return false
            }
            return !isConnected
        }
    }

// `NetworkMonitor` is intentionally Apple-only. There is no `NWPathMonitor`
// equivalent in Foundation on Linux, and a stub that always reports
// "online" would be actively misleading: a cross-platform consumer asking
// for offline detection deserves a compile error on Linux rather than a
// false-always answer at runtime. Linux consumers needing offline-aware
// behavior implement their own detection and pass `.use` / `.bypass`
// explicitly via ``NetworkAccess``. The `.useIfAvailable` case is also
// gated on `canImport(Network)`, so it doesn't appear on this platform.
#endif
