import Testing
import Foundation
@testable import Orchestrator

// MARK: - OpenAIProvider streaming tests
//
// Exercises streamChat via mock httpStreamClient injection.
// The mock returns AsyncThrowingStream<UInt8, Error> built from raw SSE strings.

// MARK: - Helpers

/// Convert a raw SSE response string into an AsyncThrowingStream<UInt8, Error>.
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

private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    let url = URL(string: "https://api.openai.com/v1/chat/completions")!
    return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

/// Build a minimal SSE chunk JSON line for the given content string.
private func sseChunkLine(_ content: String) -> String {
    // Escape the content for JSON embedding
    let escaped = content
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return #"data: {"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\#(escaped)"},"finish_reason":null}]}"# + "\n\n"
}

/// Build a three-chunk SSE payload (Hello, ", ", World) plus DONE.
private let threeChunkSSE: String =
    sseChunkLine("Hello") + sseChunkLine(", ") + sseChunkLine("World") + "data: [DONE]\n\n"

// MARK: - Tests

@Suite("OpenAIProvider streaming")
struct OpenAIProviderStreamTests {

    @Test("streamChat yields three tokens from three-chunk SSE payload")
    func streamChatYieldsThreeTokensFromThreeChunkSSEPayload() async throws {
        let provider = OpenAIProvider(
            apiKey: "sk-test",
            httpStreamClient: { _ in
                (makeByteStream(from: threeChunkSSE), makeHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected == ["Hello", ", ", "World"])
    }

    @Test("streamChat finishes normally when DONE sentinel is received")
    func streamChatFinishesNormallyWhenDoneSentinelReceived() async throws {
        let provider = OpenAIProvider(
            apiKey: "sk-test",
            httpStreamClient: { _ in
                (makeByteStream(from: "data: [DONE]\n\n"), makeHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected.isEmpty)
    }

    @Test("streamChat throws httpError when server responds with 401")
    func streamChatThrowsHTTPErrorWhenServerResponds401() async throws {
        let provider = OpenAIProvider(
            apiKey: "sk-bad",
            httpStreamClient: { _ in
                (makeByteStream(from: ""), makeHTTPResponse(statusCode: 401))
            }
        )

        await #expect(throws: LLMProviderError.self) {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        }
    }

    @Test("streamChat throws when underlying network throws")
    func streamChatThrowsWhenNetworkThrows() async throws {
        struct FakeNetworkError: Error {}

        let provider = OpenAIProvider(
            apiKey: "sk-test",
            httpStreamClient: { _ in
                throw FakeNetworkError()
            }
        )

        await #expect(throws: Error.self) {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        }
    }

    @Test("streamChat skips keep-alive comment lines without yielding")
    func streamChatSkipsKeepAliveCommentLinesWithoutYielding() async throws {
        let sse = ": keepalive\n\n" + sseChunkLine("Hi") + "data: [DONE]\n\n"

        let provider = OpenAIProvider(
            apiKey: "sk-test",
            httpStreamClient: { _ in
                (makeByteStream(from: sse), makeHTTPResponse(statusCode: 200))
            }
        )

        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected == ["Hi"])
    }

    @Test("streamChat sends stream:true in request body")
    func streamChatSendsStreamTrueInRequestBody() async throws {
        var capturedBody: [String: Any]?
        let provider = OpenAIProvider(
            apiKey: "sk-test",
            httpStreamClient: { request in
                if let data = request.httpBody {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return (makeByteStream(from: "data: [DONE]\n\n"), makeHTTPResponse(statusCode: 200))
            }
        )

        for try await _ in provider.streamChat([LLMMessage(role: .user, content: "test")]) {}

        #expect(capturedBody?["stream"] as? Bool == true)
    }
}


// MARK: - 错误响应体携带(stream 非 2xx 带上服务商 message)

@Suite("OpenAIProvider streaming 错误体携带")
struct OpenAIProviderStreamErrorBodyTests {

    @Test("非 2xx → httpError 携带服务商错误体(此前丢空体)")
    func errorBodyCarried() async throws {
        let provider = OpenAIProvider(
            apiKey: "sk-bad",
            httpStreamClient: { _ in
                (makeByteStream(from: "{\"error\":{\"message\":\"Incorrect API key provided\"}}"),
                 makeHTTPResponse(statusCode: 401))
            }
        )

        var caught: LLMProviderError?
        do {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        } catch let e as LLMProviderError {
            caught = e
        }

        guard case .httpError(let status, let body) = caught else {
            Issue.record("expected httpError, got \(String(describing: caught))")
            return
        }
        #expect(status == 401)
        #expect(body.contains("Incorrect API key provided"))
    }

    @Test("错误体有界:超 4KB 截断(防异常大响应撑内存)")
    func errorBodyBounded() async throws {
        let big = String(repeating: "e", count: 10_000)
        let provider = OpenAIProvider(
            apiKey: "sk-bad",
            httpStreamClient: { _ in
                (makeByteStream(from: big), makeHTTPResponse(statusCode: 500))
            }
        )

        var caught: LLMProviderError?
        do {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        } catch let e as LLMProviderError {
            caught = e
        }

        guard case .httpError(_, let body) = caught else {
            Issue.record("expected httpError, got \(String(describing: caught))")
            return
        }
        #expect(body.utf8.count <= 4096)
    }
}
