import Testing
import Foundation
@testable import Orchestrator

// MARK: - AnthropicProvider SSE parsing unit tests
//
// Exercises `AnthropicProvider.parseAnthropicSSEEvent(_:)` in isolation.
// No networking, no actors — pure static function tests.

@Suite("AnthropicProvider — SSE event parsing")
struct AnthropicSSEParsingTests {

    // MARK: - content_block_delta: happy path

    @Test("Standard content_block_delta event returns delta text")
    func standardContentBlockDeltaReturnsDeltaText() {
        let event = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result == ["Hello"])
    }

    @Test("Multiple content_block_delta events each return their delta text")
    func multipleContentBlockDeltaEventsReturnTexts() {
        let event1 = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """
        let event2 = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world!"}}
        """

        let result1 = AnthropicProvider.parseAnthropicSSEEvent(event1)
        let result2 = AnthropicProvider.parseAnthropicSSEEvent(event2)

        #expect(result1 == ["Hello"])
        #expect(result2 == [", world!"])
    }

    @Test("content_block_delta with empty text string returns empty string (not ignored)")
    func contentBlockDeltaWithEmptyTextReturnsEmptyString() {
        let event = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        // parseAnthropicSSEEvent returns the string; the caller (yieldAnthropicEvent)
        // filters out empty strings before yielding to the continuation.
        #expect(result == [""])
    }

    // MARK: - Non-delta events: must be ignored (return [])

    @Test("message_start event returns empty array (ignored)")
    func messageStartEventReturnsEmpty() {
        let event = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","stop_reason":null,"usage":{"input_tokens":5}}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("message_stop event returns empty array (ignored)")
    func messageStopEventReturnsEmpty() {
        let event = """
        event: message_stop
        data: {"type":"message_stop"}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("ping event returns empty array (ignored)")
    func pingEventReturnsEmpty() {
        let event = """
        event: ping
        data: {"type":"ping"}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("content_block_start event returns empty array (ignored)")
    func contentBlockStartEventReturnsEmpty() {
        let event = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("content_block_stop event returns empty array (ignored)")
    func contentBlockStopEventReturnsEmpty() {
        let event = """
        event: content_block_stop
        data: {"type":"content_block_stop","index":0}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("message_delta event returns empty array (ignored)")
    func messageDeltaEventReturnsEmpty() {
        let event = """
        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("Unknown event type returns empty array (does not throw)")
    func unknownEventTypeReturnsEmpty() {
        let event = """
        event: some_future_event_type
        data: {"type":"some_future_event_type","payload":"anything"}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    // MARK: - Resilience

    @Test("Corrupted JSON in data line returns empty array (does not throw)")
    func corruptedJSONReturnsEmpty() {
        let event = """
        event: content_block_delta
        data: {this is not valid json!!!
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("Event with no event: line returns empty array")
    func eventWithNoEventLineReturnsEmpty() {
        let event = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }

    @Test("content_block_delta with non-text_delta type returns empty array")
    func contentBlockDeltaWithNonTextDeltaTypeReturnsEmpty() {
        // input_json_delta is a tool-use delta type we don't handle
        let event = """
        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"key\":"}}
        """

        let result = AnthropicProvider.parseAnthropicSSEEvent(event)

        #expect(result.isEmpty)
    }
}
