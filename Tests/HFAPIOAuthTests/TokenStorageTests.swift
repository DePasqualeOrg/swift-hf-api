// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import HFAPIOAuth

#if swift(>=6.1)
    @Suite("Token Storage Tests", .serialized)
    struct TokenStorageTests {
        @Test("FileTokenStorage store retrieve delete lifecycle")
        func testFileTokenStorageLifecycle() throws {
            let (directory, fileURL) = makeTempTokenPath()
            defer { try? FileManager.default.removeItem(at: directory) }

            let storage = FileTokenStorage(fileURL: fileURL)
            let token = OAuthToken(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            #expect(storage.hasStoredToken == false)
            try storage.store(token)
            #expect(storage.hasStoredToken == true)

            let retrieved = try #require(try storage.retrieve())
            #expect(retrieved.accessToken == token.accessToken)
            #expect(retrieved.refreshToken == token.refreshToken)
            #expect(retrieved.expiresAt == token.expiresAt)

            try storage.delete()
            #expect(storage.hasStoredToken == false)
            #expect(try storage.retrieve() == nil)
        }

        @Test("FileTokenStorage retrieve is nil when file is absent")
        func testFileTokenStorageRetrieveMissingFile() throws {
            let (directory, fileURL) = makeTempTokenPath()
            defer { try? FileManager.default.removeItem(at: directory) }

            let storage = FileTokenStorage(fileURL: fileURL)
            #expect(try storage.retrieve() == nil)
        }

        @Test("FileTokenStorage throws when file contains invalid JSON")
        func testFileTokenStorageInvalidJSONThrows() throws {
            let (directory, fileURL) = makeTempTokenPath()
            defer { try? FileManager.default.removeItem(at: directory) }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{invalid-json".utf8).write(to: fileURL)

            let storage = FileTokenStorage(fileURL: fileURL)
            #expect(throws: DecodingError.self) {
                _ = try storage.retrieve()
            }
        }

        private func makeTempTokenPath() -> (URL, URL) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = directory.appendingPathComponent("token.json")
            return (directory, fileURL)
        }
    }
#endif
