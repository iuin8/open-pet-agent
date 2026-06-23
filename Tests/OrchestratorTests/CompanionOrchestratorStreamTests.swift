import Testing
@testable import Orchestrator
import Context
import Rendering
import RuntimeBridge

// MARK: - Streaming Provider Stubs

/// Streaming provider that yields a fixed sequence of chunks.
/// Uses `nonisolated` on `streamChat` to satisfy Swift 6 actor conformance rules.
private final class StubStreamingProvider: LLMProvider, Sendable {
    private let chunks: [String]

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        chunks.joined()
    }

    nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let capturedChunks = chunks
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in capturedChunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

/// Provider that throws on streamChat mid-stream after one chunk.
private final class ThrowingStreamProvider: LLMProvider, Sendable {
    func chat(_ messages: [LLMMessage]) async throws -> String {
        throw LLMProviderError.httpError(status: 503, body: "error")
    }

    nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield("partial")
                continuation.finish(throwing: LLMProviderError.transportError("mid-stream failure"))
            }
        }
    }
}

// MARK: - Tests

@Suite("CompanionOrchestrator streaming")
struct CompanionOrchestratorStreamTests {

    @Test("reply with onPartialReply calls callback for each chunk yielded")
    func replyWithOnPartialReplyCallsCallbackForEachChunkYielded() async throws {
        let provider = StubStreamingProvider(chunks: ["Hello", ", ", "World"])
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        var partials: [String] = []
        let final = await orchestrator.reply(
            to: "hi",
            onPartialReply: { accumulated in
                partials.append(accumulated)
            }
        )

        // 3 chunks → 3 partial callbacks with accumulated strings
        #expect(partials.count == 3)
        #expect(partials[0] == "Hello")
        #expect(partials[1] == "Hello, ")
        #expect(partials[2] == "Hello, World")
        // Final return value equals the fully accumulated string
        #expect(final == "Hello, World")
    }

    @Test("reply with onPartialReply returns full accumulated string as return value")
    func replyWithOnPartialReplyReturnsFinalAccumulatedString() async throws {
        let provider = StubStreamingProvider(chunks: ["A", "B", "C"])
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        let result = await orchestrator.reply(
            to: "test",
            onPartialReply: { _ in }
        )

        #expect(result == "ABC")
    }

    @Test("reply with nil onPartialReply uses atomic chat path (backward compat)")
    func replyWithNilOnPartialReplyUsesAtomicChatPath() async throws {
        let provider = StubStreamingProvider(chunks: ["atomic response"])
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        let result = await orchestrator.reply(to: "test", onPartialReply: nil)

        // Atomic path: chat() returns chunks.joined() = "atomic response"
        #expect(result == "atomic response")
    }

    @Test("reply with onPartialReply appends only the final complete message to ConversationStore")
    func replyWithOnPartialReplyAppendsOnlyFinalMessageToStore() async throws {
        let store = ConversationStore()
        let provider = StubStreamingProvider(chunks: ["first", " second", " third"])
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        _ = await orchestrator.reply(
            to: "question",
            onPartialReply: { _ in }
        )

        // Store should have: 1 user message + 1 assistant message (not 3 partials)
        let messages = await store.messages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "question")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "first second third")
    }

    @Test("reply with onPartialReply falls back to echo and calls onThinkingEnded failure on stream error")
    func replyWithOnPartialReplyFallsBackOnStreamError() async throws {
        let provider = ThrowingStreamProvider()
        let orchestrator = CompanionOrchestrator(llmProvider: provider)

        var thinkingEndedResult: Result<String, Error>?
        let result = await orchestrator.reply(
            to: "hello",
            onThinkingEnded: { thinkingEndedResult = $0 },
            onPartialReply: { _ in }
        )

        // Should fall back to echo
        let expected = "\u{6211}\u{542C}\u{5230}\u{201C}hello\u{201D}\u{4E86}\u{3002}"
        #expect(result == expected)
        // onThinkingEnded receives failure
        if case .failure = thinkingEndedResult {
            // expected
        } else {
            Issue.record("Expected .failure but got \(String(describing: thinkingEndedResult))")
        }
    }

    @Test("default streamChat extension yields full chat response as single token")
    func defaultStreamChatExtensionYieldsFullChatResponseAsSingleToken() async throws {
        // This provider only implements chat(), not streamChat().
        // The default extension impl should yield the full response once then finish.
        struct StubAtomicProvider: LLMProvider {
            func chat(_ messages: [LLMMessage]) async throws -> String { "full response" }
        }

        let provider = StubAtomicProvider()
        var collected: [String] = []
        for try await delta in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {
            collected.append(delta)
        }

        #expect(collected == ["full response"])
    }

    @Test("default streamChat extension propagates error from chat")
    func defaultStreamChatExtensionPropagatesErrorFromChat() async throws {
        struct ThrowingAtomicProvider: LLMProvider {
            func chat(_ messages: [LLMMessage]) async throws -> String {
                throw LLMProviderError.emptyResponse
            }
        }

        let provider = ThrowingAtomicProvider()
        await #expect(throws: LLMProviderError.self) {
            for try await _ in provider.streamChat([LLMMessage(role: .user, content: "hi")]) {}
        }
    }

    // MARK: - replyStream(for:)

    @Test("replyStream yields delta tokens and store has full reply after stream finishes")
    func replyStreamYieldsDeltaTokensAndStoreHasFullReplyAfterFinish() async throws {
        let store = ConversationStore()
        let provider = StubStreamingProvider(chunks: ["Hello", " World"])
        let orchestrator = CompanionOrchestrator(llmProvider: provider, conversationStore: store)

        var collected: [String] = []
        for try await delta in orchestrator.replyStream(for: "test") {
            collected.append(delta)
        }

        #expect(collected == ["Hello", " World"])

        let messages = await store.messages()
        #expect(messages.count == 2)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "Hello World")
    }
}
