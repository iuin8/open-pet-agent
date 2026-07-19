import Testing
import Foundation
@testable import AgentSensing

@Suite("AgentConversation — events → 对话项(折叠 tool 对)")
struct AgentConversationTests {

    func e(_ kind: AgentEventKind, _ t: TimeInterval, session: String = "s", detail: String? = nil) -> AgentEvent {
        AgentEvent(agent: .claudeCode, sessionId: session, cwd: nil, kind: kind, timestamp: Date(timeIntervalSince1970: t), detail: detail)
    }

    @Test("toolUse + 紧随 toolResult 折叠成一条带成败(ok)")
    func foldsToolPair() {
        let items = AgentConversation.build(from: [
            e(.toolUse(name: "Bash", summary: "npm test"), 1),
            e(.toolResult(name: "", isError: false), 2),
        ])
        #expect(items.count == 1)
        if case .tool(let name, let summary, let st, _, _) = items[0].kind {
            #expect(name == "Bash"); #expect(summary == "npm test"); #expect(st == .ok)
        } else { Issue.record("应折叠成 .tool 项") }
    }

    @Test("tool 折叠携带 input(toolUse detail)+ output(toolResult detail)—— 给详情展开")
    func foldCarriesDetail() {
        let items = AgentConversation.build(from: [
            e(.toolUse(name: "Bash", summary: "npm test"), 1, detail: "npm test --coverage"),
            e(.toolResult(name: "", isError: false), 2, detail: "All tests passed (42)"),
        ])
        #expect(items.count == 1)
        if case .tool(_, _, _, let input, let output) = items[0].kind {
            #expect(input == "npm test --coverage")
            #expect(output == "All tests passed (42)")
        } else { Issue.record("应折叠成 .tool 项") }
    }

    @Test("**P0-2** 扁平流并行工具:tool_result 按 tool_use_id 精确配对(FIFO 回传不张冠李戴)")
    func flatParallelToolsPairById() {
        func tool(_ summary: String, id: String, detail: String) -> AgentEvent {
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil, kind: .toolUse(name: "Read", summary: summary),
                       timestamp: Date(timeIntervalSince1970: 1), detail: detail, toolUseId: id)
        }
        func result(_ id: String, isError: Bool, output: String) -> AgentEvent {
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil, kind: .toolResult(name: "", isError: isError),
                       timestamp: Date(timeIntervalSince1970: 2), detail: output, toolUseId: id)
        }
        // 并行两工具 t1,t2;结果 FIFO 回传(t1 先)→ 纯 LIFO 会把 t1 的 output 挂到 t2。
        let items = AgentConversation.build(from: [
            tool("A.swift", id: "t1", detail: "/a/A.swift"),
            tool("B.swift", id: "t2", detail: "/a/B.swift"),
            result("t1", isError: false, output: "AAA"),
            result("t2", isError: true, output: "BBB"),
        ])
        #expect(items.count == 2)
        for item in items {
            guard case .tool(_, let summary, let state, _, let output) = item.kind else { continue }
            if item.toolUseId == "t1" { #expect(summary == "A.swift" && output == "AAA" && state == .ok) }
            if item.toolUseId == "t2" { #expect(summary == "B.swift" && output == "BBB" && state == .error) }
        }
    }

    @Test("toolResult(isError) → .error")
    func toolError() {
        let items = AgentConversation.build(from: [
            e(.toolUse(name: "Bash", summary: "x"), 1),
            e(.toolResult(name: "", isError: true), 2),
        ])
        if case .tool(_, _, let st, _, _) = items.first?.kind { #expect(st == .error) }
        else { Issue.record("应是 .tool") }
    }

    @Test("user / assistant 直出")
    func userAssistant() {
        let items = AgentConversation.build(from: [
            e(.userPrompt(text: "修个 bug"), 1),
            e(.assistantText(text: "好的"), 2),
        ])
        #expect(items.count == 2)
        #expect(items[0].kind == .user(text: "修个 bug"))
        #expect(items[1].kind == .assistant(text: "好的"))
    }

    @Test("awaitingUser → .awaiting")
    func awaiting() {
        let items = AgentConversation.build(from: [e(.awaitingUser(reason: .question(title: "选哪个")), 1)])
        #expect(items.count == 1)
        if case .awaiting(let r) = items[0].kind { #expect(r == .question(title: "选哪个")) }
        else { Issue.record("应是 .awaiting") }
    }

    @Test("systemNotice → 中性系统通知项")
    func systemNoticeVisibleButNotUser() {
        let items = AgentConversation.build(from: [e(.systemNotice(text: "协作会话消息 · reviewer：APPROVE"), 1, detail: "<teammate-message>APPROVE</teammate-message>")])
        #expect(items.count == 1)
        #expect(items[0].kind == .systemNotice(text: "协作会话消息 · reviewer：APPROVE"))
        #expect(items[0].systemNoticeDetail == "<teammate-message>APPROVE</teammate-message>")
        #expect(items[0].detailAffordance == .sideCard)
    }

    @Test("sessionStart / done 不产可见项")
    func noiseSkipped() {
        let items = AgentConversation.build(from: [
            e(.sessionStart, 1),
            e(.assistantText(text: "活"), 2),
            e(.done, 3),
        ])
        #expect(items.count == 1)
        #expect(items[0].kind == .assistant(text: "活"))
    }

    @Test("孤立 toolResult(无 running tool)被忽略")
    func orphanResult() {
        let items = AgentConversation.build(from: [e(.toolResult(name: "", isError: false), 1)])
        #expect(items.isEmpty)
    }

    @Test("顺序保持 + id = idStart + 事件下标(折叠的 toolResult 留空隙)")
    func orderAndIDs() {
        let items = AgentConversation.build(from: [
            e(.userPrompt(text: "a"), 1),                    // 事件 0 → id 0
            e(.toolUse(name: "Read", summary: "F.swift"), 2), // 事件 1 → id 1
            e(.toolResult(name: "", isError: false), 3),     // 事件 2 → 折叠进 id 1,不产项
            e(.assistantText(text: "b"), 4),                  // 事件 3 → id 3
        ])
        #expect(items.count == 3)   // user + tool(folded) + assistant
        #expect(items.map(\.id) == [0, 1, 3])   // 事件偏移:折叠掉的事件 2 留空隙
        if case .user = items[0].kind {} else { Issue.record("0=user") }
        if case .tool = items[1].kind {} else { Issue.record("1=tool") }
        if case .assistant = items[2].kind {} else { Issue.record("2=assistant") }
    }

    @Test("G4:idStart 下移 P → 既有事件的 item id 恒定(prepend 不漂)")
    func idStableUnderPrepend() {
        let tail = [e(.userPrompt(text: "问"), 10), e(.assistantText(text: "答"), 11)]
        let base = AgentConversation.build(from: tail, idStart: 0)
        #expect(base.map(\.id) == [0, 1])
        // 在前面 prepend 3 条更早事件 → 调用方把 idStart 下移 3;尾部两条仍是 id 0/1。
        let earlier = [e(.userPrompt(text: "更早1"), 1), e(.assistantText(text: "更早2"), 2), e(.userPrompt(text: "更早3"), 3)]
        let combined = AgentConversation.build(from: earlier + tail, idStart: -3)
        #expect(combined.map(\.id) == [-3, -2, -1, 0, 1])   // 更早 3 条拿负 id,原尾部 0/1 不变
        #expect(combined.suffix(2).map(\.id) == base.map(\.id))
    }
}
