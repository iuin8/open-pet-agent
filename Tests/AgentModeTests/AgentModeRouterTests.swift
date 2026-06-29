import Testing
@testable import AgentMode

@MainActor
@Test("AgentModeRouter 初始无 engine")
func agentModeRouterStartsWithoutEngine() async {
    let router = AgentModeRouter()
    #expect(router.currentEngine == nil)
    #expect(router.currentKind == nil)
    #expect(await router.isReady() == false)
}

@MainActor
@Test("AgentModeRouter setEngine 后记录 kind 并标记 ready")
func agentModeRouterTracksKindAfterSetEngine() async {
    let router = AgentModeRouter()
    router.setEngine(StubClaudeCodeEngine())

    #expect(router.currentEngine != nil)
    #expect(router.currentKind == .claudeCode)
    #expect(await router.isReady() == true)
}

@MainActor
@Test("AgentModeRouter setEngine 吃 any AgentEngine 存在类型(注册表 makeEngine)→ 反推 kind")
func agentModeRouterAcceptsExistentialFromRegistry() async {
    // 重构核心:setEngine 改非泛型后能直接喂 `AgentEngineRegistry.makeEngine()`
    // 返回的存在类型,kind 由 `type(of:).kind` 反推(不再靠编译期具体类型)。
    let router = AgentModeRouter()
    let engine: any AgentEngine = AgentEngineRegistry.codex.makeEngine()
    router.setEngine(engine)

    #expect(router.currentEngine != nil)
    #expect(router.currentKind == .codex)
}

@MainActor
@Test("AgentModeRouter setEngine(nil) 清空 engine")
func agentModeRouterClearsEngineWhenSetNil() async {
    let router = AgentModeRouter()
    router.setEngine(StubClaudeCodeEngine())
    router.setEngine(Optional<StubClaudeCodeEngine>.none)

    #expect(router.currentEngine == nil)
    #expect(router.currentKind == nil)
    #expect(await router.isReady() == false)
}

@MainActor
@Test("AgentModeRouter 无 engine 时 runAgent throw notImplemented")
func agentModeRouterRunToolThrowsWhenNoEngine() async {
    let router = AgentModeRouter()
    let stream = router.runAgent(prompt: "test")

    var caught: AgentEngineError?
    do {
        for try await _ in stream {
            // 不应该有任何 chunk
        }
    } catch let error as AgentEngineError {
        caught = error
    } catch {
        Issue.record("意外错误类型: \(error)")
    }

    #expect(caught == .notImplemented(.claudeCode))
}

@MainActor
@Test("AgentModeRouter 有 engine 时 runAgent 转发到 engine")
func agentModeRouterRunToolForwardsToEngine() async throws {
    let router = AgentModeRouter()
    router.setEngine(StubClaudeCodeEngine())

    let stream = router.runAgent(prompt: "hello")
    var collected: [String] = []
    for try await chunk in stream {
        collected.append(chunk)
    }

    #expect(!collected.isEmpty)
    #expect(collected.joined().contains("未接入"))
}
