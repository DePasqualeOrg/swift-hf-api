// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

extension RepoType {
    /// Cache folder prefix used by Hugging Face Hub conventions:
    /// `models--owner--name` for models, `datasets--owner--name` for datasets.
    var cacheFolderPrefix: String {
        switch self {
        case .model: "models"
        case .dataset: "datasets"
        }
    }
}

/// Hugging Face Hub repository identifier in `owner/name` form.
///
/// The Hub canonicalizes every repository to a two-segment identifier. Legacy
/// pre-organization repos like `gpt2` are exposed by the Hub as
/// `openai-community/gpt2`; this type requires the namespaced form. Construct
/// from explicit parts with ``init(owner:name:)`` or parse a `"owner/name"`
/// string with ``init(_:)``.
///
/// Validation follows the same rules as Python `huggingface_hub`'s
/// `REPO_ID_REGEX` (`utils/_validators.py:28-38`): each segment is 1–96
/// characters drawn from `[A-Za-z0-9._-]`, must not start or end with `-`
/// or `.`, must not contain `--` or `..`, and the `name` segment must not
/// end with `.git`.
public struct RepositoryID: Hashable, Sendable, Codable {
    public let owner: String
    public let name: String

    /// Construct from explicit segments. Throws ``ValidationError`` if either
    /// segment violates the Hugging Face Hub naming rules.
    public init(owner: String, name: String) throws {
        try Self.validateSegment(owner, role: .owner)
        try Self.validateSegment(name, role: .name)
        self.owner = owner
        self.name = name
    }

    /// Parse `"owner/name"`. Returns `nil` if the string does not contain
    /// exactly one `/`, if either segment is empty, or if either segment
    /// fails Hugging Face Hub naming validation.
    public init?(_ rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        do {
            try self.init(owner: String(parts[0]), name: String(parts[1]))
        } catch {
            return nil
        }
    }

    /// Canonical `owner/name` representation.
    public var rawValue: String {
        "\(owner)/\(name)"
    }

    public enum ValidationError: Error, LocalizedError, Hashable, Sendable {
        case empty(role: SegmentRole)
        case tooLong(role: SegmentRole, length: Int)
        case invalidCharacter(role: SegmentRole, character: Character)
        case leadingOrTrailingDot(role: SegmentRole)
        case leadingOrTrailingHyphen(role: SegmentRole)
        case doubleHyphen(role: SegmentRole)
        case doubleDot(role: SegmentRole)
        case gitSuffix(role: SegmentRole)

        public var errorDescription: String? {
            switch self {
            case .empty(let role):
                "The \(role) segment of a repository ID must not be empty."
            case .tooLong(let role, let length):
                "The \(role) segment of a repository ID must be at most 96 characters (got \(length))."
            case .invalidCharacter(let role, let character):
                "The \(role) segment contains an invalid character '\(character)'. "
                    + "Only letters, digits, '.', '-', and '_' are allowed."
            case .leadingOrTrailingDot(let role):
                "The \(role) segment must not start or end with '.'."
            case .leadingOrTrailingHyphen(let role):
                "The \(role) segment must not start or end with '-'."
            case .doubleHyphen(let role):
                "The \(role) segment must not contain '--'."
            case .doubleDot(let role):
                "The \(role) segment must not contain '..'."
            case .gitSuffix(let role):
                "The \(role) segment must not end with '.git'."
            }
        }
    }

    public enum SegmentRole: String, Sendable, CustomStringConvertible {
        case owner
        case name

        public var description: String { rawValue }
    }

    private static func validateSegment(_ segment: String, role: SegmentRole) throws {
        do {
            try validateRepoIdSegmentFfi(segment: segment, role: role.ffiRole)
        } catch let error as RepoIdValidationErrorFfi {
            throw ValidationError(ffi: error, fallbackRole: role)
        }
    }
}

extension RepositoryID.SegmentRole {
    fileprivate var ffiRole: SegmentRoleDto {
        switch self {
        case .owner: .owner
        case .name: .name
        }
    }
}

extension RepositoryID.SegmentRole {
    fileprivate init(ffi: SegmentRoleDto) {
        self =
            switch ffi {
            case .owner: .owner
            case .name: .name
            }
    }
}

extension RepositoryID.ValidationError {
    fileprivate init(ffi: RepoIdValidationErrorFfi, fallbackRole: RepositoryID.SegmentRole) {
        switch ffi {
        case .Empty(let role):
            self = .empty(role: .init(ffi: role))
        case .TooLong(let role, let length):
            self = .tooLong(role: .init(ffi: role), length: Int(length))
        case .InvalidCharacter(let role, let character):
            // The FFI carries the offending character as a one-character string; defensively
            // fall back to a `?` placeholder if the FFI ever surfaces an empty string.
            let firstChar = character.first ?? "?"
            self = .invalidCharacter(role: .init(ffi: role), character: firstChar)
        case .LeadingOrTrailingDot(let role):
            self = .leadingOrTrailingDot(role: .init(ffi: role))
        case .LeadingOrTrailingHyphen(let role):
            self = .leadingOrTrailingHyphen(role: .init(ffi: role))
        case .DoubleHyphen(let role):
            self = .doubleHyphen(role: .init(ffi: role))
        case .DoubleDot(let role):
            self = .doubleDot(role: .init(ffi: role))
        case .GitSuffix:
            // `GitSuffix` is name-scoped on the Rust side; carry the caller's role for
            // consistency with the Swift-side enum shape.
            self = .gitSuffix(role: fallbackRole)
        }
    }
}
