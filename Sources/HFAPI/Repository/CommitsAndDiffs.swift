// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Author entry attached to a commit. All fields are optional because the
/// Hub only surfaces what it has – a linked Hub username, or the raw
/// git name/email pair.
public struct CommitAuthor: Sendable, Equatable, Hashable {
    public let user: String?
    public let name: String?
    public let email: String?

    init(_ dto: CommitAuthorDto) {
        self.user = dto.user
        self.name = dto.name
        self.email = dto.email
    }
}

/// A single commit in a repository's history. Returned by
/// ``RepositoryProtocol/listCommits(revision:limit:)``.
public struct GitCommitInfo: Sendable, Equatable, Hashable {
    public let id: String
    public let authors: [CommitAuthor]
    /// Author/commit date parsed from the Hub's ISO-8601 timestamp. `nil`
    /// when the Hub omits the field or sends an unrecognized format.
    public let date: Date?
    public let title: String
    public let message: String
    /// HTML-formatted commit title, when the request asked the Hub to
    /// format the message.
    public let formattedTitle: String?
    /// HTML-formatted commit message, when the request asked the Hub to
    /// format the message.
    public let formattedMessage: String?
    public let parents: [String]

    init(_ dto: GitCommitInfoDto) {
        self.id = dto.id
        self.authors = dto.authors.map(CommitAuthor.init)
        self.date = parseHubTimestamp(dto.date)
        self.title = dto.title
        self.message = dto.message
        self.formattedTitle = dto.formattedTitle
        self.formattedMessage = dto.formattedMessage
        self.parents = dto.parents
    }
}

/// A single git ref (branch, tag, convert, or pull-request ref) and the
/// commit it points to.
public struct GitRefInfo: Sendable, Equatable, Hashable {
    /// Short ref name such as `"main"` or `"v1.0.0"`.
    public let name: String
    /// Full git ref name such as `"refs/heads/main"`.
    public let ref: String
    public let targetCommit: String

    init(_ dto: GitRefInfoDto) {
        self.name = dto.name
        self.ref = dto.gitRef
        self.targetCommit = dto.targetCommit
    }
}

/// All git refs on a repository – branches, tags, converts, and (when
/// requested) pull-request refs.
public struct GitRefs: Sendable, Equatable, Hashable {
    public let branches: [GitRefInfo]
    public let tags: [GitRefInfo]
    public let converts: [GitRefInfo]
    public let pullRequests: [GitRefInfo]

    init(_ dto: GitRefsDto) {
        self.branches = dto.branches.map(GitRefInfo.init)
        self.tags = dto.tags.map(GitRefInfo.init)
        self.converts = dto.converts.map(GitRefInfo.init)
        self.pullRequests = dto.pullRequests.map(GitRefInfo.init)
    }
}

/// File-level status code parsed from a raw diff entry. Mirrors the
/// single-letter git raw diff status codes.
public enum GitStatus: Sendable, Equatable, Hashable {
    case addition
    case copy
    case deletion
    case modification
    case fileTypeChange
    case rename
    case unknown
    case unmerged

    init(_ dto: GitStatusDto) {
        switch dto {
        case .addition: self = .addition
        case .copy: self = .copy
        case .deletion: self = .deletion
        case .modification: self = .modification
        case .fileTypeChange: self = .fileTypeChange
        case .rename: self = .rename
        case .unknown: self = .unknown
        case .unmerged: self = .unmerged
        }
    }
}

/// One parsed file entry from the Hub's raw diff payload.
///
/// For rename and copy entries, ``newFilePath`` contains the destination
/// path while ``filePath`` remains the source path. For additions or
/// deletions, the corresponding blob id is typically all zeroes.
public struct FileDiff: Sendable, Equatable, Hashable {
    public let oldBlobID: String
    public let newBlobID: String
    public let status: GitStatus
    public let filePath: String
    public let newFilePath: String?
    public let isBinary: Bool
    public let newFileSize: UInt64

    init(_ dto: HfFileDiffDto) {
        self.oldBlobID = dto.oldBlobId
        self.newBlobID = dto.newBlobId
        self.status = GitStatus(dto.status)
        self.filePath = dto.filePath
        self.newFilePath = dto.newFilePath
        self.isBinary = dto.isBinary
        self.newFileSize = dto.newFileSize
    }
}
