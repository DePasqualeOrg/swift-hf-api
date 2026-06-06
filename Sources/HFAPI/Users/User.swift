// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Whether a Hugging Face Hub account is a personal user or an
/// organization, surfaced from the Hub's `userType` field. The
/// ``other(_:)`` case preserves the raw token for any future account
/// shape this library doesn't yet classify.
public enum UserType: Sendable, Equatable, Hashable {
    case user
    case organization
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "org": self = .organization
        default: self = .other(rawValue)
        }
    }
}

/// A Hugging Face Hub user account.
///
/// Mirrors `hf_hub::users::User`. Only ``username`` is guaranteed to be set;
/// the remaining fields populate based on whether the caller is looking at
/// their own ``HFClient/currentUser()`` response or another user's publicly
/// visible profile. Fields like ``email``, ``emailVerified``, ``plan``,
/// ``canPay``, and ``orgs`` are only returned for the authenticated user.
public struct User: Sendable, Equatable, Hashable {
    public let username: String
    public let fullname: String?
    public let avatarURL: String?
    public let userType: UserType?
    public let details: String?
    public let isFollowing: Bool?
    public let isPro: Bool?
    public let numModels: UInt64?
    public let numDatasets: UInt64?
    public let numSpaces: UInt64?
    public let numDiscussions: UInt64?
    public let numPapers: UInt64?
    public let numUpvotes: UInt64?
    public let numLikes: UInt64?
    public let numFollowing: UInt64?
    public let numFollowers: UInt64?
    public let email: String?
    public let emailVerified: Bool?
    public let plan: String?
    public let canPay: Bool?
    public let orgs: [OrgMembership]?

    init(_ dto: UserDto) {
        self.username = dto.username
        self.fullname = dto.fullname
        self.avatarURL = dto.avatarUrl
        self.userType = dto.userType.map(UserType.init(rawValue:))
        self.details = dto.details
        self.isFollowing = dto.isFollowing
        self.isPro = dto.isPro
        self.numModels = dto.numModels
        self.numDatasets = dto.numDatasets
        self.numSpaces = dto.numSpaces
        self.numDiscussions = dto.numDiscussions
        self.numPapers = dto.numPapers
        self.numUpvotes = dto.numUpvotes
        self.numLikes = dto.numLikes
        self.numFollowing = dto.numFollowing
        self.numFollowers = dto.numFollowers
        self.email = dto.email
        self.emailVerified = dto.emailVerified
        self.plan = dto.plan
        self.canPay = dto.canPay
        self.orgs = dto.orgs?.map(OrgMembership.init)
    }
}

/// Summary entry for an organization the authenticated user belongs to.
///
/// Returned inside ``User/orgs`` from ``HFClient/currentUser()``.
public struct OrgMembership: Sendable, Equatable, Hashable {
    public let name: String?
    public let fullname: String?
    public let avatarURL: String?

    init(_ dto: OrgMembershipDto) {
        self.name = dto.name
        self.fullname = dto.fullname
        self.avatarURL = dto.avatarUrl
    }
}
