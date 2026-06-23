import Testing
@testable import ToolMode

@MainActor
@Test("ToolModeRouter 初始无 engine")
func toolModeRouterStartsWithoutEngine() async {
    let router = ToolModeRouter()
    #expect(router.currentEngine == nil)
    #expect(router.currentKind == nil)
    #expect(await router.isReady() == false)
}

@MainActor
@Test("ToolModeRouter setEngine 后记录 kind 并标记 ready")
func toolModeRouterTracksKindAfterSetEngine() async {
    let router = ToolModeRouter()
    router.setEngine(StubClaudeCodeEngine())

    #expect(router.currentEngine != nil)
    #expect(router.currentKind == .claudeCode)
    #expect(await router.isReady() == true)
}

@MainActor
@Test("ToolModeRouter setEngine(nil) 清空 engine")
func toolModeRouterClearsEngineWhenSetNil() async {
    let router = ToolModeRouter()
    router.setEngine(StubClaudeCodeEngine())
    router.setEngine(Optional<StubClaudeCodeEngine>.none)

    #expect(router.currentEngine == nil)
    #expect(router.currentKind == nil)
    #expect(await router.isReady() == false)
}

@MainActor
@Test("ToolModeRouter 无 engine 时 runTool throw notImplemented")
func toolModeRouterRunToolThrowsWhenNoEngine() async {
    let router = ToolModeRouter()
    let stream = router.runTool(prompt: "test")

    var caught: ToolEngineError?
    do {
        for try await _ in stream {
            // 不应该有任何 chunk
        }
    } catch let error as ToolEngineError {
        caught = error
    } catch {
        Issue.record("意外错误类型: \(error)")
    }

    #expect(caught == .notImplemented(.claudeCode))
}

@MainActor
@Test("ToolModeRouter 有 engine 时 runTool 转发到 engine")
func toolModeRouterRunToolForwardsToEngine() async throws {
    let router = ToolModeRouter()
    router.setEngine(StubClaudeCodeEngine())

    let stream = router.runTool(prompt: "hello")
    var collected: [String] = []
    for try await chunk in stream {
        collected.append(chunk)
    }

    #expect(!collected.isEmpty)
    #expect(collected.joined().contains("未接入"))
}
