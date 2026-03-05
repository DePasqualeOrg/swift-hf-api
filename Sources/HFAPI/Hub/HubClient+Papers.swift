// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

// MARK: - Papers API

public extension HubClient {
    /// Lists papers from the Hub with automatic pagination.
    ///
    /// ```swift
    /// for try await paper in client.listPapers(search: "diffusion") {
    ///     print(paper.title)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - search: Search term to filter papers.
    ///   - sort: Property to use when sorting (e.g., "trending", "updated").
    ///   - limit: Maximum total number of papers to return across all pages.
    /// - Returns: An async sequence of papers.
    func listPapers(
        search: String? = nil,
        sort: String? = nil,
        limit: Int? = nil
    ) -> PaginatedSequence<Paper> {
        var params: [String: Value] = [:]

        if let search { params["search"] = .string(search) }
        if let sort { params["sort"] = .string(sort) }
        if let limit { params["limit"] = .int(limit) }

        let capturedParams = params
        return PaginatedSequence(
            limit: limit,
            firstPage: { [httpClient] in
                try await httpClient.fetchPaginated(.get, "/api/papers", params: capturedParams)
            },
            nextPage: { [httpClient] url in
                try await httpClient.fetchPaginated(.get, url: url)
            }
        )
    }

    /// Gets information for a specific paper.
    ///
    /// - Parameter id: The paper's identifier (e.g., arXiv ID like "2103.00020").
    /// - Returns: Information about the paper.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func getPaper(_ id: String) async throws -> Paper {
        return try await httpClient.fetch(.get, "/api/papers/\(id)")
    }

    /// Lists daily papers from the Hub.
    ///
    /// - Parameters:
    ///   - page: Page number for pagination. If omitted, server default is 0.
    ///   - limit: Number of papers per page. If omitted, server default is 50 (max: 100).
    ///   - date: Filter by specific date (YYYY-MM-DD format).
    ///   - week: Filter by specific week (YYYY-WXX format).
    ///   - month: Filter by specific month (YYYY-MM format).
    ///   - submitter: Filter by submitter username.
    ///   - sort: Sort order ("publishedAt" or "trending"). If omitted, server default is "publishedAt".
    /// - Returns: An array of daily papers.
    /// - Throws: An error if the request fails or the response cannot be decoded.
    func listDailyPapers(
        page: Int? = nil,
        limit: Int? = nil,
        date: String? = nil,
        week: String? = nil,
        month: String? = nil,
        submitter: String? = nil,
        sort: String? = nil
    ) async throws -> [DailyPaper] {
        var params: [String: Value] = [:]

        if let page { params["p"] = .int(page) }
        if let limit { params["limit"] = .int(limit) }
        if let date { params["date"] = .string(date) }
        if let week { params["week"] = .string(week) }
        if let month { params["month"] = .string(month) }
        if let submitter { params["submitter"] = .string(submitter) }
        if let sort { params["sort"] = .string(sort) }

        return try await httpClient.fetch(.get, "/api/daily_papers", params: params)
    }
}
