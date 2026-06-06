// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Metadata for a dataset repository on the Hub.
///
/// Mirrors `hf_hub::DatasetInfo`. JSON-typed fields (`cardData`,
/// `resourceGroup`) surface as raw JSON `String`s – feed
/// `cardData?.data(using: .utf8)` into `JSONDecoder` /
/// `JSONSerialization` to decode. Structured sub-records (`siblings`)
/// reuse the ``RepoSibling`` type defined in `ModelInfo.swift`;
/// timestamps are decoded to `Date`; `gated` maps to the typed
/// ``GatedMode`` enum.
public struct DatasetInfo: Sendable, Equatable, Hashable {
    public let id: String
    public let internalID: String?
    public let author: String?
    public let sha: String?
    public let isPrivate: Bool?
    public let gated: GatedMode?
    public let disabled: Bool?
    public let downloads: UInt64?
    public let downloadsAllTime: UInt64?
    public let likes: UInt64?
    public let tags: [String]?
    public let createdAt: Date?
    public let lastModified: Date?
    public let siblings: [RepoSibling]?
    public let cardData: String?
    public let citation: String?
    public let papersWithCodeID: String?
    public let resourceGroup: String?
    public let trendingScore: Double?
    public let description: String?
    public let usedStorage: UInt64?

    init(_ dto: DatasetInfoDto) {
        self.id = dto.id
        self.internalID = dto.internalId
        self.author = dto.author
        self.sha = dto.sha
        self.isPrivate = dto.`private`
        self.gated = GatedMode(rawJSON: dto.gatedJson)
        self.disabled = dto.disabled
        self.downloads = dto.downloads
        self.downloadsAllTime = dto.downloadsAllTime
        self.likes = dto.likes
        self.tags = dto.tags
        self.createdAt = parseHubTimestamp(dto.createdAt)
        self.lastModified = parseHubTimestamp(dto.lastModified)
        self.siblings = dto.siblings?.map(RepoSibling.init)
        self.cardData = dto.cardDataJson
        self.citation = dto.citation
        self.papersWithCodeID = dto.paperswithcodeId
        self.resourceGroup = dto.resourceGroupJson
        self.trendingScore = dto.trendingScore
        self.description = dto.description
        self.usedStorage = dto.usedStorage
    }
}
