// Copyright © Anthony DePasquale

import Foundation
#if canImport(os)
    import os
#endif

/// Cross-platform logger used by `HFAPI`, `HFAPIOAuth`, and friends.
///
/// On Apple platforms forwards to `os.Logger`. On Linux there is no
/// `os` module, so messages are written to standard error with a
/// `[level subsystem/category]` prefix and a trailing newline.
///
/// The shape mirrors the small subset of `os.Logger` the library
/// actually uses: `debug`, `info`, `warning`, `error`. Messages are
/// emitted with `.public` privacy on Apple. The library intentionally
/// never logs token material or user-identifying data; callers reaching
/// for `HFLog` should follow the same rule. If a future caller needs
/// private interpolation, switch that call site to a platform-gated
/// `os.Logger` use directly rather than extending this helper – the API
/// stays a small lowest-common-denominator surface.
package struct HFLog: Sendable {
    #if canImport(os)
        private let logger: Logger
    #else
        private let subsystem: String
        private let category: String
    #endif

    package init(subsystem: String, category: String) {
        #if canImport(os)
            self.logger = Logger(subsystem: subsystem, category: category)
        #else
            self.subsystem = subsystem
            self.category = category
        #endif
    }

    package func debug(_ message: String) {
        #if canImport(os)
            logger.debug("\(message, privacy: .public)")
        #else
            emit(level: "debug", message: message)
        #endif
    }

    package func info(_ message: String) {
        #if canImport(os)
            logger.info("\(message, privacy: .public)")
        #else
            emit(level: "info", message: message)
        #endif
    }

    package func warning(_ message: String) {
        #if canImport(os)
            logger.warning("\(message, privacy: .public)")
        #else
            emit(level: "warning", message: message)
        #endif
    }

    package func error(_ message: String) {
        #if canImport(os)
            logger.error("\(message, privacy: .public)")
        #else
            emit(level: "error", message: message)
        #endif
    }

    #if !canImport(os)
        private func emit(level: String, message: String) {
            let line = "[\(level) \(subsystem)/\(category)] \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    #endif
}
