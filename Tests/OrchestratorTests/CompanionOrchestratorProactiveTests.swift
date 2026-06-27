import Foundation
import Testing
import Context
@testable import Orchestrator

@Suite("CompanionOrchestrator+Proactive")
struct CompanionOrchestratorProactiveTests {
    /// 记录收到的 messages 的 spy provider。
    actor SpyProvider: LLMProvider {
        var lastMessages: [LLMMessage] = []
        func chat(_ messages: [LLMMessage]) async throws -> String {
            lastMessages = messages
            return "你好呀"
        }
    }

    @Test("proactiveSuggestion 三段式 [专用 system + few-shot + user 场景]，不含 history / 不复用 chat 上下文")
    func noHistoryMessages() async throws {
        let spy = SpyProvider()
        // conversationStore 预置历史——验证主动入口不把它拼进去
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proactive-\(UUID()).json")
        let store = ConversationStore(storeURL: tmp)
        await store.append(ConversationMessage(role: .user, content: "历史问题"))
        await store.append(ConversationMessage(role: .assistant, content: "历史回答"))

        let orchestrator = CompanionOrchestrator(
            llmProvider: spy,
            conversationStore: store,
            modelName: nil   // proactiveSuggestion 不依赖 modelName（不走 truncatedMessages）
        )
        let snap = DesktopSnapshot(visibleApplicationName: "Xcode")
        // 传入含用户 persona 的 system prompt（引擎实际就这么组好传入）。
        let sys = ProactivePromptComposer.systemPrompt(personaText: "叫我老王，后端工程师")
        let reply = try await orchestrator.proactiveSuggestion(systemPrompt: sys, for: "测试 prompt", snapshot: snap)

        #expect(reply == "你好呀")
        let msgs = await spy.lastMessages
        // 结构：1 个专用 system + 每条 few-shot 2 条（user 场景 + assistant 示范）+ 1 条真实 user。
        let expectedCount = 1 + ProactivePromptComposer.fewShotExamples.count * 2 + 1
        #expect(msgs.count == expectedCount)
        // 专用 pet persona system（不是 chat 的助手 persona，不含桌面上下文 "Xcode"）
        #expect(msgs.first?.role == .system)
        #expect(msgs.first?.content.contains("只说一句") == true)
        #expect(msgs.first?.content.contains("Xcode") == false)
        // 传入的用户 persona 被原样用作 system（orchestrator 不再引用静态基底）。
        #expect(msgs.first?.content.contains("老王") == true)
        // few-shot：至少有一条 assistant 示范，且示范不来自历史
        #expect(msgs.contains { $0.role == .assistant })
        // 真实场景在最后一条 user
        #expect(msgs.last?.role == .user)
        #expect(msgs.last?.content == "测试 prompt")
        // 不含历史
        #expect(!msgs.contains { $0.content == "历史问题" })
        #expect(!msgs.contains { $0.content == "历史回答" })
    }

    /// 只实现 streamChat、多 delta 流式 spy —— 验证 proactiveSuggestion 走流式累积
    /// （不是退化到默认单 chunk 包装）。这是「只支持流式的端点」上能工作的关键。
    actor StreamingSpyProvider: LLMProvider {
        var lastMessages: [LLMMessage] = []
        func chat(_ messages: [LLMMessage]) async throws -> String {
            // 非流式路径不应被主动建议触达——若被调到说明回退了，返回哨兵便于断言失败。
            lastMessages = messages
            return "__NONSTREAM__"
        }
        nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                for delta in ["凌晨", "了，", "早点", "休息"] { continuation.yield(delta) }
                continuation.finish()
            }
        }
    }

    @Test("proactiveSuggestion 走流式累积多 delta（兼容只支持流式的端点）")
    func accumulatesStreamingDeltas() async throws {
        let spy = StreamingSpyProvider()
        let orchestrator = CompanionOrchestrator(llmProvider: spy, modelName: nil)
        let reply = try await orchestrator.proactiveSuggestion(
            systemPrompt: ProactivePromptComposer.systemPrompt(personaText: ""), for: "测试", snapshot: nil)
        #expect(reply == "凌晨了，早点休息")
    }

    @Test("流式返回空 → 抛 emptyResponse（引擎静默跳过）")
    func emptyStreamThrows() async {
        actor EmptyStreamProvider: LLMProvider {
            func chat(_ messages: [LLMMessage]) async throws -> String { "" }
            nonisolated func streamChat(_ messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let orchestrator = CompanionOrchestrator(llmProvider: EmptyStreamProvider(), modelName: nil)
        await #expect(throws: LLMProviderError.emptyResponse) {
            _ = try await orchestrator.proactiveSuggestion(
                systemPrompt: ProactivePromptComposer.systemPrompt(personaText: ""), for: "x", snapshot: nil)
        }
    }

    @Test("流式累积硬上限 2000 字 — 防模型疯狂输出")
    func streamingCapsRunaway() async throws {
        actor RunawayProvider: LLMProvider {
            func chat(_ m: [LLMMessage]) async throws -> String { "" }
            nonisolated func streamChat(_ m: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    for _ in 0..<5000 { c.yield("字") }   // 5000 字 → 应被截到 2000
                    c.finish()
                }
            }
        }
        let orchestrator = CompanionOrchestrator(llmProvider: RunawayProvider(), modelName: nil)
        let reply = try await orchestrator.proactiveSuggestion(
            systemPrompt: ProactivePromptComposer.systemPrompt(personaText: ""), for: "x", snapshot: nil)
        #expect(reply.count == 2000)   // 每 delta 1 字,break 在 count>=2000 → 恰好 2000
    }

    @Test("无 provider → 抛 missingAPIKey")
    func noProviderThrows() async {
        let orchestrator = CompanionOrchestrator()  // 无 provider
        await #expect(throws: LLMProviderError.self) {
            _ = try await orchestrator.proactiveSuggestion(
                systemPrompt: ProactivePromptComposer.systemPrompt(personaText: ""), for: "x", snapshot: nil)
        }
    }

    @Test("proactiveSuggestion 不写 conversationStore")
    func doesNotWriteStore() async throws {
        let spy = SpyProvider()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proactive-\(UUID()).json")
        let store = ConversationStore(storeURL: tmp)
        let orchestrator = CompanionOrchestrator(llmProvider: spy, conversationStore: store, modelName: nil)
        _ = try await orchestrator.proactiveSuggestion(
            systemPrompt: ProactivePromptComposer.systemPrompt(personaText: ""), for: "p", snapshot: nil)
        let stored = await store.messages()
        #expect(stored.isEmpty)
    }
}
