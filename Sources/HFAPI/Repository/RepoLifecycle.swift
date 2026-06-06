// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Repository types wrapped by this client. Mirrors a subset of the upstream
/// `RepoType` markers; used at the Swift API surface to pick which concrete
/// repository type a lifecycle call (create, delete, move) targets. Spaces
/// and kernels exist on the Hub but are intentionally not wrapped – the
/// library is scoped to model and dataset workflows.
public enum RepoType: Sendable, Hashable {
    case model
    case dataset
}

extension RepoType {
    var ffi: RepoTypeDto {
        switch self {
        case .model: .model
        case .dataset: .dataset
        }
    }
}

/// Access-gating mode for a repository. Mirrors `hf_hub::repository::GatedApprovalMode`.
public enum GatedApprovalMode: Sendable, Hashable {
    /// Access is open; no request is required.
    case disabled
    /// Access requests are approved automatically once the user accepts the terms.
    case auto
    /// Access requests must be reviewed and approved by a repo owner.
    case manual
}

extension GatedApprovalMode {
    var ffi: GatedApprovalModeDto {
        switch self {
        case .disabled: .disabled
        case .auto: .auto
        case .manual: .manual
        }
    }
}

/// Access-gating state surfaced by `info()` responses. The Hub returns the
/// `gated` field as either `false` (no gating), `"auto"`, `"manual"`, or –
/// occasionally – a future value not yet known to this library. The
/// ``unknown(_:)`` case preserves the raw JSON token so callers can opt into
/// future Hub vocabulary without a library update.
///
/// This is the read-side mirror of the Hub's `gated` field. For the
/// write side, see ``GatedApprovalMode``, which is what
/// ``RepositoryProtocol/updateSettings(private:gated:description:discussionsDisabled:gatedNotifications:)`` accepts.
public enum GatedMode: Sendable, Hashable {
    case disabled
    case auto
    case manual
    case unknown(String)

    /// Parse the raw JSON token (the value of the Hub's `gated` field
    /// surfaced as `Option<String>` from the Rust crate).
    ///
    /// The Hub uses two shapes for this field: a JSON `false` (no gating)
    /// or a JSON string (`"auto"`/`"manual"`). Decode via `JSONDecoder`
    /// rather than string-matching the raw tokens so a future Hub change
    /// (extra whitespace, alternative casing) doesn't fall through to
    /// ``unknown(_:)`` unnecessarily.
    init?(rawJSON: String?) {
        guard let rawJSON, !rawJSON.isEmpty,
            let data = rawJSON.data(using: .utf8)
        else { return nil }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            switch value {
            case .bool(false): self = .disabled
            case .string("auto"): self = .auto
            case .string("manual"): self = .manual
            default: self = .unknown(rawJSON)
            }
        } else {
            self = .unknown(rawJSON)
        }
    }
}

/// Minimal JSON-value enum used by ``GatedMode/init(rawJSON:)`` to
/// distinguish JSON `false` from a JSON string without parsing literal
/// tokens. Stored separately so the parser only handles the two shapes
/// the Hub actually sends.
private enum JSONValue: Decodable {
    case bool(Bool)
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }
}

/// Cadence for gated-access notifications.
public enum GatedNotificationsMode: Sendable, Hashable {
    /// Bundle notifications and deliver them periodically.
    case bulk
    /// Notify on every access request as it arrives.
    case realTime
}

extension GatedNotificationsMode {
    var ffi: GatedNotificationsModeDto {
        switch self {
        case .bulk: .bulk
        case .realTime: .realTime
        }
    }
}

/// Gated-notification preferences for a repository. Pass to
/// ``RepositoryProtocol/updateSettings(private:gated:description:discussionsDisabled:gatedNotifications:)``
/// via the `gatedNotifications` parameter.
public struct GatedNotifications: Sendable, Hashable {
    public let mode: GatedNotificationsMode
    /// Override email recipient. When `nil`, the existing recipient on the
    /// repository is left in place.
    public let email: String?

    public init(mode: GatedNotificationsMode, email: String? = nil) {
        self.mode = mode
        self.email = email
    }

    var ffi: GatedNotificationsDto {
        GatedNotificationsDto(mode: mode.ffi, email: email)
    }
}
