import Testing
import Foundation
@testable import Orchestrator

// MARK: - Helpers

private func makeAnthropicSuccessJSON(text: String) -> Data {
    // Escape any double quotes inside text
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let json = """
    {
        "id": "msg_abc123",
        "type": "message",
        "role": "assistant",
        "content": [
            {
                "type": "text",
                "text": "\(escaped)"
            }
        ],
        "model": "claude-sonnet-4-5",
        "stop_reason": "end_turn",
        "usage": {
            "input_tokens": 10,
            "output_tokens": 5
        }
    }
    """
    return Data(json.utf8)
}

private func makeAnthropicHTTPResponse(
    status: Int,
    url: URL = URL(string: "https://api.anthropic.com/v1/messages")!
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

@Suite("AnthropicProvider — atomic chat")
struct AnthropicProviderTests {

    // MARK: - Happy path

    @Test("Returns message text from content[0].text on success")
    func returnsContentTextOnSuccess() async throws {
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { _ in
                (makeAnthropicSuccessJSON(text: "Hello from Claude!"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        let result = try await provider.chat([LLMMessage(role: .user, content: "hi")])

        #expect(result == "Hello from Claude!")
    }

    @Test("Does NOT send Bearer Authorization header; uses x-api-key header instead")
    func doesNotUseBearerAuthAndUsesXAPIKey() async throws {
        var capturedRequest: URLRequest?
        let provider = AnthropicProvider(
            apiKey: "sk-ant-my-secret",
            httpClient: { request in
                capturedRequest = request
                return (makeAnthropicSuccessJSON(text: "ok"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        _ = try await provider.chat([LLMMessage(role: .user, content: "test")])

        let xApiKey = capturedRequest?.value(forHTTPHeaderField: "x-api-key")
        let authorization = capturedRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(xApiKey == "sk-ant-my-secret")
        #expect(authorization == nil, "Anthropic must NOT use Bearer Authorization header")
    }

    @Test("Sends anthropic-version header")
    func sendsAnthropicVersionHeader() async throws {
        var capturedRequest: URLRequest?
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { request in
                capturedRequest = request
                return (makeAnthropicSuccessJSON(text: "ok"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        _ = try await provider.chat([LLMMessage(role: .user, content: "test")])

        let versionHeader = capturedRequest?.value(forHTTPHeaderField: "anthropic-version")
        #expect(versionHeader == AnthropicProvider.anthropicVersion)
    }

    @Test("System messages are extracted to top-level system field, not in messages array")
    func systemMessageGoesToTopLevelField() async throws {
        var capturedBody: [String: Any]?
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { request in
                if let data = request.httpBody {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return (makeAnthropicSuccessJSON(text: "ok"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        let messages = [
            LLMMessage(role: .system, content: "You are a helpful assistant"),
            LLMMessage(role: .user, content: "What is 2+2?"),
        ]
        _ = try await provider.chat(messages)

        // system field at top level
        let systemField = capturedBody?["system"] as? String
        #expect(systemField == "You are a helpful assistant")

        // messages array must NOT contain system role
        let messagesArray = capturedBody?["messages"] as? [[String: Any]]
        #expect(messagesArray?.count == 1)
        #expect(messagesArray?[0]["role"] as? String == "user")
        #expect(messagesArray?[0]["content"] as? String == "What is 2+2?")
    }

    @Test("Multiple system messages are concatenated with newline as top-level system field")
    func multipleSystemMessagesAreConcatenated() async throws {
        var capturedBody: [String: Any]?
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { request in
                if let data = request.httpBody {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return (makeAnthropicSuccessJSON(text: "ok"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        let messages = [
            LLMMessage(role: .system, content: "Part one"),
            LLMMessage(role: .system, content: "Part two"),
            LLMMessage(role: .user, content: "Question"),
        ]
        _ = try await provider.chat(messages)

        let systemField = capturedBody?["system"] as? String
        #expect(systemField == "Part one\nPart two")

        let messagesArray = capturedBody?["messages"] as? [[String: Any]]
        #expect(messagesArray?.count == 1)
    }

    @Test("Sends max_tokens in request body")
    func sendsMaxTokensInRequestBody() async throws {
        var capturedBody: [String: Any]?
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { request in
                if let data = request.httpBody {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return (makeAnthropicSuccessJSON(text: "ok"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])

        let maxTokens = capturedBody?["max_tokens"] as? Int
        #expect(maxTokens == AnthropicProvider.defaultMaxTokens)
    }

    @Test("Chinese user content is correctly encoded in JSON body")
    func chineseUserContentIsEncodedCorrectly() async throws {
        var capturedBody: [String: Any]?
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { request in
                if let data = request.httpBody {
                    capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                return (makeAnthropicSuccessJSON(text: "你好！"), makeAnthropicHTTPResponse(status: 200))
            }
        )

        let chineseMessage = "你好，世界！请问今天天气怎么样？"
        _ = try await provider.chat([LLMMessage(role: .user, content: chineseMessage)])

        let messagesArray = capturedBody?["messages"] as? [[String: Any]]
        #expect(messagesArray?[0]["content"] as? String == chineseMessage)
    }

    // MARK: - Error paths

    @Test("Throws httpError with 401 status on unauthorized response")
    func throwsHTTPErrorOn401() async throws {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"Invalid API key"}}"#.utf8)
        let provider = AnthropicProvider(
            apiKey: "sk-ant-bad",
            httpClient: { _ in (body, makeAnthropicHTTPResponse(status: 401)) }
        )

        do {
            _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
            Issue.record("Expected error to be thrown")
        } catch let error as LLMProviderError {
            if case .httpError(let status, _) = error {
                #expect(status == 401)
            } else {
                Issue.record("Expected httpError, got \(error)")
            }
        }
    }

    @Test("Throws httpError with 429 status on rate-limited response")
    func throwsHTTPErrorOn429() async throws {
        let body = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limit exceeded"}}"#.utf8)
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { _ in (body, makeAnthropicHTTPResponse(status: 429)) }
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

    @Test("Throws decodingFailed on malformed JSON response")
    func throwsDecodingFailedOnMalformedJSON() async throws {
        let malformed = Data("not-valid-json".utf8)
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { _ in (malformed, makeAnthropicHTTPResponse(status: 200)) }
        )

        await #expect(throws: LLMProviderError.self) {
            _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
        }
    }

    @Test("Throws emptyResponse when content array is empty")
    func throwsEmptyResponseWhenContentArrayIsEmpty() async throws {
        let emptyContent = Data(#"{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":0}}"#.utf8)
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            httpClient: { _ in (emptyContent, makeAnthropicHTTPResponse(status: 200)) }
        )

        await #expect(throws: LLMProviderError.emptyResponse) {
            _ = try await provider.chat([LLMMessage(role: .user, content: "hi")])
        }
    }
}

// MARK: - splitMessages helper tests

@Suite("AnthropicProvider — splitMessages helper")
struct AnthropicSplitMessagesTests {

    @Test("Empty messages yields empty system and empty messages")
    func emptyMessagesYieldsEmptyBoth() {
        let (system, messages) = AnthropicProvider.splitMessages([])
        #expect(system == "")
        #expect(messages.isEmpty)
    }

    @Test("User-only messages: no system prompt extracted")
    func userOnlyMessagesNoSystemExtracted() {
        let input = [LLMMessage(role: .user, content: "hello")]
        let (system, messages) = AnthropicProvider.splitMessages(input)
        #expect(system == "")
        #expect(messages.count == 1)
        #expect(messages[0].role == .user)
    }

    @Test("System message is extracted; user/assistant remain in order")
    func systemExtractedAndOrderPreserved() {
        let input = [
            LLMMessage(role: .system, content: "Be helpful"),
            LLMMessage(role: .user, content: "Question"),
            LLMMessage(role: .assistant, content: "Answer"),
        ]
        let (system, messages) = AnthropicProvider.splitMessages(input)
        #expect(system == "Be helpful")
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
    }
}
