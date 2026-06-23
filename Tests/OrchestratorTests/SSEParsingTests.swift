import Testing
import Foundation
@testable import Orchestrator

// MARK: - SSE Parsing Unit Tests
//
// Tests parseSSEDelta and parseSSEEvent static helpers on OpenAIProvider.
// These are pure text-parsing functions with no networking — fast and deterministic.

@Suite("SSE Parsing")
struct SSEParsingTests {

    // MARK: - parseSSEDelta

    @Test("parseSSEDelta returns content for a standard chunk")
    func parseSSEDeltaReturnsContentForStandardChunk() {
        let line = #"data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#
        let result = OpenAIProvider.parseSSEDelta(line)
        #expect(result == "Hello")
    }

    @Test("parseSSEDelta returns nil for DONE sentinel")
    func parseSSEDeltaReturnsNilForDoneSentinel() {
        let result = OpenAIProvider.parseSSEDelta("data: [DONE]")
        #expect(result == nil)
    }

    @Test("parseSSEDelta returns nil for empty line")
    func parseSSEDeltaReturnsNilForEmptyLine() {
        let result = OpenAIProvider.parseSSEDelta("")
        #expect(result == nil)
    }

    @Test("parseSSEDelta returns nil for keep-alive comment line")
    func parseSSEDeltaReturnsNilForKeepAliveCommentLine() {
        let result = OpenAIProvider.parseSSEDelta(": keepalive")
        #expect(result == nil)
    }

    @Test("parseSSEDelta returns nil for malformed JSON")
    func parseSSEDeltaReturnsNilForMalformedJSON() {
        let result = OpenAIProvider.parseSSEDelta("data: not-valid-json{{{")
        #expect(result == nil)
    }

    @Test("parseSSEDelta returns nil for role-only delta with no content key")
    func parseSSEDeltaReturnsNilForRoleOnlyDelta() {
        // First chunk typically only has role, no content
        let line = #"data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#
        let result = OpenAIProvider.parseSSEDelta(line)
        // role-only: content key absent → nil (skip)
        #expect(result == nil)
    }

    @Test("parseSSEDelta returns empty string for chunk with empty content")
    func parseSSEDeltaReturnsEmptyStringForChunkWithEmptyContent() {
        let line = #"data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}"#
        let result = OpenAIProvider.parseSSEDelta(line)
        // Empty content is a valid delta (empty string), not nil
        #expect(result == "")
    }

    @Test("parseSSEDelta handles Unicode content correctly")
    func parseSSEDeltaHandlesUnicodeContent() {
        let line = #"data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}"#
        let result = OpenAIProvider.parseSSEDelta(line)
        #expect(result == "你好")
    }

    // MARK: - parseSSEEvent

    @Test("parseSSEEvent extracts single delta from a standard event")
    func parseSSEEventExtractsSingleDeltaFromStandardEvent() {
        let event = #"data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
        let deltas = OpenAIProvider.parseSSEEvent(event)
        #expect(deltas == ["Hi"])
    }

    @Test("parseSSEEvent returns empty array for event with no content lines")
    func parseSSEEventReturnsEmptyArrayForEventWithNoContentLines() {
        let event = ": keepalive\n: keepalive"
        let deltas = OpenAIProvider.parseSSEEvent(event)
        #expect(deltas.isEmpty)
    }

    @Test("parseSSEEvent skips DONE line and returns empty array")
    func parseSSEEventSkipsDoneLineAndReturnsEmptyArray() {
        let event = "data: [DONE]"
        let deltas = OpenAIProvider.parseSSEEvent(event)
        #expect(deltas.isEmpty)
    }

    @Test("parseSSEEvent processes multi-line event collecting all content deltas")
    func parseSSEEventProcessesMultiLineEventCollectingAllContentDeltas() {
        // Unusual but spec-legal: multiple data: lines within a single \n\n-delimited event
        let chunk1 = #"data: {"id":"1","choices":[{"index":0,"delta":{"content":"A"},"finish_reason":null}]}"#
        let chunk2 = #"data: {"id":"2","choices":[{"index":0,"delta":{"content":"B"},"finish_reason":null}]}"#
        let event = chunk1 + "\n" + chunk2
        let deltas = OpenAIProvider.parseSSEEvent(event)
        #expect(deltas == ["A", "B"])
    }
}
