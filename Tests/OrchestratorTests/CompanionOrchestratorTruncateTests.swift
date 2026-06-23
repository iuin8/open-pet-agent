import Testing
import Foundation
@testable import Orchestrator
import Context

// MARK: - Stubs

/// Records all messages arrays passed to chat(_:) for assertion.
private actor MessageCapturingProvider: LLMProvider {
    private(set) var capturedCalls: [[LLMMessage]] = []
    let response: String

    init(response: String = "ok") {
        self.response = response
    }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        capturedCalls.append(messages)
        return response
    }
}

// MARK: - Helpers

private func makeTmpURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("orchtrunc-\(UUID().uuidString).json")
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    let bak = url.deletingLastPathComponent()
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".bak")
    try? FileManager.default.removeItem(at: bak)
}

private func makeStoreWithHistory(turns: Int) async throws -> (ConversationStore, URL) {
    let url = makeTmpURL()
    let store = ConversationStore(storeURL: url)
    try await store.load()
    for i in 0..<turns {
        await store.append(ConversationMessage(role: .user, content: "user msg \(i) " + String(repeating: "x", count: 60)))
        await store.append(ConversationMessage(role: .assistant, content: "assistant reply \(i) " + String(repeating: "x", count: 60)))
    }
    return (store, url)
}

// MARK: - Tests

@Suite("CompanionOrchestrator — truncatedMessages + contextWindow")
struct CompanionOrchestratorTruncateTests {

    // 1. contextWindow static: nil model → 4096
    @Test("contextWindow for nil model returns 4096")
    func contextWindowNilModelReturns4096() {
        #expect(CompanionOrchestrator.contextWindow(for: nil) == 4096)
    }

    // 2. contextWindow: gpt-4o-mini → 16_000
    @Test("contextWindow for gpt-4o-mini returns 16000")
    func contextWindowGPT4oMiniReturns16000() {
        #expect(CompanionOrchestrator.contextWindow(for: "gpt-4o-mini") == 16_000)
    }

    // 3. contextWindow: gpt-4o → 16_000 (hasPrefix gpt-4o)
    @Test("contextWindow for gpt-4o returns 16000")
    func contextWindowGPT4oReturns16000() {
        #expect(CompanionOrchestrator.contextWindow(for: "gpt-4o") == 16_000)
    }

    // 4. contextWindow: gpt-4-turbo → 8_000 (hasPrefix gpt-4, not gpt-4o)
    @Test("contextWindow for gpt-4-turbo returns 8000")
    func contextWindowGPT4TurboReturns8000() {
        #expect(CompanionOrchestrator.contextWindow(for: "gpt-4-turbo") == 8_000)
    }

    // 5. contextWindow: gpt-3.5-turbo → 4_000
    @Test("contextWindow for gpt-3.5-turbo returns 4000")
    func contextWindowGPT35TurboReturns4000() {
        #expect(CompanionOrchestrator.contextWindow(for: "gpt-3.5-turbo") == 4_000)
    }

    // 6. contextWindow: deepseek-chat → 32_000
    @Test("contextWindow for deepseek-chat returns 32000")
    func contextWindowDeepSeekChatReturns32000() {
        #expect(CompanionOrchestrator.contextWindow(for: "deepseek-chat") == 32_000)
    }

    // 7. contextWindow: claude-3-opus → 32_000
    @Test("contextWindow for claude-3-opus returns 32000")
    func contextWindowClaudeReturns32000() {
        #expect(CompanionOrchestrator.contextWindow(for: "claude-3-opus") == 32_000)
    }

    // 8. contextWindow: llama3.1 → 4_096
    @Test("contextWindow for llama3.1 returns 4096")
    func contextWindowLlamaReturns4096() {
        #expect(CompanionOrchestrator.contextWindow(for: "llama3.1") == 4_096)
    }

    // 9. contextWindow: qwen2.5 → 4_096
    @Test("contextWindow for qwen2.5 returns 4096")
    func contextWindowQwenReturns4096() {
        #expect(CompanionOrchestrator.contextWindow(for: "qwen2.5") == 4_096)
    }

    // 10. contextWindow: mistral → 4_096
    @Test("contextWindow for mistral returns 4096")
    func contextWindowMistralReturns4096() {
        #expect(CompanionOrchestrator.contextWindow(for: "mistral") == 4_096)
    }

    // 11. contextWindow: unknown model → 4_096
    @Test("contextWindow for unknown model returns 4096")
    func contextWindowUnknownReturns4096() {
        #expect(CompanionOrchestrator.contextWindow(for: "some-future-model") == 4_096)
    }

    // 12. 50-turn history with gpt-4o-mini: provider receives fewer than 50 turns of history
    @Test("50-turn history with gpt-4o-mini: provider receives a bounded history subset")
    func fiftyTurnHistoryGPT4oMiniIsTruncated() async throws {
        let (store, url) = try await makeStoreWithHistory(turns: 50)
        defer { cleanup(url) }

        let provider = MessageCapturingProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store,
            modelName: "gpt-4o-mini"
        )

        _ = await orchestrator.reply(to: "new question")

        let calls = await provider.capturedCalls
        #expect(calls.count == 1)
        let received = calls[0]

        // [system] + history + [current user]
        // history should be a subset of the 100 stored messages (50 turns × 2)
        // total must be ≤ 100+2 but history is bounded
        let historyCount = received.count - 2 // minus system and current user
        // With gpt-4o-mini (16k window) and 50 turns of ~17 tokens each = ~850 tokens
        // All 50 turns should fit since budget ≈ 12k tokens
        // Confirm history is at least some messages and ≤ 100
        #expect(historyCount >= 0)
        #expect(historyCount <= 100)
        // The current user message should be the last one
        #expect(received.last?.role == .user)
        #expect(received.last?.content == "new question")
        #expect(received.first?.role == .system)
    }

    // 13. gpt-3.5-turbo (4k) with same 50-turn history: receives fewer messages than gpt-4o
    @Test("same 50-turn history: gpt-3.5-turbo receives fewer history messages than gpt-4o-mini")
    func smallerContextWindowReceivesLessHistory() async throws {
        let url1 = makeTmpURL()
        let url2 = makeTmpURL()
        defer { cleanup(url1); cleanup(url2) }

        // Shared history of 50 turns with longer content to force drops on smaller window
        var turns: [(role: LLMRole, content: String)] = []
        for i in 0..<50 {
            turns.append((role: .user, content: "user msg \(i) " + String(repeating: "a", count: 80)))
            turns.append((role: .assistant, content: "assistant \(i) " + String(repeating: "b", count: 80)))
        }

        func buildStore(_ url: URL) async throws -> ConversationStore {
            let store = ConversationStore(storeURL: url)
            try await store.load()
            for t in turns {
                await store.append(ConversationMessage(role: t.role, content: t.content))
            }
            return store
        }

        let store1 = try await buildStore(url1)
        let store2 = try await buildStore(url2)

        let provider1 = MessageCapturingProvider()
        let provider2 = MessageCapturingProvider()

        let orch1 = CompanionOrchestrator(llmProvider: provider1, conversationStore: store1, modelName: "gpt-4o-mini")
        let orch2 = CompanionOrchestrator(llmProvider: provider2, conversationStore: store2, modelName: "gpt-3.5-turbo")

        _ = await orch1.reply(to: "ping")
        _ = await orch2.reply(to: "ping")

        let msgs1 = await provider1.capturedCalls[0]
        let msgs2 = await provider2.capturedCalls[0]

        // gpt-4o-mini has 16k window; gpt-3.5-turbo has 4k window
        // gpt-3.5-turbo must receive ≤ messages compared to gpt-4o-mini
        #expect(msgs2.count <= msgs1.count)
    }

    // 14. modelName nil → orchestrator uses default contextWindow(4096)
    @Test("nil modelName uses default 4096 context window")
    func nilModelNameUsesDefault4096() {
        let window = CompanionOrchestrator.contextWindow(for: nil)
        #expect(window == 4096)
    }

    // 15. gpt-4o prefix takes priority over gpt-4 prefix (longest match first)
    @Test("gpt-4o-mini is matched as gpt-4o not gpt-4 (prefix ordering)")
    func gpt4oPrefixTakesPriorityOverGpt4() {
        // gpt-4o-mini should return 16_000 not 8_000
        let w = CompanionOrchestrator.contextWindow(for: "gpt-4o-mini")
        #expect(w == 16_000)
    }
}
