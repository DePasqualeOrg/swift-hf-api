// Copyright © Anthony DePasquale

import Foundation

/// ISO-8601 parser used at the DTO→Swift boundary for Hub timestamp
/// fields. The Hub returns timestamps with fractional seconds and a `Z`
/// timezone suffix (e.g., `"2023-11-08T12:34:56.789Z"`). The standard
/// `.iso8601` formatter doesn't handle fractional seconds; the
/// `.withInternetDateTime`/`.withFractionalSeconds` options do. We try
/// the fractional formatter first and fall back to the plain one for
/// forward compatibility.
///
/// Returns `nil` for malformed input. We don't log – a listing of 1000
/// entries with bad timestamps would emit 1000 warnings, and the `Date?`
/// return already encodes "didn't parse" for any caller that cares. The
/// sibling parser ``parseCommitURL(_:)`` does log because it is called
/// once per `CommitInfo`, not 1000 times in a listing.
///
/// `ISO8601DateFormatter` is documented as thread-safe (its underlying
/// `CFDateFormatter` is) but the type isn't marked `Sendable` – hence
/// the `nonisolated(unsafe)` annotation on the cached singletons.
func parseHubTimestamp(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    if let date = hubTimestampWithFractional.date(from: raw) { return date }
    return hubTimestampPlain.date(from: raw)
}

nonisolated(unsafe) private let hubTimestampWithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

nonisolated(unsafe) private let hubTimestampPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
