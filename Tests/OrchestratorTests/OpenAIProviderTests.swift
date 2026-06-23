import Testing
import Foundation
@testable import Orchestrator

// MARK: - Helper builders

private func makeSuccessJSON(content: String) -> Data {
    let json = """
    {
        "id": "chatcmpl-123",
        "object": "chat.completion",
        "model": "gpt-4o-mini",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "\(content)"
                },
                "finish_reason": "stop"
            }
        ],
        "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15
        }
    }
    """
    return Data(json.utf8)
}

private func makeHTTPResponse(
    status: Int,
    url: URL = URL(string: "https://api.openai.com/v1/chat/completions")!
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private let defaultURL = URL(string: "https://api.openai.com/v1/chat/completions")!

// MARK: - Happy path

@Test("OpenAIProvider returns message content on successful response")
func openAIProviderReturnsMessageContentOnSuccessfulResponse() async throws {
    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in
            (makeSuccessJSON(content: "Hello from GPT!"), makeHTTPResponse(status: 200))
        }
    )

    let result = try await provider.chat([LLMMessage(role: .user, content: "hi")])

    #expect(result == "Hello from GPT!")
}

@Test("OpenAIProvider sends Bearer auth header")
func openAIProviderSendsBearerAuthHeader() async throws {
    var capturedRequest: URLRequest?
    let provider = OpenAIProvider(
        apiKey: "sk-my-secret-key",
        httpClient: { request in
            capturedRequest = request
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200))
        }
    )

    _ = try await provider.chat([LLMMessage(role: .user, content: "test")])

    let authHeader = capturedRequest?.value(forHTTPHeaderField: "Authorization")
    #expect(authHeader == "Bearer sk-my-secret-key")
}

@Test("OpenAIProvider sends correct model in request body")
func openAIProviderSendsCorrectModelInRequestBody() async throws {
    var capturedBody: [String: Any]?
    let provider = OpenAIProvider(
        apiKey: "sk-test",
        model: "gpt-4o",
        httpClient: { request in
            if let data = request.httpBody {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200))
        }
    )

    _ = try await provider.chat([LLMMessage(role: .user, content: "test")])

    #expect(capturedBody?["model"] as? String == "gpt-4o")
}

@Test("OpenAIProvider sends messages array in request body")
func openAIProviderSendsMessagesArrayInRequestBody() async throws {
    var capturedMessages: [[String: String]]?
    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { request in
            if let data = request.httpBody,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                capturedMessages = body["messages"] as? [[String: String]]
            }
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200))
        }
    )

    let messages = [
        LLMMessage(role: .system, content: "Be helpful"),
        LLMMessage(role: .user, content: "What is 2+2?"),
    ]
    _ = try await provider.chat(messages)

    #expect(capturedMessages?.count == 2)
    #expect(capturedMessages?[0]["role"] == "system")
    #expect(capturedMessages?[0]["content"] == "Be helpful")
    #expect(capturedMessages?[1]["role"] == "user")
    #expect(capturedMessages?[1]["content"] == "What is 2+2?")
}

@Test("OpenAIProvider sends POST to the completions endpoint")
func openAIProviderSendsPOSTToCompletionsEndpoint() async throws {
    var capturedRequest: URLRequest?
    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { request in
            capturedRequest = request
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200))
        }
    )

    _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])

    #expect(capturedRequest?.httpMethod == "POST")
    #expect(capturedRequest?.url?.path == "/v1/chat/completions")
}

@Test("OpenAIProvider sets Content-Type application/json header")
func openAIProviderSetsContentTypeApplicationJSONHeader() async throws {
    var capturedRequest: URLRequest?
    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { request in
            capturedRequest = request
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200))
        }
    )

    _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])

    #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

// MARK: - Error paths

@Test("OpenAIProvider throws emptyResponse when choices array is empty")
func openAIProviderThrowsEmptyResponseWhenChoicesArrayIsEmpty() async throws {
    let emptyChoicesJSON = Data(#"{"id":"chatcmpl-123","choices":[]}"#.utf8)

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in (emptyChoicesJSON, makeHTTPResponse(status: 200)) }
    )

    await #expect(throws: LLMProviderError.emptyResponse) {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
    }
}

@Test("OpenAIProvider throws LLMProviderError on 401 Unauthorized")
func openAIProviderThrowsLLMProviderErrorOn401Unauthorized() async throws {
    let body = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)

    let provider = OpenAIProvider(
        apiKey: "sk-bad",
        httpClient: { _ in (body, makeHTTPResponse(status: 401)) }
    )

    await #expect(throws: LLMProviderError.self) {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
    }
}

@Test("OpenAIProvider throws httpError with 429 status on rate limited response")
func openAIProviderThrowsHTTPErrorWith429StatusOnRateLimitedResponse() async throws {
    let body = Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8)

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in (body, makeHTTPResponse(status: 429)) }
    )

    do {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
        Issue.record("Expected error to be thrown")
    } catch let error as LLMProviderError {
        if case .httpError(let status, _) = error {
            #expect(status == 429)
        } else {
            Issue.record("Expected httpError, got \(error)")
        }
    }
}

@Test("OpenAIProvider throws httpError with 500 status on server error response")
func openAIProviderThrowsHTTPErrorWith500StatusOnServerErrorResponse() async throws {
    let body = Data(#"{"error":{"message":"Internal server error"}}"#.utf8)

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in (body, makeHTTPResponse(status: 500)) }
    )

    do {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
        Issue.record("Expected error to be thrown")
    } catch let error as LLMProviderError {
        if case .httpError(let status, _) = error {
            #expect(status == 500)
        } else {
            Issue.record("Expected httpError, got \(error)")
        }
    }
}

@Test("OpenAIProvider throws LLMProviderError on malformed JSON response")
func openAIProviderThrowsLLMProviderErrorOnMalformedJSONResponse() async throws {
    let malformed = Data("not-json-at-all".utf8)

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in (malformed, makeHTTPResponse(status: 200)) }
    )

    await #expect(throws: LLMProviderError.self) {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
    }
}

@Test("OpenAIProvider throws LLMProviderError when choices key is missing")
func openAIProviderThrowsLLMProviderErrorWhenChoicesKeyIsMissing() async throws {
    let missingChoices = Data(#"{"id":"chatcmpl-123"}"#.utf8)

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in (missingChoices, makeHTTPResponse(status: 200)) }
    )

    await #expect(throws: LLMProviderError.self) {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
    }
}

@Test("OpenAIProvider wraps network errors as transportError")
func openAIProviderWrapsNetworkErrorsAsTransportError() async throws {
    struct FakeNetworkError: Error {}

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in throw FakeNetworkError() }
    )

    await #expect(throws: LLMProviderError.self) {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
    }
}

@Test("OpenAIProvider transport error contains localised error description")
func openAIProviderTransportErrorContainsLocalisedErrorDescription() async throws {
    struct DescribedError: LocalizedError {
        var errorDescription: String? { "simulated timeout" }
    }

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { _ in throw DescribedError() }
    )

    do {
        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
        Issue.record("Expected transportError to be thrown")
    } catch let error as LLMProviderError {
        if case .transportError(let desc) = error {
            #expect(desc.contains("simulated timeout"))
        } else {
            Issue.record("Expected transportError, got \(error)")
        }
    }
}

@Test("OpenAIProvider uses default model gpt-4o-mini")
func openAIProviderUsesDefaultModelGPT4oMini() async throws {
    var capturedBody: [String: Any]?
    let provider = OpenAIProvider(
        apiKey: "sk-test",
        httpClient: { request in
            if let data = request.httpBody {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200))
        }
    )

    _ = try await provider.chat([LLMMessage(role: .user, content: "test")])

    #expect(capturedBody?["model"] as? String == "gpt-4o-mini")
}

@Test("OpenAIProvider uses custom endpoint URL when provided")
func openAIProviderUsesCustomEndpointURLWhenProvided() async throws {
    let customURL = URL(string: "https://custom-proxy.example.com/v1/chat/completions")!
    var capturedURL: URL?

    let provider = OpenAIProvider(
        apiKey: "sk-test",
        endpoint: customURL,
        httpClient: { request in
            capturedURL = request.url
            return (makeSuccessJSON(content: "ok"), makeHTTPResponse(status: 200, url: customURL))
        }
    )

    _ = try await provider.chat([LLMMessage(role: .user, content: "test")])

    #expect(capturedURL == customURL)
}
