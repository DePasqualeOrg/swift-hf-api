// Copyright © Hugging Face SAS
// Copyright © Anthony DePasquale

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@testable import HFAPI

#if swift(>=6.1)
    @Suite("Dataset Tests", .serialized)
    struct DatasetTests {
        /// Helper to create a URL session with mock protocol handlers
        func createMockClient() -> HubClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: configuration)
            return HubClient(
                session: session,
                host: URL(string: "https://huggingface.co")!,
                userAgent: "TestClient/1.0"
            )
        }

        @Test("List datasets with no parameters", .mockURLSession)
        func testListDatasets() async throws {
            let url = URL(string: "https://huggingface.co/api/datasets")!

            let mockResponse = """
                [
                    {
                        "id": "datasets/squad",
                        "author": "datasets",
                        "downloads": 500000,
                        "likes": 250
                    },
                    {
                        "id": "stanfordnlp/imdb",
                        "author": "stanfordnlp",
                        "downloads": 300000,
                        "likes": 150
                    }
                ]
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets")
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            var datasets: [Dataset] = []
            for try await dataset in client.listDatasets() {
                datasets.append(dataset)
            }

            #expect(datasets.count == 2)
            #expect(datasets[0].id == "datasets/squad")
            #expect(datasets[0].author == "datasets")
            #expect(datasets[1].id == "stanfordnlp/imdb")
        }

        @Test("List datasets with search parameter", .mockURLSession)
        func testListDatasetsWithSearch() async throws {
            let mockResponse = """
                [
                    {
                        "id": "datasets/squad",
                        "author": "datasets",
                        "downloads": 500000,
                        "likes": 250
                    }
                ]
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets")
                #expect(request.url?.query?.contains("search=squad") == true)

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            var datasets: [Dataset] = []
            for try await dataset in client.listDatasets(search: "squad") {
                datasets.append(dataset)
            }

            #expect(datasets.count == 1)
            #expect(datasets[0].id == "datasets/squad")
        }

        @Test("List datasets with additional query parameters", .mockURLSession)
        func testListDatasetsWithAdditionalParameters() async throws {
            let mockResponse = """
                [
                    {
                        "id": "datasets/squad"
                    }
                ]
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets")

                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []

                // datasetName is folded into search
                #expect(queryItems.contains { $0.name == "search" && $0.value == "squad" })

                // languageCreators and sizeCategories are encoded as repeated filter params
                let filterValues = queryItems.filter { $0.name == "filter" }.compactMap(\.value)
                #expect(filterValues.contains("language_creators:crowdsourced"))
                #expect(filterValues.contains("size_categories:10K<n<100K"))

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            var datasets: [Dataset] = []
            for try await dataset in client.listDatasets(
                datasetName: "squad",
                languageCreators: ["crowdsourced"],
                sizeCategories: ["10K<n<100K"]
            ) {
                datasets.append(dataset)
            }

            #expect(datasets.count == 1)
        }

        @Test("Get specific dataset", .mockURLSession)
        func testGetDataset() async throws {
            let mockResponse = """
                {
                    "id": "_/squad",
                    "author": "datasets",
                    "downloads": 500000,
                    "likes": 250,
                    "tags": ["question-answering"]
                }
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets/_/squad")
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "_/squad"
            let dataset = try await client.getDataset(repoID)

            #expect(dataset.id == "_/squad")
            #expect(dataset.author == "datasets")
            #expect(dataset.downloads == 500000)
        }

        @Test("Get dataset with namespace", .mockURLSession)
        func testGetDatasetWithNamespace() async throws {
            let mockResponse = """
                {
                    "id": "huggingface/squad",
                    "author": "huggingface",
                    "downloads": 500000,
                    "likes": 250
                }
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets/huggingface/squad")
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "huggingface/squad"
            let dataset = try await client.getDataset(repoID)

            #expect(dataset.id == "huggingface/squad")
            #expect(dataset.author == "huggingface")
        }

        @Test("Get dataset tags", .mockURLSession)
        func testGetDatasetTags() async throws {
            // Mock response matches real API format (no "tags" wrapper)
            let mockResponse = """
                {
                    "task_categories": [
                        {"id": "question-answering", "label": "Question Answering", "type": "task_categories"},
                        {"id": "text-classification", "label": "Text Classification", "type": "task_categories"}
                    ],
                    "languages": [
                        {"id": "en", "label": "English", "type": "languages"},
                        {"id": "fr", "label": "French", "type": "languages"}
                    ]
                }
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets-tags-by-type")
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let tags = try await client.getDatasetTags()

            #expect(tags["task_categories"]?.count == 2)
            #expect(tags["languages"]?.count == 2)
        }

        // The Hub parquet endpoint returns different response shapes:
        // - No args: {config: {split: [urls]}}
        // - Subset only: {split: [urls]}
        // - Subset + split: [urls]

        @Test("List parquet files without parameters", .mockURLSession)
        func testListParquetFiles() async throws {
            let mockResponse = """
                {
                    "ParaphraseRC": {
                        "test": [
                            "https://huggingface.co/api/datasets/ibm/duorc/parquet/ParaphraseRC/test/0.parquet"
                        ],
                        "train": [
                            "https://huggingface.co/api/datasets/ibm/duorc/parquet/ParaphraseRC/train/0.parquet"
                        ]
                    },
                    "SelfRC": {
                        "test": [
                            "https://huggingface.co/api/datasets/ibm/duorc/parquet/SelfRC/test/0.parquet"
                        ]
                    }
                }
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets/ibm/duorc/parquet")
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "ibm/duorc"
            let files = try await client.listParquetFiles(repoID)

            #expect(files.count == 3)
            let configs = Set(files.map(\.config))
            #expect(configs == ["ParaphraseRC", "SelfRC"])
        }

        @Test("List parquet files with subset", .mockURLSession)
        func testListParquetFilesWithSubset() async throws {
            let mockResponse = """
                {
                    "test": [
                        "https://huggingface.co/api/datasets/ibm/duorc/parquet/ParaphraseRC/test/0.parquet"
                    ],
                    "train": [
                        "https://huggingface.co/api/datasets/ibm/duorc/parquet/ParaphraseRC/train/0.parquet"
                    ]
                }
                """

            await MockURLProtocol.setHandler { request in
                #expect(request.url?.path == "/api/datasets/ibm/duorc/parquet/ParaphraseRC")
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "ibm/duorc"
            let files = try await client.listParquetFiles(repoID, subset: "ParaphraseRC")

            #expect(files.count == 2)
            let splits = Set(files.map(\.split))
            #expect(splits == ["test", "train"])
        }

        @Test("List parquet files with subset and split", .mockURLSession)
        func testListParquetFilesWithSubsetAndSplit() async throws {
            let mockResponse = """
                [
                    "https://huggingface.co/api/datasets/ibm/duorc/parquet/ParaphraseRC/train/0.parquet"
                ]
                """

            await MockURLProtocol.setHandler { request in
                #expect(
                    request.url?.path == "/api/datasets/ibm/duorc/parquet/ParaphraseRC/train"
                )
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "ibm/duorc"
            let files = try await client.listParquetFiles(
                repoID,
                subset: "ParaphraseRC",
                split: "train"
            )

            #expect(files.count == 1)
            #expect(files[0].dataset == "duorc")
            #expect(files[0].config == "ParaphraseRC")
            #expect(files[0].split == "train")
            #expect(files[0].filename == "0.parquet")
        }

        @Test("List parquet files with multiple shards", .mockURLSession)
        func testListParquetFilesWithMultipleShards() async throws {
            let mockResponse = """
                [
                    "https://huggingface.co/api/datasets/fancyzhx/amazon_polarity/parquet/amazon_polarity/train/0.parquet",
                    "https://huggingface.co/api/datasets/fancyzhx/amazon_polarity/parquet/amazon_polarity/train/1.parquet"
                ]
                """

            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let files = try await client.listParquetFiles(
                "fancyzhx/amazon_polarity",
                subset: "amazon_polarity",
                split: "train"
            )

            #expect(files.count == 2)
            #expect(files[0].filename == "0.parquet")
            #expect(files[1].filename == "1.parquet")
        }

        @Test("Reject malformed parquet URL", .mockURLSession)
        func testListParquetFilesWithMalformedURL() async throws {
            // Missing "parquet" segment in URL path
            let mockResponse = """
                [
                    "https://huggingface.co/api/datasets/ankislyakov/titanic/default/train/0.parquet"
                ]
                """

            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(mockResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "ankislyakov/titanic"

            await #expect(throws: HTTPClientError.self) {
                _ = try await client.listParquetFiles(
                    repoID,
                    subset: "default",
                    split: "train"
                )
            }
        }

        @Test("Handle 404 error for dataset", .mockURLSession)
        func testGetDatasetNotFound() async throws {
            let errorResponse = """
                {
                    "error": "Dataset not found"
                }
                """

            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!

                return (response, Data(errorResponse.utf8))
            }

            let client = createMockClient()
            let repoID: Repo.ID = "nonexistent/dataset"

            await #expect(throws: HTTPClientError.self) {
                _ = try await client.getDataset(repoID)
            }
        }
    }

    // MARK: - Integration Tests (Real API Calls)

    /// Integration tests that make real API calls to the Hugging Face Hub.
    ///
    /// Skip these tests in CI by setting the `SKIP_INTEGRATION_TESTS` environment variable.
    @Suite(
        "Dataset Integration Tests",
        .serialized,
        .enabled(if: ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] == nil)
    )
    struct DatasetIntegrationTests {
        let client = HubClient()

        @Test("List parquet files without parameters returns nested response")
        func listParquetFilesNoParams() async throws {
            let files = try await client.listParquetFiles("ibm/duorc")

            #expect(files.count > 0)
            // ibm/duorc has multiple configs (ParaphraseRC, SelfRC)
            let configs = Set(files.map(\.config))
            #expect(configs.count > 1)
            for file in files {
                #expect(file.dataset == "duorc")
                #expect(!file.config.isEmpty)
                #expect(!file.split.isEmpty)
                #expect(file.filename.hasSuffix(".parquet"))
                #expect(file.url.contains("/parquet/"))
            }
        }

        @Test("List parquet files with subset returns splits")
        func listParquetFilesWithSubset() async throws {
            let files = try await client.listParquetFiles("ibm/duorc", subset: "SelfRC")

            #expect(files.count > 0)
            let splits = Set(files.map(\.split))
            #expect(splits.contains("train"))
            #expect(splits.contains("test"))
            for file in files {
                #expect(file.config == "SelfRC")
            }
        }

        @Test("List parquet files with subset and split returns flat array")
        func listParquetFilesWithSubsetAndSplit() async throws {
            let files = try await client.listParquetFiles(
                "ibm/duorc",
                subset: "SelfRC",
                split: "train"
            )

            #expect(files.count > 0)
            for file in files {
                #expect(file.config == "SelfRC")
                #expect(file.split == "train")
                #expect(file.filename.hasSuffix(".parquet"))
            }
        }
    }

#endif  // swift(>=6.1)
