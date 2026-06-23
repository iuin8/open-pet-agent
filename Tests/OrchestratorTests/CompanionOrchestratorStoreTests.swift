import Testing
import Foundation
@testable import Orchestrator
import Context

// MARK: - Stubs

/// Records all messages arrays passed to chat(_:) for assertion.
private actor StubRecordingProvider: LLMProvider {
    private(set) var callCount = 0
    private(set) var lastReceivedMessages: [LLMMessage] = []
    private(set) var allReceivedMessages: [[LLMMessage]] = []
    let response: String

    init(response: String = "stub reply") {
        self.response = response
    }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        callCount += 1
        lastReceivedMessages = messages
        allReceivedMessages.append(messages)
        return response
    }
}

private actor ThrowingStubProvider: LLMProvider {
    private(set) var callCount = 0

    func chat(_ messages: [LLMMessage]) async throws -> String {
        callCount += 1
        throw LLMProviderError.httpError(status: 503, body: "unavailable")
    }
}

private func makeTmpURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("orchstore-\(UUID().uuidString).json")
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    let bak = url.deletingLastPathComponent()
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".bak")
    try? FileManager.default.removeItem(at: bak)
}

private func makeStore() async throws -> (ConversationStore, URL) {
    let url = makeTmpURL()
    let store = ConversationStore(storeURL: url)
    try await store.load()
    return (store, url)
}

// MARK: - Tests

@Suite("CompanionOrchestrator + ConversationStore integration")
struct CompanionOrchestratorStoreTests {

    // MARK: 1. reply → store contains user message

    @Test("reply appends user message to store")
    func replyAppendsUserMessageToStore() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = StubRecordingProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        _ = await orchestrator.reply(to: "hello world")

        let msgs = await store.messages()
        let userMsgs = msgs.filter { $0.role == .user }
        #expect(userMsgs.count == 1)
        #expect(userMsgs[0].content == "hello world")
    }

    // MARK: 2. reply success → store contains assistant message

    @Test("reply success appends assistant message to store")
    func replySuccessAppendsAssistantMessageToStore() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = StubRecordingProvider(response: "assistant answer")
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        _ = await orchestrator.reply(to: "question")

        let msgs = await store.messages()
        let assistantMsgs = msgs.filter { $0.role == .assistant }
        #expect(assistantMsgs.count == 1)
        #expect(assistantMsgs[0].content == "assistant answer")
    }

    // MARK: 3. provider receives [system, ...history, user]

    @Test("provider receives [system, user] on first call with empty history")
    func providerReceivesSystemAndUserOnFirstCall() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = StubRecordingProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        _ = await orchestrator.reply(to: "my question")

        let received = await provider.lastReceivedMessages
        #expect(received.count >= 2)
        #expect(received.first?.role == .system)
        #expect(received.last?.role == .user)
        #expect(received.last?.content == "my question")
    }

    // MARK: 4. second reply contains history from first reply

    @Test("second reply sends history from first reply to provider")
    func secondReplySendsHistoryFromFirstReply() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = StubRecordingProvider(response: "first response")
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        _ = await orchestrator.reply(to: "first message")
        _ = await orchestrator.reply(to: "second message")

        let allCalls = await provider.allReceivedMessages
        #expect(allCalls.count == 2)

        let secondCall = allCalls[1]
        // [system, user("first message"), assistant("first response"), user("second message")]
        let roles = secondCall.map(\.role)
        #expect(roles.contains(.system))
        #expect(roles.filter { $0 == .user }.count == 2)
        #expect(roles.filter { $0 == .assistant }.count == 1)

        // First user message is "first message"
        let userMsgs = secondCall.filter { $0.role == .user }
        #expect(userMsgs[0].content == "first message")
        #expect(userMsgs[1].content == "second message")

        // Assistant message from first call
        let assistantMsgs = secondCall.filter { $0.role == .assistant }
        #expect(assistantMsgs[0].content == "first response")
    }

    // MARK: 5. provider throws → user message stored, assistant NOT stored

    @Test("provider throw stores user message but not assistant message")
    func providerThrowStoresUserButNotAssistant() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = ThrowingStubProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        _ = await orchestrator.reply(to: "failing question")

        let msgs = await store.messages()
        #expect(msgs.filter { $0.role == .user }.count == 1)
        #expect(msgs.filter { $0.role == .assistant }.isEmpty)
    }

    // MARK: 6. provider throws → echo string NOT stored

    @Test("echo fallback string is not stored in conversation store")
    func echoFallbackNotStoredInConversationStore() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = ThrowingStubProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store
        )

        let echo = await orchestrator.reply(to: "echo me")
        // The echo string contains the original message wrapped
        #expect(echo.contains("echo me"))

        let msgs = await store.messages()
        let assistantMsgs = msgs.filter { $0.role == .assistant }
        // Echo string must NOT be in store as assistant message
        for msg in assistantMsgs {
            #expect(msg.content != echo)
        }
    }

    // MARK: 7. nil store → reply still works (backward compat)

    @Test("nil conversationStore preserves existing echo behaviour")
    func nilConversationStorePreservesEchoBehaviour() async throws {
        let orchestrator = CompanionOrchestrator(
            llmProvider: nil,
            conversationStore: nil
        )

        let reply = await orchestrator.reply(to: "backward compat")
        #expect(reply.contains("backward compat"))
    }

    // MARK: 8. nil store with real provider → reply returns provider response

    @Test("nil conversationStore with provider returns provider response")
    func nilConversationStoreWithProviderReturnsProviderResponse() async throws {
        let provider = StubRecordingProvider(response: "no store response")
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: nil
        )

        let reply = await orchestrator.reply(to: "no store")
        #expect(reply == "no store response")
    }
}
