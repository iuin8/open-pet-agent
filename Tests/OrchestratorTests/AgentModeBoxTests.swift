import Foundation
import Testing
import AgentMode
@testable import Orchestrator

// MARK: - AgentModeBox 测试
//
// 验证 `AgentModeBox` 作为 Orchestrator (非 MainActor) 与
// `AgentModeRouter` (`@MainActor`) 之间的桥, 状态查询 + runAgent stream
// 行为是否与 brief 描述一致 (空 router → notImplemented; 注册 engine →
// enabled + forward stream; setEngine(nil) → 回到 disabled)。

@Suite("AgentModeBox")
struct AgentModeBoxTests {

    @Test("默认 init 无 router → isAgentModeEnabled=false, currentEngineKind=nil")
    func defaultInitReportsDisabled() async {
        let box = AgentModeBox()
        let enabled = await box.isAgentModeEnabled
        let kind = await box.currentEngineKind
        #expect(enabled == false)
        #expect(kind == nil)
    }

    @Test("无 router 时 runAgent 立刻 throw notImplemented(.claudeCode)")
    func runAgentWithoutRouterThrows() async {
        let box = AgentModeBox()
        var caught: AgentEngineError?
        do {
            for try await _ in box.runAgent(prompt: "hello") {
                Issue.record("不应该有任何 chunk")
            }
        } catch let error as AgentEngineError {
            caught = error
        } catch {
            Issue.record("意外错误类型: \(error)")
        }
        #expect(caught == .notImplemented(.claudeCode))
    }

    @Test("router 存在但 engine=nil → 仍然 disabled + runAgent throw notImplemented")
    @MainActor
    func routerWithoutEngineStaysDisabled() async {
        let router = AgentModeRouter()
        let box = AgentModeBox { router }

        let enabled = await box.isAgentModeEnabled
        let kind = await box.currentEngineKind
        #expect(enabled == false)
        #expect(kind == nil)

        var caught: AgentEngineError?
        do {
            for try await _ in box.runAgent(prompt: "x") {
                Issue.record("不应该有任何 chunk")
            }
        } catch let error as AgentEngineError {
            caught = error
        } catch {
            Issue.record("意外错误类型: \(error)")
        }
        #expect(caught == .notImplemented(.claudeCode))
    }

    @Test("router 注册 stub engine 后 isAgentModeEnabled=true, currentEngineKind=.claudeCode")
    @MainActor
    func routerWithEngineReportsEnabled() async {
        let router = AgentModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = AgentModeBox { router }

        let enabled = await box.isAgentModeEnabled
        let kind = await box.currentEngineKind
        #expect(enabled == true)
        #expect(kind == .claudeCode)
    }

    @Test("有 engine 时 runAgent 转发 stub 输出 (含 '未接入' 占位文案)")
    @MainActor
    func runAgentWithEngineForwardsStream() async throws {
        let router = AgentModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = AgentModeBox { router }

        var collected = ""
        for try await chunk in box.runAgent(prompt: "你好") {
            collected += chunk
        }
        #expect(!collected.isEmpty)
        #expect(collected.contains("未接入"))
    }

    @Test("setEngine(nil) 后 isAgentModeEnabled 回到 false (动态切换可见)")
    @MainActor
    func setEngineNilRevertsToDisabled() async {
        let router = AgentModeRouter()
        let box = AgentModeBox { router }

        router.setEngine(StubClaudeCodeEngine())
        #expect(await box.isAgentModeEnabled == true)

        let none: StubClaudeCodeEngine? = nil
        router.setEngine(none)
        #expect(await box.isAgentModeEnabled == false)
        #expect(await box.currentEngineKind == nil)
    }
}
