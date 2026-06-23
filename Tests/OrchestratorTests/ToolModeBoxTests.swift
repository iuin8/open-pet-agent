import Foundation
import Testing
import ToolMode
@testable import Orchestrator

// MARK: - ToolModeBox 测试
//
// 验证 `ToolModeBox` 作为 Orchestrator (非 MainActor) 与
// `ToolModeRouter` (`@MainActor`) 之间的桥, 状态查询 + runTool stream
// 行为是否与 brief 描述一致 (空 router → notImplemented; 注册 engine →
// enabled + forward stream; setEngine(nil) → 回到 disabled)。

@Suite("ToolModeBox")
struct ToolModeBoxTests {

    @Test("默认 init 无 router → isToolModeEnabled=false, currentEngineKind=nil")
    func defaultInitReportsDisabled() async {
        let box = ToolModeBox()
        let enabled = await box.isToolModeEnabled
        let kind = await box.currentEngineKind
        #expect(enabled == false)
        #expect(kind == nil)
    }

    @Test("无 router 时 runTool 立刻 throw notImplemented(.claudeCode)")
    func runToolWithoutRouterThrows() async {
        let box = ToolModeBox()
        var caught: ToolEngineError?
        do {
            for try await _ in box.runTool(prompt: "hello") {
                Issue.record("不应该有任何 chunk")
            }
        } catch let error as ToolEngineError {
            caught = error
        } catch {
            Issue.record("意外错误类型: \(error)")
        }
        #expect(caught == .notImplemented(.claudeCode))
    }

    @Test("router 存在但 engine=nil → 仍然 disabled + runTool throw notImplemented")
    @MainActor
    func routerWithoutEngineStaysDisabled() async {
        let router = ToolModeRouter()
        let box = ToolModeBox { router }

        let enabled = await box.isToolModeEnabled
        let kind = await box.currentEngineKind
        #expect(enabled == false)
        #expect(kind == nil)

        var caught: ToolEngineError?
        do {
            for try await _ in box.runTool(prompt: "x") {
                Issue.record("不应该有任何 chunk")
            }
        } catch let error as ToolEngineError {
            caught = error
        } catch {
            Issue.record("意外错误类型: \(error)")
        }
        #expect(caught == .notImplemented(.claudeCode))
    }

    @Test("router 注册 stub engine 后 isToolModeEnabled=true, currentEngineKind=.claudeCode")
    @MainActor
    func routerWithEngineReportsEnabled() async {
        let router = ToolModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = ToolModeBox { router }

        let enabled = await box.isToolModeEnabled
        let kind = await box.currentEngineKind
        #expect(enabled == true)
        #expect(kind == .claudeCode)
    }

    @Test("有 engine 时 runTool 转发 stub 输出 (含 '未接入' 占位文案)")
    @MainActor
    func runToolWithEngineForwardsStream() async throws {
        let router = ToolModeRouter()
        router.setEngine(StubClaudeCodeEngine())
        let box = ToolModeBox { router }

        var collected = ""
        for try await chunk in box.runTool(prompt: "你好") {
            collected += chunk
        }
        #expect(!collected.isEmpty)
        #expect(collected.contains("未接入"))
    }

    @Test("setEngine(nil) 后 isToolModeEnabled 回到 false (动态切换可见)")
    @MainActor
    func setEngineNilRevertsToDisabled() async {
        let router = ToolModeRouter()
        let box = ToolModeBox { router }

        router.setEngine(StubClaudeCodeEngine())
        #expect(await box.isToolModeEnabled == true)

        let none: StubClaudeCodeEngine? = nil
        router.setEngine(none)
        #expect(await box.isToolModeEnabled == false)
        #expect(await box.currentEngineKind == nil)
    }
}
