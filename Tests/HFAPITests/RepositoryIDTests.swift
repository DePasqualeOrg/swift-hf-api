// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

@Suite("RepositoryID")
struct RepositoryIDTests {
    @Test("init(owner:name:) accepts a typical model ID")
    func acceptsTypicalID() throws {
        let id = try RepositoryID(owner: "mlx-community", name: "Qwen2-1.5B-Instruct-4bit")
        #expect(id.owner == "mlx-community")
        #expect(id.name == "Qwen2-1.5B-Instruct-4bit")
        #expect(id.rawValue == "mlx-community/Qwen2-1.5B-Instruct-4bit")
    }

    @Test("init(_:) parses owner/name strings")
    func parsesString() {
        let id = RepositoryID("openai-community/gpt2")
        #expect(id?.owner == "openai-community")
        #expect(id?.name == "gpt2")
    }

    @Test("init(_:) rejects single-segment IDs")
    func rejectsSingleSegment() {
        #expect(RepositoryID("gpt2") == nil)
    }

    @Test("init(_:) rejects three-segment IDs")
    func rejectsThreeSegments() {
        #expect(RepositoryID("a/b/c") == nil)
    }

    @Test("init(_:) rejects an empty segment")
    func rejectsEmptySegment() {
        #expect(RepositoryID("/name") == nil)
        #expect(RepositoryID("owner/") == nil)
        #expect(RepositoryID("/") == nil)
    }

    @Test("validation rejects forbidden characters")
    func rejectsForbiddenCharacters() {
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "owner with space", name: "name")
        }
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "owner", name: "name?query")
        }
    }

    @Test("validation rejects leading or trailing '-' and '.'")
    func rejectsLeadingTrailingPunctuation() {
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "-owner", name: "name")
        }
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "owner", name: "name-")
        }
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: ".owner", name: "name")
        }
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "owner", name: "name.")
        }
    }

    @Test("validation rejects double '-' and '..'")
    func rejectsDoublePunctuation() {
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "ow--ner", name: "name")
        }
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "owner", name: "na..me")
        }
    }

    @Test("validation rejects .git suffix on the name segment")
    func rejectsGitSuffix() {
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: "owner", name: "repo.git")
        }
    }

    @Test("validation accepts dots and dashes in the middle")
    func acceptsInteriorDotsAndDashes() throws {
        let id = try RepositoryID(owner: "stabilityai", name: "stable-diffusion-2.1")
        #expect(id.rawValue == "stabilityai/stable-diffusion-2.1")
    }

    @Test("validation rejects a segment longer than 96 characters")
    func rejectsOverlongSegment() {
        let long = String(repeating: "a", count: 97)
        #expect(throws: RepositoryID.ValidationError.self) {
            _ = try RepositoryID(owner: long, name: "name")
        }
    }

    @Test("validation accepts a 96-character segment")
    func acceptsMaxLengthSegment() throws {
        let long = String(repeating: "a", count: 96)
        let id = try RepositoryID(owner: long, name: "name")
        #expect(id.owner == long)
    }

    @Test("RepositoryID is Hashable and Equatable")
    func hashableEquatable() throws {
        let a = try RepositoryID(owner: "foo", name: "bar")
        let b = try RepositoryID(owner: "foo", name: "bar")
        let c = try RepositoryID(owner: "foo", name: "baz")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test("RepositoryID round-trips through Codable")
    func codableRoundTrip() throws {
        let id = try RepositoryID(owner: "foo", name: "bar")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RepositoryID.self, from: data)
        #expect(decoded == id)
    }
}
