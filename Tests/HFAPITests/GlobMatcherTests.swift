// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

@Suite("GlobMatcher")
struct GlobMatcherTests {
    // MARK: - Single * (does NOT cross /)

    @Test("'*' matches a single segment")
    func singleStarMatchesSegment() throws {
        let m = try #require(GlobMatcher("*.json"))
        #expect(m.matches("config.json"))
        #expect(m.matches("tokenizer.json"))
        #expect(!m.matches("subdir/config.json"), "* must not cross /")
        #expect(!m.matches("config.txt"))
    }

    @Test("'subdir/*.json' matches only one segment deep")
    func subdirSingleStar() throws {
        let m = try #require(GlobMatcher("subdir/*.json"))
        #expect(m.matches("subdir/config.json"))
        #expect(!m.matches("config.json"))
        #expect(!m.matches("subdir/nested/config.json"))
    }

    // MARK: - ? (single char, not /)

    @Test("'?' matches a single character but not /")
    func questionMark() throws {
        let m = try #require(GlobMatcher("file?.txt"))
        #expect(m.matches("fileA.txt"))
        #expect(m.matches("file1.txt"))
        #expect(!m.matches("file.txt"))
        #expect(!m.matches("filex/y.txt"))
    }

    // MARK: - ** (recursive)

    @Test("'**/*.json' matches at any depth, including root")
    func recursiveAllDepths() throws {
        let m = try #require(GlobMatcher("**/*.json"))
        #expect(m.matches("config.json"))
        #expect(m.matches("subdir/config.json"))
        #expect(m.matches("a/b/c/config.json"))
        #expect(!m.matches("config.txt"))
    }

    @Test("'a/**/b' matches with zero or more intermediate segments")
    func recursiveSandwich() throws {
        let m = try #require(GlobMatcher("a/**/b"))
        #expect(m.matches("a/b"))
        #expect(m.matches("a/x/b"))
        #expect(m.matches("a/x/y/b"))
        #expect(!m.matches("a/x"))
        #expect(!m.matches("b"))
    }

    @Test("'foo/**' matches anything inside the directory")
    func recursiveSuffix() throws {
        let m = try #require(GlobMatcher("foo/**"))
        // globset's `foo/**` matches paths inside `foo/`, not `foo` itself.
        #expect(m.matches("foo/x"))
        #expect(m.matches("foo/x/y"))
        #expect(!m.matches("bar/x"))
    }

    @Test("'**' matches everything")
    func recursiveOnly() throws {
        let m = try #require(GlobMatcher("**"))
        #expect(m.matches("foo"))
        #expect(m.matches("foo/bar"))
        #expect(m.matches("a/b/c"))
    }

    @Test("'**' outside a full path component degrades to a single '*'")
    func doubleStarOutsidePathComponent() throws {
        // globset treats `**` that is not a full path component as a single `*`.
        // The pattern still compiles; cross-segment recursion just doesn't happen.
        let m = try #require(GlobMatcher("foo**bar"))
        #expect(m.matches("foobar"))
        #expect(m.matches("fooXYZbar"))
        #expect(!m.matches("foo/bar"))
    }

    // MARK: - Trailing slash sugar

    @Test("A trailing '/' auto-appends '*'")
    func trailingSlash() throws {
        let m = try #require(GlobMatcher("data/"))
        #expect(m.matches("data/anything"))
        #expect(m.matches("data/file.json"))
        #expect(!m.matches("data/nested/file.json"), "trailing-slash is '/*' not '/**'")
        #expect(!m.matches("data"))
    }

    // MARK: - Literal characters

    @Test("Regex metacharacters in patterns are matched literally")
    func regexMetaIsEscaped() throws {
        let m = try #require(GlobMatcher("foo.bar"))
        #expect(m.matches("foo.bar"))
        #expect(!m.matches("fooXbar"), "'.' in glob is a literal, not regex any-char")
    }

    @Test("Common Hugging Face allow-pattern shapes")
    func commonAllowPatterns() throws {
        for pattern in [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "preprocessor_config.json",
            "*.safetensors",
            "README.md",
        ] {
            #expect(GlobMatcher(pattern) != nil, "should compile: \(pattern)")
        }
        let safetensors = try? #require(GlobMatcher("*.safetensors"))
        #expect(safetensors?.matches("weights.safetensors") == true)
        #expect(safetensors?.matches("model.safetensors") == true)
        #expect(safetensors?.matches("subdir/weights.safetensors") == false)
    }
}
