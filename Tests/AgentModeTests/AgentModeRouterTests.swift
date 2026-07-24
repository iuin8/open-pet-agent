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


// MARK: - P5 @mention 引擎池

/// P5 池测试 stub:`class var kind` 子类覆盖换 kind;记录 prompts 验证路由去向。
private class PoolStubEngine: AgentEngine, @unchecked Sendable {
    class var kind: AgentEngineKind { .openCode }
    private(set) var prompts: [String] = []
    var available = true
    var isAvailable: Bool { available }

    func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        let tag = Self.kind.rawValue
        return AsyncThrowingStream { c in
            c.yield("ok-\(tag)")
            c.finish()
        }
    }
}
private final class CodexPoolStub: PoolStubEngine {
    override class var kind: AgentEngineKind { .codex }
}
private final class OpenCodePoolStub: PoolStubEngine {
    override class var kind: AgentEngineKind { .openCode }
}

@MainActor
@Suite("AgentModeRouter P5 引擎池")
struct AgentModeRouterPoolTests {

    @Test("engine(for:) 当前 engine 同 kind → 直接用,不调工厂")
    func engineForCurrentKindReusesCurrent() {
        let router = AgentModeRouter()
        let current = OpenCodePoolStub()
        router.setEngine(current)
        var factoryCalls = 0
        router.engineFactory = { _ in factoryCalls += 1; return CodexPoolStub() }

        let e = router.engine(for: .openCode)

        #expect((e as? OpenCodePoolStub) === current)
        #expect(factoryCalls == 0)
    }

    @Test("engine(for:) 池懒建一次,二次命中缓存")
    func engineForPoolsLazily() {
        let router = AgentModeRouter()
        router.setEngine(OpenCodePoolStub())
        var factoryCalls = 0
        router.engineFactory = { kind in
            factoryCalls += 1
            return kind == .codex ? CodexPoolStub() : nil
        }

        let first = router.engine(for: .codex)
        let second = router.engine(for: .codex)

        #expect(first != nil)
        #expect((first as? CodexPoolStub) === (second as? CodexPoolStub))
        #expect(factoryCalls == 1)
    }

    @Test("existingPooledEngine 不触发懒建(未建 → nil)")
    func existingPooledDoesNotCreate() {
        let router = AgentModeRouter()
        var factoryCalls = 0
        router.engineFactory = { _ in factoryCalls += 1; return CodexPoolStub() }

        #expect(router.existingPooledEngine(for: .codex) == nil)
        #expect(factoryCalls == 0)
    }

    @Test("runAgent(kind:) 路由到池引擎,当前 engine 收不到")
    func runAgentKindRoutesToPool() async throws {
        let router = AgentModeRouter()
        let current = OpenCodePoolStub()
        router.setEngine(current)
        let codex = CodexPoolStub()
        router.engineFactory = { _ in codex }

        var collected = ""
        for try await d in router.runAgent(prompt: "hi", kind: .codex) { collected += d }

        #expect(collected == "ok-codex")
        #expect(codex.prompts == ["hi"])
        #expect(current.prompts.isEmpty)
    }

    @Test("runAgent(kind:) 当前 engine 同 kind → 直跑当前(不入池不 prepare)")
    func runAgentKindCurrentDirect() async throws {
        let router = AgentModeRouter()
        let current = OpenCodePoolStub()
        router.setEngine(current)
        var prepared = 0
        router.preparePooledEngine = { _, _ in prepared += 1 }

        for try await _ in router.runAgent(prompt: "直跑", kind: .openCode) {}

        #expect(current.prompts == ["直跑"])
        #expect(prepared == 0)
    }

    @Test("runAgent(kind:) 工厂无法构建 → throw notImplemented(kind)")
    func runAgentKindUnavailableThrows() async {
        let router = AgentModeRouter()
        router.setEngine(OpenCodePoolStub())
        router.engineFactory = { _ in nil }

        var caught: AgentEngineError?
        do {
            for try await _ in router.runAgent(prompt: "x", kind: .codex) {}
        } catch let e as AgentEngineError {
            caught = e
        } catch {
            Issue.record("意外错误类型: \(error)")
        }

        #expect(caught == .notImplemented(.codex))
    }

    @Test("池引擎首跑前 prepare 一次;二跑不重复;默认 run 不 prepare")
    func prepareOnceForPooled() async throws {
        let router = AgentModeRouter()
        let current = OpenCodePoolStub()
        router.setEngine(current)
        let codex = CodexPoolStub()
        router.engineFactory = { _ in codex }
        var prepared: [AgentEngineKind] = []
        router.preparePooledEngine = { kind, _ in prepared.append(kind) }

        for try await _ in router.runAgent(prompt: "一", kind: .codex) {}
        for try await _ in router.runAgent(prompt: "二", kind: .codex) {}
        for try await _ in router.runAgent(prompt: "三") {}   // 默认当前 engine

        #expect(prepared == [.codex])
        #expect(codex.prompts == ["一", "二"])
        #expect(current.prompts == ["三"])
    }

    @Test("clearPooledEngines → 再 @ 时工厂重建 + prepare 重跑(项目切换场景)")
    func clearPoolReCreates() async throws {
        let router = AgentModeRouter()
        router.setEngine(OpenCodePoolStub())
        var factoryCalls = 0
        router.engineFactory = { _ in factoryCalls += 1; return CodexPoolStub() }
        var prepared = 0
        router.preparePooledEngine = { _, _ in prepared += 1 }

        _ = router.engine(for: .codex)
        for try await _ in router.runAgent(prompt: "x", kind: .codex) {}
        router.clearPooledEngines()
        #expect(router.existingPooledEngine(for: .codex) == nil)

        _ = router.engine(for: .codex)
        for try await _ in router.runAgent(prompt: "y", kind: .codex) {}

        #expect(factoryCalls == 2)
        #expect(prepared == 2)
    }
}
