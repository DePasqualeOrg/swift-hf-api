// Copyright © Anthony DePasquale

import Foundation
import HFAPIFFI

/// Metadata for a model repository on the Hub.
///
/// Mirrors `hf_hub::ModelInfo`. Most fields are optional because they depend
/// on the `expand` parameter and the repo's state. Fields that the Hub
/// returns as free-form JSON (`cardData`, `config`, `gguf`, `modelIndex`,
/// `resourceGroup`, `securityRepoStatus`, `widgetData`, `evalResults`) are
/// surfaced as raw JSON `String`s – feed `cardData?.data(using: .utf8)`
/// into `JSONDecoder` / `JSONSerialization` to decode the schema your
/// caller cares about. Structured sub-records with a fixed schema
/// (`siblings`, `safetensors`, `transformersInfo`) are mapped to typed
/// Swift values; ``createdAt`` and ``lastModified`` are decoded from the
/// Hub's ISO-8601 timestamps to `Date`; ``gated`` is mapped to the
/// typed ``GatedMode`` enum (with raw forwarding via `.unknown`).
public struct ModelInfo: Sendable, Equatable, Hashable {
    public let id: String
    public let internalID: String?
    public let author: String?
    public let baseModels: [String]?
    public let cardData: String?
    public let childrenModelCount: UInt64?
    public let config: String?
    public let createdAt: Date?
    public let disabled: Bool?
    public let downloads: UInt64?
    public let downloadsAllTime: UInt64?
    public let evalResults: String?
    public let gated: GatedMode?
    public let gguf: String?
    public let inference: String?
    public let inferenceProviderMapping: [InferenceProviderMapping]?
    public let lastModified: Date?
    public let libraryName: String?
    public let likes: UInt64?
    public let maskToken: String?
    public let modelIndex: String?
    public let pipelineTag: String?
    public let isPrivate: Bool?
    public let resourceGroup: String?
    public let safetensors: SafeTensorsInfo?
    public let securityRepoStatus: String?
    public let sha: String?
    public let siblings: [RepoSibling]?
    public let spaces: [String]?
    public let tags: [String]?
    public let transformersInfo: TransformersInfo?
    public let trendingScore: Double?
    public let usedStorage: UInt64?
    public let widgetData: String?

    init(_ dto: ModelInfoDto) {
        self.id = dto.id
        self.internalID = dto.internalId
        self.author = dto.author
        self.baseModels = dto.baseModels
        self.cardData = dto.cardDataJson
        self.childrenModelCount = dto.childrenModelCount
        self.config = dto.configJson
        self.createdAt = parseHubTimestamp(dto.createdAt)
        self.disabled = dto.disabled
        self.downloads = dto.downloads
        self.downloadsAllTime = dto.downloadsAllTime
        self.evalResults = dto.evalResultsJson
        self.gated = GatedMode(rawJSON: dto.gatedJson)
        self.gguf = dto.ggufJson
        self.inference = dto.inference
        self.inferenceProviderMapping = dto.inferenceProviderMapping?.map(InferenceProviderMapping.init)
        self.lastModified = parseHubTimestamp(dto.lastModified)
        self.libraryName = dto.libraryName
        self.likes = dto.likes
        self.maskToken = dto.maskToken
        self.modelIndex = dto.modelIndexJson
        self.pipelineTag = dto.pipelineTag
        self.isPrivate = dto.`private`
        self.resourceGroup = dto.resourceGroupJson
        self.safetensors = dto.safetensors.map(SafeTensorsInfo.init)
        self.securityRepoStatus = dto.securityRepoStatusJson
        self.sha = dto.sha
        self.siblings = dto.siblings?.map(RepoSibling.init)
        self.spaces = dto.spaces
        self.tags = dto.tags
        self.transformersInfo = dto.transformersInfo.map(TransformersInfo.init)
        self.trendingScore = dto.trendingScore
        self.usedStorage = dto.usedStorage
        self.widgetData = dto.widgetDataJson
    }
}

public struct RepoSibling: Sendable, Equatable, Hashable {
    public let relativeFilename: String
    public let size: UInt64?
    public let lfs: BlobLfsInfo?

    init(_ dto: RepoSiblingDto) {
        self.relativeFilename = dto.rfilename
        self.size = dto.size
        self.lfs = dto.lfs.map(BlobLfsInfo.init)
    }
}

public struct BlobLfsInfo: Sendable, Equatable, Hashable {
    public let size: UInt64?
    public let sha256: String?
    public let pointerSize: UInt64?

    init(_ dto: BlobLfsInfoDto) {
        self.size = dto.size
        self.sha256 = dto.sha256
        self.pointerSize = dto.pointerSize
    }
}

public struct SafeTensorsInfo: Sendable, Equatable, Hashable {
    public let parameters: [String: UInt64]
    public let total: UInt64

    init(_ dto: SafeTensorsInfoDto) {
        self.parameters = dto.parameters
        self.total = dto.total
    }
}

public struct TransformersInfo: Sendable, Equatable, Hashable {
    public let autoModel: String
    public let customClass: String?
    public let pipelineTag: String?
    public let processor: String?

    init(_ dto: TransformersInfoDto) {
        self.autoModel = dto.autoModel
        self.customClass = dto.customClass
        self.pipelineTag = dto.pipelineTag
        self.processor = dto.processor
    }
}

public struct InferenceProviderMapping: Sendable, Equatable, Hashable {
    public let provider: String
    public let providerID: String
    public let status: String
    public let task: String
    public let adapter: String?
    public let adapterWeightsPath: String?
    public let kind: String?

    init(_ dto: InferenceProviderMappingDto) {
        self.provider = dto.provider
        self.providerID = dto.providerId
        self.status = dto.status
        self.task = dto.task
        self.adapter = dto.adapter
        self.adapterWeightsPath = dto.adapterWeightsPath
        self.kind = dto.kind
    }
}
