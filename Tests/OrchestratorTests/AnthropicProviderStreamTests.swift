import Testing
import Foundation
@testable import Orchestrator

// MARK: - AnthropicProvider streaming tests
//
// Exercises streamChat via mock httpStreamClient injection.
// The mock returns AsyncThrowingStream<UInt8, Error> built from raw SSE strings.

// MARK: - Helpers

private func makeByteStream(from text: String) -> AsyncThrowingStream<UInt8, Error> {
    let bytes = Array(text.utf8)
    return AsyncThrowingStream { continuation in
        Task {
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}

private func makeThrowingByteStream(error: Error) -> AsyncThrowingStream<UInt8, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
    }
}

private func makeAnthropicHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

/// Build one Anthropic content_block_delta SSE event string (with \n\n terminator).
private func anthropicDeltaEvent(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\(escaped)"}}\n\n
    """
}

/// Build a full Anthropic message lifecycle SSE payload.
private func makeAnthropicFullSSE(deltas: [String]) -> String {
    var parts: [String] = []

    // message_start
    parts.append("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-4-5\",\"stop_reason\":null,\"usage\":{\"input_tokens\":5}}}\n\n")

    // content_block_start
    parts.append("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n")

    // deltas
    for delta in deltas {
        parts.append(anthropicDeltaEvent(delta))
    }

    // content_block_stop
    parts.append("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")

    // message_delta
    parts.append("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":10}}\n\n")

    // message_stop
    parts.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")

    return parts.joined()
}

// MARK: - Tests

@Suite("AnthropicProvider streaming")
struct AnthropicProviderStreamTests {

    @Test("streamChat yields delta strings in correct order from multi-delta SSE")
    func streamChatYieldsDeltasInOrder() async throws {
        let sse = makeAnthropicFullSSE(deltas: ["Hello", ", ", "world"])

        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpStreamClient: { _ in
                (makeByteStream(from: sse), makeAnthropicHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected == ["Hello", ", ", "world"])
    }

    @Test("Complete message lifecycle: only the 2 delta texts are yielded")
    func completeMessageLifecycleYieldsOnlyDeltas() async throws {
        // Full lifecycle: message_start → content_block_start → delta1 → delta2 → content_block_stop → message_stop
        let sse = makeAnthropicFullSSE(deltas: ["First", "Second"])

        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpStreamClient: { _ in
                (makeByteStream(from: sse), makeAnthropicHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected == ["First", "Second"])
    }

    @Test("Chinese CJK content round-trips without corruption across SSE chunks")
    func chineseCJKContentRoundTripsCorrectly() async throws {
        let chineseText = "你好世界"
        // Split into individual characters to simulate chunked delivery
        let deltas = chineseText.map { String($0) }
        let sse = makeAnthropicFullSSE(deltas: deltas)

        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpStreamClient: { _ in
                (makeByteStream(from: sse), makeAnthropicHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        let reconstructed = collected.joined()
        #expect(reconstructed == chineseText)
    }

    @Test("streamChat throws httpError when server responds with 401")
    func streamChatThrowsHTTPErrorOn401() async throws {
        let provider = AnthropicProvider(
            apiKey: "sk-ant-bad",
            httpStreamClient: { _ in
                (makeByteStream(from: ""), makeAnthropicHTTPResponse(statusCode: 401))
            }
        )

        await #expect(throws: LLMProviderError.self) {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        }
    }

    @Test("streamChat throws when underlying network throws mid-stream")
    func streamChatThrowsWhenNetworkThrowsMidStream() async throws {
        struct FakeNetworkError: Error {}

        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpStreamClient: { _ in
                throw FakeNetworkError()
            }
        )

        await #expect(throws: Error.self) {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        }
    }

    @Test("streamChat with no deltas (empty response) yields nothing and finishes cleanly")
    func streamChatWithNoDeltas() async throws {
        let sse = makeAnthropicFullSSE(deltas: [])

        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpStreamClient: { _ in
                (makeByteStream(from: sse), makeAnthropicHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected.isEmpty)
    }

    @Test("streamChat sends stream: true in request body")
    func streamChatSendsStreamTrueInBody() async throws {
        var capturedBody: [String: Any]?

        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpStreamClient: { request in
                if let data = request.httpBody {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return (makeByteStream(from: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"), makeAnthropicHTTPResponse(statusCode: 200))
            }
        )

        for try await _ in provider.streamChat([LLMMessage(role: .user, content: "test")]) {}

        #expect(capturedBody?["stream"] as? Bool == true)
    }
}
