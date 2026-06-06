// Copyright © Anthony DePasquale

import Foundation
import Testing
@testable import HFAPI

/// Lock-in tests for the typed error model. These are pure-data assertions
/// that don't touch the Hub – they exist to detect drift in the contract
/// callers retry against.

@Suite("RequestErrorKind.isTransient contract")
struct RequestErrorKindTransienceTests {
    @Test("timeout and connect are transient; decode/tls/other are not")
    func contract() {
        #expect(RequestErrorKind.timeout.isTransient)
        #expect(RequestErrorKind.connect.isTransient)
        #expect(!RequestErrorKind.decode.isTransient)
        #expect(!RequestErrorKind.tls.isTransient)
        #expect(!RequestErrorKind.other.isTransient)
    }
}

@Suite("HFError.localizedDescription rendering")
struct ErrorLocalizedDescriptionTests {
    @Test("request error includes the message and url")
    func requestRendering() {
        let err = HFError.request(
            message: "connection refused",
            url: "https://huggingface.co/api/whoami",
            kind: .connect
        )
        let rendered = err.localizedDescription
        #expect(rendered.contains("connection refused"))
        #expect(rendered.contains("https://huggingface.co/api/whoami"))
    }

    @Test("cancelled has a short, user-visible message")
    func cancelledRendering() {
        #expect(HFError.cancelled.localizedDescription == "Operation cancelled")
    }

    @Test("other carries Hub error prefix so the source is unambiguous")
    func otherRendering() {
        let rendered = HFError.other(message: "unmapped upstream variant").localizedDescription
        #expect(rendered.hasPrefix("Hub error: "))
    }

    @Test("invalidParameter carries the call-site message verbatim")
    func invalidParameterRendering() {
        let rendered = HFError.invalidParameter(message: "both token and tokenProvider set")
            .localizedDescription
        #expect(rendered.contains("both token and tokenProvider set"))
    }
}

@Suite("GatedMode.init(rawJSON:) classification")
struct GatedModeParseTests {
    @Test("nil and empty raw values produce nil")
    func nilAndEmpty() {
        #expect(GatedMode(rawJSON: nil) == nil)
        #expect(GatedMode(rawJSON: "") == nil)
    }

    @Test("canonical JSON values parse to their typed cases")
    func canonical() {
        #expect(GatedMode(rawJSON: "false") == .disabled)
        #expect(GatedMode(rawJSON: "\"auto\"") == .auto)
        #expect(GatedMode(rawJSON: "\"manual\"") == .manual)
    }

    @Test("JSON values with whitespace still classify correctly")
    func whitespaceTolerant() {
        // JSONDecoder accepts whitespace around top-level values – the
        // pre-decode string-match parser fell through to `.unknown(_)`
        // for these inputs.
        #expect(GatedMode(rawJSON: "  false  ") == .disabled)
        #expect(GatedMode(rawJSON: " \"auto\"") == .auto)
    }

    @Test("unrecognized JSON values land in .unknown carrying the raw text")
    func unknownPassthrough() {
        // A future Hub addition (e.g., a new mode label) should round-trip
        // its raw text through `.unknown` so callers can opt in without a
        // library update.
        if case .unknown(let raw) = GatedMode(rawJSON: "\"future-mode\"") {
            #expect(raw == "\"future-mode\"")
        } else {
            Issue.record("expected .unknown for a future Hub value")
        }
        // JSON `true` is not a documented gated value but should still
        // flow through .unknown rather than crash.
        if case .unknown(let raw) = GatedMode(rawJSON: "true") {
            #expect(raw == "true")
        } else {
            Issue.record("expected .unknown for JSON true")
        }
    }

    @Test("malformed JSON falls through to .unknown without throwing")
    func malformedJSONFallthrough() {
        // The Rust side does not promise a well-formed JSON token – a
        // future change to surface the raw header verbatim would land
        // garbage here. Confirm `.unknown` is the worst-case outcome.
        if case .unknown(let raw) = GatedMode(rawJSON: "not-json") {
            #expect(raw == "not-json")
        } else {
            Issue.record("expected .unknown for malformed input")
        }
    }
}
