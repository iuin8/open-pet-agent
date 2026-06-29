import Foundation
import Testing
import AgentMode
@testable import Orchestrator

// MARK: - CompanionOrchestrator + Tool Mode 集成测试
//
// 验证 `replyStream(for:)` 在 Tool Mode 开关切换时正确路由 ——
// 工具层启用 → 走 `AgentModeBox.runAgent` 子进程路径 (绕过 LLM)。
// 工具层禁用 → 走 LLM `provider.streamChat` 灵魂层路径。
// 关键点: 工具层路径不能跑 SSE idle watchdog (子进程时长跟 SSE idle 无关)。

/// 测试用 stub provider —— 灵魂层在被 "误调用" 时记录一次, 用来反证工具层
/// 真的拦截了 prompt 而非两条路径都跑了。
private final class TrackingStreamingProvider: LLMProvider, Sendable {
    private let storage = Storage()

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        var callCount = 0
        var lastMessages: [LLMMessage] = []
        func recordCall(_ messages: [LLMMessage]) {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            lastMessages = messages
        }
        func read() -> (Int, [LLMMessage]) {
            lock.lock()
            defer { lock.unlock() }
            return (callCount, lastMessages)
        }
    }

    var callCount: Int { storage.read().0 }
    var lastMessages: [LLMMessage] { storage.read().1 }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        storage.recordCall(messages)
        return "LLM-FALLBACK"
    }

    nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let storage = self.storage
        return AsyncThrowingStream { continuation in
            Task {
                storage.recordCall(messages)
                continuation.yield("LLM-")
                continuation.yield("FALLBACK")
                continuation.finish()
            }
        }
    }
}

@Suite("CompanionOrchestrator Tool Mode 路由")
struct CompanionOrchestratorAgentModeTests {

    @Test("工具层启用 + engine 注册 → replyStream 走 AgentEngine, 不调 LLM provider")
    @MainActor
    func agentModeEnabledRoutesToAgentEngine() async throws {
        let router = AgentModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = AgentModeBox { router }
        let llm = TrackingStreamingProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: llm,
            agentModeBox: box
        )

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "测试 prompt") {
            collected += delta
        }

        // 工具层路径吐出 stub 占位文本 (含 "未接入") 而非 LLM 路径的
        // "LLM-FALLBACK"。同时 LLM provider 应该没被调用过。
        #expect(collected.contains("未接入"))
        #expect(collected.contains("LLM-FALLBACK") == false)
        #expect(llm.callCount == 0)
    }

    @Test("工具层禁用 → replyStream 走 LLM provider 灵魂层 (现有行为不破)")
    @MainActor
    func agentModeDisabledRoutesToLLMProvider() async throws {
        let router = AgentModeRouter()
        // 故意不 setEngine, router 存在但 engine=nil
        let box = AgentModeBox { router }
        let llm = TrackingStreamingProvider()
        let orchestrator = CompanionOrchestrator(
            llmProvider: llm,
            agentModeBox: box
        )

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "another prompt") {
            collected += delta
        }

        #expect(collected == "LLM-FALLBACK")
        #expect(llm.callCount == 1)
    }

    @Test("工具层启用时 user + assistant 都入 conversation store")
    @MainActor
    func agentModeRecordsUserAndAssistantInStore() async throws {
        let router = AgentModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = AgentModeBox { router }
        let store = ConversationStore()
        let orchestrator = CompanionOrchestrator(
            agentModeBox: box,
            conversationStore: store
        )

        var accumulated = ""
        for try await delta in orchestrator.replyStream(for: "你好工具层") {
            accumulated += delta
        }

        let messages = await store.messages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "你好工具层")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == accumulated)
        #expect(messages[1].content.contains("未接入"))
    }

    @Test("默认 init (无 box / 无 provider) → 显示 providerNotConfigured 提示, 不 crash")
    func defaultInitFallsBackToProviderNotConfiguredMessage() async throws {
        let orchestrator = CompanionOrchestrator()  // 默认空 agentModeBox + 无 provider

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "anything") {
            collected += delta
        }
        // 工具层默认空, provider 也没配 → 走 LLMProviderBox 为空的 fallback 路径,
        // yield providerNotConfiguredMessage。
        #expect(collected == CompanionOrchestrator.providerNotConfiguredMessage)
    }
}
