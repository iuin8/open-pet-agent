import Testing
import Foundation
import AgentSensing
import Rendering
@testable import App

/// 验证 AgentActivityVisualMapper 严格对照 petdex 官方 `stateForEvent`(原汁原味)把原始 AgentEvent 映射成视觉态。
@Suite("AgentActivityVisualMapper — petdex 官方 stateForEvent 忠实映射")
struct AgentActivityVisualMapperTests {

    private func ev(_ kind: AgentEventKind) -> AgentEvent {
        AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil, kind: kind, timestamp: Date())
    }

    @Test("user prompt → .celebrating(jumping 行,你发问桌宠雀跃)")
    func userPromptJumps() {
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.userPrompt(text: "hi"))) == .celebrating)
    }

    @Test("只读工具 read/grep/glob → .reviewing(review 行,小写比较)")
    func readOnlyToolsReview() {
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolUse(name: "Read", summary: "x"))) == .reviewing)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolUse(name: "Grep", summary: "x"))) == .reviewing)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolUse(name: "glob", summary: "x"))) == .reviewing)
    }

    @Test("其余工具 → .working(running 行)")
    func otherToolsRun() {
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolUse(name: "Bash", summary: "x"))) == .working)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolUse(name: "Edit", summary: "x"))) == .working)
    }

    @Test("工具出错 → .failed;成功 → .idle(petdex session.error / post)")
    func toolResultMapping() {
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolResult(name: "Bash", isError: true))) == .failed)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.toolResult(name: "Bash", isError: false))) == .idle)
    }

    @Test("awaitingUser → .waiting / done → .idle")
    func waitingAndDone() {
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.awaitingUser(reason: .question(title: "发布?")))) == .waiting)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.done)) == .idle)
    }

    @Test("生成文本/思考/sessionStart/中断 → nil(不改态,根治「一直挥手」;petdex 无此 hook)")
    func generatingDoesNotChange() {
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.assistantText(text: "hi"))) == nil)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.thinking(text: "..."))) == nil)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.sessionStart)) == nil)
        #expect(AgentActivityVisualMapper.visual(forEvent: ev(.interrupted)) == nil)
    }
}
