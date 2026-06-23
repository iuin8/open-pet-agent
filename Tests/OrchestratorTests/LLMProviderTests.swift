import Testing
import Foundation
@testable import Orchestrator

// MARK: - LLMMessage Tests

@Test("LLMMessage initialises with role and content")
func llmMessageInitialisesWithRoleAndContent() {
    let message = LLMMessage(role: .user, content: "hello")

    #expect(message.role == .user)
    #expect(message.content == "hello")
}

@Test("LLMMessage equality based on role and content")
func llmMessageEqualityBasedOnRoleAndContent() {
    let a = LLMMessage(role: .system, content: "sys")
    let b = LLMMessage(role: .system, content: "sys")
    let c = LLMMessage(role: .user, content: "sys")

    #expect(a == b)
    #expect(a != c)
}

@Test("LLMMessage is Codable round-trip")
func llmMessageIsCodableRoundTrip() throws {
    let original = LLMMessage(role: .assistant, content: "reply text")
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

    #expect(decoded == original)
}

// MARK: - LLMRole Tests

@Test("LLMRole raw values match OpenAI API strings")
func llmRoleRawValuesMatchOpenAIAPIStrings() {
    #expect(LLMRole.system.rawValue == "system")
    #expect(LLMRole.user.rawValue == "user")
    #expect(LLMRole.assistant.rawValue == "assistant")
}

@Test("LLMRole is Codable round-trip")
func llmRoleIsCodableRoundTrip() throws {
    let encoded = try JSONEncoder().encode(LLMRole.user)
    let decoded = try JSONDecoder().decode(LLMRole.self, from: encoded)

    #expect(decoded == .user)
}

// MARK: - Stub conformance: verifies the protocol compiles

private struct StubLLMProvider: LLMProvider {
    let response: String

    func chat(_ messages: [LLMMessage]) async throws -> String {
        response
    }
}

@Test("LLMProvider protocol can be implemented by a stub")
func llmProviderProtocolCanBeImplementedByAStub() async throws {
    let stub = StubLLMProvider(response: "stub response")
    let result = try await stub.chat([LLMMessage(role: .user, content: "hi")])

    #expect(result == "stub response")
}

@Test("LLMProvider stub propagates messages correctly")
func llmProviderStubPropagatesMessagesCorrectly() async throws {
    var receivedMessages: [LLMMessage] = []

    struct RecordingProvider: LLMProvider {
        let record: @Sendable ([LLMMessage]) async -> Void

        func chat(_ messages: [LLMMessage]) async throws -> String {
            await record(messages)
            return "ok"
        }
    }

    let provider = RecordingProvider { msgs in
        receivedMessages = msgs
    }

    let messages = [
        LLMMessage(role: .system, content: "system prompt"),
        LLMMessage(role: .user, content: "user input"),
    ]
    _ = try await provider.chat(messages)

    #expect(receivedMessages.count == 2)
    #expect(receivedMessages[0].role == .system)
    #expect(receivedMessages[1].role == .user)
}

// MARK: - LLMProviderError Tests

@Test("LLMProviderError missingAPIKey is equatable")
func llmProviderErrorMissingAPIKeyIsEquatable() {
    let a = LLMProviderError.missingAPIKey
    let b = LLMProviderError.missingAPIKey

    #expect(a == b)
}

@Test("LLMProviderError httpError carries status and body")
func llmProviderErrorHttpErrorCarriesStatusAndBody() {
    let error = LLMProviderError.httpError(status: 429, body: "rate limited")

    if case .httpError(let status, let body) = error {
        #expect(status == 429)
        #expect(body == "rate limited")
    } else {
        Issue.record("Expected httpError case")
    }
}

@Test("LLMProviderError decodingFailed carries description")
func llmProviderErrorDecodingFailedCarriesDescription() {
    let error = LLMProviderError.decodingFailed("no choices key")

    if case .decodingFailed(let desc) = error {
        #expect(desc == "no choices key")
    } else {
        Issue.record("Expected decodingFailed case")
    }
}

@Test("LLMProviderError transportError carries description")
func llmProviderErrorTransportErrorCarriesDescription() {
    let error = LLMProviderError.transportError("connection refused")

    if case .transportError(let desc) = error {
        #expect(desc == "connection refused")
    } else {
        Issue.record("Expected transportError case")
    }
}

@Test("LLMProviderError emptyResponse is equatable")
func llmProviderErrorEmptyResponseIsEquatable() {
    #expect(LLMProviderError.emptyResponse == LLMProviderError.emptyResponse)
}

@Test("Distinct LLMProviderError cases are not equal")
func distinctLLMProviderErrorCasesAreNotEqual() {
    #expect(LLMProviderError.missingAPIKey != LLMProviderError.emptyResponse)
    #expect(LLMProviderError.httpError(status: 401, body: "a") != LLMProviderError.httpError(status: 500, body: "a"))
    #expect(LLMProviderError.decodingFailed("x") != LLMProviderError.decodingFailed("y"))
    #expect(LLMProviderError.transportError("x") != LLMProviderError.transportError("y"))
}
