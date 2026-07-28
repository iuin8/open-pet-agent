import Foundation
import Testing
import AgentMode
@testable import Orchestrator

/// 测试用 hermetic ConversationStore:绝不碰默认 Application Support 路径 ——
/// 那里是用户真实数据(默认 init 会造成真实历史被测试覆盖,且 macOS provenance
/// 会跨 app 触发内核级 rename 阻塞,2026-07-26 实测卡死六个测试)。
private func makeHermeticStore() -> ConversationStore {
    ConversationStore(storeURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("test-conversations-\(UUID().uuidString).json"))
}

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
        let store = makeHermeticStore()
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

    // MARK: - P4 跨引擎交接

    @Test("agent 模式 + handoff 背景非 nil → engine 收到包装 prompt;store 只记用户原文")
    @MainActor
    func agentHandoffWrapsFirstPrompt() async throws {
        let router = AgentModeRouter()
        let engine = PromptRecordingEngine()
        router.setEngine(engine)
        let box = AgentModeBox { router }
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(
            agentModeBox: box,
            conversationStore: store,
            agentHandoffContext: { _ in "user: 之前聊过数字42" }
        )

        for try await _ in orchestrator.replyStream(for: "新消息") {}

        #expect(engine.prompts.count == 1)
        let sent = engine.prompts[0]
        #expect(sent.contains("[背景交接]"))
        #expect(sent.contains("user: 之前聊过数字42"))
        #expect(sent.contains("新消息"))
        // store 记的是用户原文,不是交接包装(防摘要滚雪球进记忆)
        let messages = await store.messages()
        #expect(messages.first?.content == "新消息")
    }

    @Test("handoff 背景 nil → prompt 原样直发(无包装)")
    @MainActor
    func noHandoffSendsRawPrompt() async throws {
        let router = AgentModeRouter()
        let engine = PromptRecordingEngine()
        router.setEngine(engine)
        let box = AgentModeBox { router }
        let orchestrator = CompanionOrchestrator(agentModeBox: box)

        for try await _ in orchestrator.replyStream(for: "原样") {}

        #expect(engine.prompts == ["原样"])
    }
}

/// P4 测试 stub:记录收到的 prompt 并回固定文本(验证交接包装进了 engine 的 prompt)。
private final class PromptRecordingEngine: AgentEngine, @unchecked Sendable {
    static let kind: AgentEngineKind = .claudeCode
    var isAvailable: Bool { true }
    private(set) var prompts: [String] = []

    func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}


// MARK: - P5 @mention 路由

/// P5 stub:codex 版记录引擎(池路由验证;`available` 可控,测不可用文案)。
private final class CodexRecordingEngine: AgentEngine, @unchecked Sendable {
    static let kind: AgentEngineKind = .codex
    var available = true
    var isAvailable: Bool { available }
    private(set) var prompts: [String] = []

    func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        return AsyncThrowingStream { c in
            c.yield("codex-ok")
            c.finish()
        }
    }
}

/// P5 stub:@Sendable 交接闭包捕获用的 kind 记录盒。
private final class MentionKindBox: @unchecked Sendable {
    var kinds: [AgentEngineKind?] = []
}

@Suite("CompanionOrchestrator P5 @mention 路由")
struct CompanionOrchestratorMentionTests {

    @Test("@codex → 路由到池化 codex engine;prompt 剥离 mention;store 记原文 + 署名 codex")
    @MainActor
    func mentionRoutesToPooledEngine() async throws {
        let router = AgentModeRouter()
        let defaultEngine = PromptRecordingEngine()   // claudeCode 当前默认
        router.setEngine(defaultEngine)
        let codex = CodexRecordingEngine()
        router.engineFactory = { kind in kind == .codex ? codex : nil }
        let box = AgentModeBox { router }
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(agentModeBox: box, conversationStore: store)

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "@codex 查一下构建") {
            collected += delta
        }

        #expect(collected == "codex-ok")
        #expect(codex.prompts == ["查一下构建"])   // engine 收剥离 mention 后的 prompt
        #expect(defaultEngine.prompts.isEmpty)     // 默认引擎没收到
        let messages = await store.messages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "@codex 查一下构建")   // store 记用户原文(带 @)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "codex-ok")
        #expect(messages[1].source == AgentEngineKind.codex.rawValue)   // 署名 = 实际跑的引擎
    }

    @Test("无 mention → 默认 engine;assistant 署名当前 kind")
    @MainActor
    func noMentionUsesDefaultEngine() async throws {
        let router = AgentModeRouter()
        let defaultEngine = PromptRecordingEngine()
        router.setEngine(defaultEngine)
        let codex = CodexRecordingEngine()
        router.engineFactory = { _ in codex }
        let box = AgentModeBox { router }
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(agentModeBox: box, conversationStore: store)

        for try await _ in orchestrator.replyStream(for: "普通一句") {}

        #expect(defaultEngine.prompts == ["普通一句"])
        #expect(codex.prompts.isEmpty)
        let messages = await store.messages()
        #expect(messages.last?.source == AgentEngineKind.claudeCode.rawValue)
    }

    @Test("@codex 不可用(CLI 缺)→ 友好文案 finish 不抛错;engine 没跑;LLM 没被误调")
    @MainActor
    func mentionUnavailableYieldsFriendlyHint() async throws {
        let router = AgentModeRouter()
        router.setEngine(PromptRecordingEngine())
        let codex = CodexRecordingEngine()
        codex.available = false   // CLI 未装
        router.engineFactory = { _ in codex }
        let box = AgentModeBox { router }
        let llm = TrackingStreamingProvider()
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(
            llmProvider: llm, agentModeBox: box, conversationStore: store)

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "@codex 干活") {
            collected += delta
        }

        #expect(collected == CompanionOrchestrator.mentionUnavailableMessage(kind: .codex))
        #expect(codex.prompts.isEmpty)   // 不可用引擎没收到 prompt
        #expect(llm.callCount == 0)      // agent 模式不掉灵魂层
        let messages = await store.messages()
        #expect(messages.count == 2)
        #expect(messages[1].content == collected)
        #expect(messages[1].source == AgentEngineKind.codex.rawValue)
    }

    @Test("@mention → handoff 闭包收到 mention kind;无 mention → 收到 nil(交接桶按实际 engine 算)")
    @MainActor
    func mentionKindFlowsToHandoffContext() async throws {
        let router = AgentModeRouter()
        router.setEngine(PromptRecordingEngine())
        let codex = CodexRecordingEngine()
        router.engineFactory = { _ in codex }
        let box = AgentModeBox { router }
        let kindBox = MentionKindBox()
        let orchestrator = CompanionOrchestrator(
            agentModeBox: box,
            agentHandoffContext: { kind in
                kindBox.kinds.append(kind)
                return nil   // 不注入包装,只验证 kind 传递
            }
        )

        for try await _ in orchestrator.replyStream(for: "@codex 第一句") {}
        for try await _ in orchestrator.replyStream(for: "第二句") {}

        #expect(kindBox.kinds.count == 2)
        #expect(kindBox.kinds[0] == .codex)
        #expect(kindBox.kinds[1] == nil)
    }

    @Test("@mention + 交接背景非 nil → 包装进 mention 目标的 prompt(剥离 mention 后包装)")
    @MainActor
    func mentionHandoffWrapsStrippedPrompt() async throws {
        let router = AgentModeRouter()
        router.setEngine(PromptRecordingEngine())
        let codex = CodexRecordingEngine()
        router.engineFactory = { _ in codex }
        let box = AgentModeBox { router }
        let orchestrator = CompanionOrchestrator(
            agentModeBox: box,
            agentHandoffContext: { _ in "user: 之前聊过数字42" }
        )

        for try await _ in orchestrator.replyStream(for: "@codex 新任务") {}

        #expect(codex.prompts.count == 1)
        let sent = codex.prompts[0]
        #expect(sent.contains("[背景交接]"))
        #expect(sent.contains("user: 之前聊过数字42"))
        #expect(sent.contains("新任务"))
        #expect(!sent.contains("@codex"))   // 包装的是剥离后的 prompt
    }
}


// MARK: - P6 模式无关路由 + @pet 逃逸

@Suite("CompanionOrchestrator P6 pin 模型路由")
struct CompanionOrchestratorPinModelTests {

    @Test("P6:灵魂层默认态(未钉,engine=nil)下 @codex 也能唤起池引擎")
    @MainActor
    func mentionWorksWithoutAgentMode() async throws {
        let router = AgentModeRouter()   // 故意不 setEngine —— 工具层关闭(未钉)
        let codex = CodexRecordingEngine()
        router.engineFactory = { kind in kind == .codex ? codex : nil }
        let box = AgentModeBox { router }
        let llm = TrackingStreamingProvider()
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(
            llmProvider: llm, agentModeBox: box, conversationStore: store)

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "@codex 查一下") {
            collected += delta
        }

        #expect(collected == "codex-ok")
        #expect(codex.prompts == ["查一下"])
        #expect(llm.callCount == 0)   // 没掉灵魂层
        let messages = await store.messages()
        #expect(messages.last?.source == AgentEngineKind.codex.rawValue)
    }

    @Test("P6:钉住引擎时 @pet 强制本条灵魂层(engine 不调,LLM 收剥离后 prompt)")
    @MainActor
    func petMentionForcesSoulWhilePinned() async throws {
        let router = AgentModeRouter()
        let engine = PromptRecordingEngine()   // 钉住 claudeCode
        router.setEngine(engine)
        let box = AgentModeBox { router }
        let llm = TrackingStreamingProvider()
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(
            llmProvider: llm, agentModeBox: box, conversationStore: store)

        var collected = ""
        for try await delta in orchestrator.replyStream(for: "@pet 今天怎么样") {
            collected += delta
        }

        #expect(collected == "LLM-FALLBACK")
        #expect(llm.callCount == 1)
        #expect(engine.prompts.isEmpty)   // 钉住的引擎没收到
        // LLM 收到的 user 消息是剥离 @pet 后的内容
        let lastUser = llm.lastMessages.last(where: { $0.role == .user })?.content
        #expect(lastUser == "今天怎么样")
        // store 记原文(带 @pet);assistant 无署名(灵魂层)
        let messages = await store.messages()
        #expect(messages.first?.content == "@pet 今天怎么样")
        #expect(messages.last?.source == nil)
    }

    @Test("P6:无 mention + 未钉 → 灵魂层(原行为);无 mention + 钉住 → 默认引擎(原行为)")
    @MainActor
    func noMentionKeepsOldBranches() async throws {
        // 未钉
        do {
            let router = AgentModeRouter()
            let box = AgentModeBox { router }
            let llm = TrackingStreamingProvider()
            let orchestrator = CompanionOrchestrator(llmProvider: llm, agentModeBox: box)
            var collected = ""
            for try await delta in orchestrator.replyStream(for: "普通") { collected += delta }
            #expect(collected == "LLM-FALLBACK")
        }
        // 钉住
        do {
            let router = AgentModeRouter()
            let engine = PromptRecordingEngine()
            router.setEngine(engine)
            let box = AgentModeBox { router }
            let orchestrator = CompanionOrchestrator(agentModeBox: box)
            for try await _ in orchestrator.replyStream(for: "普通") {}
            #expect(engine.prompts == ["普通"])
        }
    }
}


// MARK: - P7.2 图片落盘(agent 路径用户消息结构化字段)

@Suite("CompanionOrchestrator P7.2 图片落盘")
struct CompanionOrchestratorImageStoreTests {

    @Test("agent 路径:用户消息带 images 落盘(结构化字段,不进 content)")
    @MainActor
    func agentPathStoresImages() async throws {
        let router = AgentModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = AgentModeBox { router }
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(
            llmProvider: TrackingStreamingProvider(),
            agentModeBox: box,
            conversationStore: store
        )
        let image = ChatImage(data: Data([0x89, 0x50]), mediaType: "image/png")

        for try await _ in orchestrator.replyStream(for: "看图", images: [image]) {}

        let messages = await store.messages()
        #expect(messages.first?.role == .user)
        #expect(messages.first?.content == "看图")
        #expect(messages.first?.images?.count == 1)
        #expect(messages.first?.images?.first?.mediaType == "image/png")
        #expect(messages.first?.images?.first?.data == Data([0x89, 0x50]))
    }

    @Test("无图:用户消息 images 为 nil(旧行为不变)")
    @MainActor
    func noImageStoresNil() async throws {
        let router = AgentModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = AgentModeBox { router }
        let store = makeHermeticStore()
        let orchestrator = CompanionOrchestrator(
            llmProvider: TrackingStreamingProvider(),
            agentModeBox: box,
            conversationStore: store
        )

        for try await _ in orchestrator.replyStream(for: "纯文本") {}

        let messages = await store.messages()
        #expect(messages.first?.role == .user)
        #expect(messages.first?.images == nil)
    }
}
