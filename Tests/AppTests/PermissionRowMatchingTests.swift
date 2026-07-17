import Testing
import Foundation
import AgentSensing
@testable import App

/// `MinimalAppDelegate.matchingPermissionRow` —— 权限请求 → 触发它的会话消息行匹配(纯函数)。
/// 用于「定位会话」把权限卡尖角重锚到对应行(2026-06-16)。
@Suite("权限定位:触发消息行匹配")
struct PermissionRowMatchingTests {

    /// turn 模型:一轮含一个工具 step(matchingPermissionRow 扫各轮 steps)。
    func tool(_ id: Int, _ name: String, _ state: ConversationItem.ToolState) -> ConversationItem {
        let step = TurnStep.tool(id: id, name: name, summary: "x", state: state, input: "i", output: nil, toolUseId: nil)
        let a = AssistantTurn(finalText: "", steps: [step], model: nil, contextTokens: nil, durationSeconds: nil,
                              toolCount: 1, thinkingCount: 0, hasError: state == .error, isRunning: state == .running)
        return ConversationItem(id: id, kind: .assistantTurn(a), timestamp: Date(timeIntervalSince1970: TimeInterval(id)))
    }
    func awaiting(_ id: Int) -> ConversationItem {
        ConversationItem(id: id, kind: .awaiting(.permission(tool: "Bash")),
                         timestamp: Date(timeIntervalSince1970: TimeInterval(id)))
    }

    @Test("running 且同名 tool → 命中(权限在工具执行前抛,行已写入且 running)")
    func runningSameName() {
        let items = [tool(0, "Read", .ok), tool(1, "Bash", .running)]
        #expect(MinimalAppDelegate.matchingPermissionRow(in: items, toolName: "Bash")?.id == 1)
    }

    @Test("多条 running 同名 → 取最后一条")
    func lastRunning() {
        let items = [tool(0, "Bash", .running), tool(1, "Edit", .ok), tool(2, "Bash", .running)]
        #expect(MinimalAppDelegate.matchingPermissionRow(in: items, toolName: "Bash")?.id == 2)
    }

    @Test("无同名 running tool 但有 awaiting → 退到 awaiting(计划/问题型)")
    func fallbackAwaiting() {
        let items = [tool(0, "Read", .ok), awaiting(1)]
        #expect(MinimalAppDelegate.matchingPermissionRow(in: items, toolName: "ExitPlanMode")?.id == 1)
    }

    @Test("同名 tool 已收尾(非 running)且无 awaiting → 退到最后一条同名 tool")
    func fallbackSameNameDone() {
        let items = [tool(0, "Bash", .ok), tool(1, "Bash", .error)]
        #expect(MinimalAppDelegate.matchingPermissionRow(in: items, toolName: "Bash")?.id == 1)
    }

    @Test("无任何匹配 → nil(竞态:行还没轮询到)")
    func noMatch() {
        let items = [tool(0, "Read", .ok)]
        #expect(MinimalAppDelegate.matchingPermissionRow(in: items, toolName: "Bash") == nil)
    }
}
