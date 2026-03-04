// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

// MARK: - Datasets API

public extension HubClient {
    /// Sort fields for dataset listing.
    enum DatasetSortField: String, Hashable, CaseIterable, Sendable {
        case createdAt
        case downloads
        case lastModified
        case likes
        case trendingScore
    }

    /// Expandable dataset fields for Hub API responses.
    enum DatasetExpandField: String, Hashable, CaseIterable, Sendable {
        case author
        case cardData
        case citation
        case createdAt
        case disabled
        case description
        case downloads
        case downloadsAllTime
        case gated
        case lastModified
        case likes
        case paperswithcodeID = "paperswithcode_id"
        case `private`
        case siblings
        case sha
        case tags
        case trendingScore
        case usedStorage
        case resourceGroup
    }

    /// Lists datasets from the Hub with automatic pagination.
    ///
    /// ```swift
    /// for try await dataset in client.listDatasets(author: "huggingface") {
    ///     print(dataset.name)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - filter: Filter based on tags (e.g., `["task_categories:text-classification"]`).
    ///   - author: Filter datasets by an author or organization.
    ///   - benchmark: Filter by benchmark value.
    ///   - datasetName: Filter by full or partial dataset name (combined with `search`).
    ///   - gated: Filter by gated status.
    ///   - languageCreators: Filter by language creator categories.
    ///   - language: Filter by languages.
    ///   - multilinguality: Filter by multilinguality categories.
    ///   - sizeCategories: Filter by dataset size categories.
    ///   - taskCategories: Filter by task categories.
    ///   - taskIds: Filter by task identifiers.
    ///   - search: Filter based on substrings for repos and their usernames (combined with `datasetName`).
    ///   - sort: Property to use when sorting.
    ///   - limit: Maximum total number of datasets to return across all pages.
    ///   - expand: Fields to include in the response.
    ///   - full: Whether to fetch most dataset data, such as all tags, the files, etc.
    /// - Returns: An async sequence of datasets.
    func listDatasets(
        filter: [String]? = nil,
        author: String? = nil,
        benchmark: String? = nil,
        datasetName: String? = nil,
        gated: Bool? = nil,
        languageCreators: CommaSeparatedList<String>? = nil,
        language: CommaSeparatedList<String>? = nil,
        multilinguality: CommaSeparatedList<String>? = nil,
        sizeCategories: CommaSeparatedList<String>? = nil,
        taskCategories: CommaSeparatedList<String>? = nil,
        taskIds: CommaSeparatedList<String>? = nil,
        search: String? = nil,
        sort: DatasetSortField? = nil,
        limit: Int? = nil,
        expand: ExtensibleCommaSeparatedList<DatasetExpandField>? = nil,
        full: Bool? = nil
    ) -> PaginatedSequence<Dataset> {
        var params: [String: Value] = [:]

        // Build the filter list, matching Python's huggingface_hub behavior
        var filterList: [Value] = []
        if let filter {
            for f in filter { filterList.append(.string(f)) }
        }
        for (key, values) in [
            ("language_creators", languageCreators),
            ("language", language),
            ("multilinguality", multilinguality),
            ("size_categories", sizeCategories),
            ("task_categories", taskCategories),
            ("task_ids", taskIds),
        ] as [(String, CommaSeparatedList<String>?)] {
            if let values {
                for value in values {
                    let prefixed = value.hasPrefix("\(key):") ? value : "\(key):\(value)"
                    filterList.append(.string(prefixed))
                }
            }
        }
        if let benchmark { filterList.append(.string("benchmark:\(benchmark)")) }
        if !filterList.isEmpty { params["filter"] = .array(filterList) }

        if let author { params["author"] = .string(author) }
        if let gated { params["gated"] = .bool(gated) }
        // datasetName and search are combined into a single search list
        var searchList: [Value] = []
        if let datasetName { searchList.append(.string(datasetName)) }
        if let search { searchList.append(.string(search)) }
        if !searchList.isEmpty { params["search"] = .array(searchList) }
        if let sort { params["sort"] = .string(sort.rawValue) }
        if let limit { params["limit"] = .int(limit) }
        if let expand { params["expand"] = .array(expand.map { .string($0.rawValue) }) }
        if let full { params["full"] = .bool(full) }

        let capturedParams = params
        return PaginatedSequence(
            limit: limit,
            firstPage: { [httpClient] in
                try await httpClient.fetchPaginated(.get, "/api/datasets", params: capturedParams)
            },
            nextPage: { [httpClient] url in
                try await httpClient.fetchPaginated(.get, url: url)
            }
        )
    }

    /// Gets information for a specific dataset.
    ///
    /// - Parameters:
    ///   - id: The repository identifier (e.g., "datasets/squad").
    ///   - revision: The git revision (branch, tag, or commit hash). If nil, uses the repo's default branch (usually "main").
    ///   - expand: Fields to include in the response.
    ///   - filesMetadata: Whether to include file metadata such as blob information.
    /// - Returns: Information about the dataset.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func getDataset(
        _ id: Repo.ID,
        revision: String? = nil,
        expand: ExtensibleCommaSeparatedList<DatasetExpandField>? = nil,
        filesMetadata: Bool? = nil
    ) async throws -> Dataset {
        var url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
        if let revision {
            url =
                url
                .appending(path: "revision")
                .appending(component: revision)
        }

        var params: [String: Value] = [:]
        if let expand { params["expand"] = .string(expand.rawValue) }
        if let filesMetadata, filesMetadata { params["blobs"] = .bool(true) }

        return try await httpClient.fetch(.get, url: url, params: params)
    }

    /// Gets all available dataset tags hosted in the Hub.
    ///
    /// - Returns: Tag information organized by type.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func getDatasetTags() async throws -> Tags {
        return try await httpClient.fetch(.get, "/api/datasets-tags-by-type")
    }

    /// Lists Parquet files for a dataset.
    ///
    /// - Parameters:
    ///   - id: The repository identifier.
    ///   - subset: Optional subset/configuration name.
    ///   - split: Optional split name.
    /// - Returns: List of Parquet file information.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func listParquetFiles(
        _ id: Repo.ID,
        subset: String? = nil,
        split: String? = nil
    ) async throws -> [ParquetFileInfo] {
        var path = "/api/datasets/\(id.namespace)/\(id.name)/parquet"

        if let subset {
            path += "/\(subset)"
            if let split {
                path += "/\(split)"
            }
        }

        return try await httpClient.fetch(.get, path)
    }

    // MARK: - Dataset Access Requests

    /// Requests access to a gated dataset repository.
    ///
    /// - Parameters:
    ///   - id: The repository identifier.
    ///   - reason: The reason for requesting access.
    ///   - institution: The institution associated with the request.
    /// - Returns: `true` if the request was submitted successfully.
    /// - Throws: An error if the request fails.
    func requestDatasetAccess(
        _ id: Repo.ID,
        reason: String? = nil,
        institution: String? = nil
    ) async throws -> Bool {
        let path = "/datasets/\(id.namespace)/\(id.name)/ask-access"
        var params: [String: Value] = [:]
        if let reason { params["reason"] = .string(reason) }
        if let institution { params["institution"] = .string(institution) }
        let result: Bool = try await httpClient.fetch(.post, path, params: params)
        return result
    }

    /// Cancels the current user's access request to a gated dataset repository.
    ///
    /// - Parameter id: The repository identifier.
    /// - Returns: `true` if the request was cancelled successfully.
    /// - Throws: An error if the request fails.
    func cancelDatasetAccessRequest(_ id: Repo.ID) async throws -> Bool {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "user-access-request")
            .appending(path: "cancel")
        let result: Bool = try await httpClient.fetch(.post, url: url)
        return result
    }

    /// Grants access to a user for a gated dataset repository.
    ///
    /// - Parameter id: The repository identifier.
    /// - Returns: `true` if access was granted successfully.
    /// - Throws: An error if the request fails.
    func grantDatasetAccess(_ id: Repo.ID) async throws -> Bool {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "user-access-request")
            .appending(path: "grant")
        let result: Bool = try await httpClient.fetch(.post, url: url)
        return result
    }

    /// Handles an access request for a gated dataset repository.
    ///
    /// - Parameter id: The repository identifier.
    /// - Returns: `true` if the request was handled successfully.
    /// - Throws: An error if the request fails.
    func handleDatasetAccessRequest(_ id: Repo.ID) async throws -> Bool {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "user-access-request")
            .appending(path: "handle")
        let result: Bool = try await httpClient.fetch(.post, url: url)
        return result
    }

    /// Lists access requests for a gated dataset repository.
    ///
    /// - Parameters:
    ///   - id: The repository identifier.
    ///   - status: The status to filter by ("pending", "accepted", "rejected").
    /// - Returns: A list of access requests.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func listDatasetAccessRequests(
        _ id: Repo.ID,
        status: AccessRequest.Status
    ) async throws -> [AccessRequest] {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "user-access-request")
            .appending(path: status.rawValue)
        return try await httpClient.fetch(.get, url: url)
    }

    /// Gets user access report for a dataset repository.
    ///
    /// - Parameter id: The repository identifier.
    /// - Returns: User access report data.
    /// - Throws: An error if the request fails.
    func getDatasetUserAccessReport(_ id: Repo.ID) async throws -> Data {
        let url = httpClient.host
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "user-access-report")
        return try await httpClient.fetchData(.get, url: url)
    }

    // MARK: - Dataset Advanced Features

    /// Sets the resource group for a dataset repository.
    ///
    /// - Parameters:
    ///   - id: The repository identifier.
    ///   - resourceGroupId: The resource group ID to set, or nil to unset.
    /// - Returns: Resource group response information.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func setDatasetResourceGroup(
        _ id: Repo.ID,
        resourceGroupId: String?
    ) async throws -> ResourceGroup {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "resource-group")

        let params: [String: Value] = [
            "resourceGroupId": resourceGroupId.map { .string($0) } ?? .null
        ]

        return try await httpClient.fetch(.post, url: url, params: params)
    }

    /// Scans a dataset repository.
    ///
    /// - Parameter id: The repository identifier.
    /// - Returns: `true` if the scan was initiated successfully.
    /// - Throws: An error if the request fails.
    func scanDataset(_ id: Repo.ID) async throws -> Bool {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "scan")
        let result: Bool = try await httpClient.fetch(.post, url: url)
        return result
    }

    /// Creates a new tag for a dataset repository.
    ///
    /// - Parameters:
    ///   - id: The repository identifier.
    ///   - revision: The git revision to tag.
    ///   - tag: The name of the tag to create.
    ///   - message: An optional message for the tag.
    /// - Returns: `true` if the tag was created successfully.
    /// - Throws: An error if the request fails.
    func createDatasetTag(
        _ id: Repo.ID,
        revision: String,
        tag: String,
        message: String? = nil
    ) async throws -> Bool {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "tag")
            .appending(component: revision)

        let params: [String: Value] = [
            "tag": .string(tag),
            "message": message.map { .string($0) } ?? .null,
        ]

        let result: Bool = try await httpClient.fetch(.post, url: url, params: params)
        return result
    }

    /// Super-squashes commits in a dataset repository.
    ///
    /// - Parameters:
    ///   - id: The repository identifier.
    ///   - revision: The git revision to squash.
    ///   - message: The commit message for the squashed commit.
    /// - Returns: The new commit ID.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func superSquashDataset(
        _ id: Repo.ID,
        revision: String,
        message: String
    ) async throws -> String {
        let url = httpClient.host
            .appending(path: "api")
            .appending(path: "datasets")
            .appending(path: id.namespace)
            .appending(path: id.name)
            .appending(path: "super-squash")
            .appending(component: revision)

        let params: [String: Value] = [
            "message": .string(message)
        ]

        struct Response: Decodable { let commitID: String }
        let resp: Response = try await httpClient.fetch(.post, url: url, params: params)
        return resp.commitID
    }
}
