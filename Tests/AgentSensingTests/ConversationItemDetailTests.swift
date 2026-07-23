import Testing
import Foundation
@testable import AgentSensing

@Suite("ConversationItem.detailAffordance — 详情展开方式判定(2026-06-16:统一走侧卡)")
struct ConversationItemDetailTests {

    func tool(input: String? = nil, output: String? = nil) -> ConversationItem {
        ConversationItem(
            id: 0,
            kind: .tool(name: "Bash", summary: "x", state: .ok, input: input, output: output),
            timestamp: Date(timeIntervalSince1970: 1)
        )
    }

    @Test("tool 无 input/output → .none(不可展开)")
    func noDetail() {
        #expect(tool().detailAffordance == .none)
        #expect(tool(input: "", output: "").detailAffordance == .none)
    }

    @Test("tool 有 input(无论长短)→ .sideCard(所有详情统一走侧卡,内联 accordion 退役)")
    func anyInput() {
        #expect(tool(input: "npm test").detailAffordance == .sideCard)
        #expect(tool(input: String(repeating: "x", count: 800)).detailAffordance == .sideCard)
    }

    @Test("tool 有 output(无论长短)→ .sideCard")
    func anyOutput() {
        #expect(tool(output: "All tests passed").detailAffordance == .sideCard)
        let long = (1...20).map { "line \($0)" }.joined(separator: "\n")
        #expect(tool(output: long).detailAffordance == .sideCard)
    }

    let t = Date(timeIntervalSince1970: 1)
    func text(_ kind: ConversationItem.Kind) -> ConversationItem { ConversationItem(id: 0, kind: kind, timestamp: t) }

    @Test("awaiting 无 detail → .none；有 detail → .sideCard")
    func awaitingDetailAffordance() {
        #expect(text(.awaiting(.question(title: "q"))).detailAffordance == .none)
        let detailed = ConversationItem(
            id: 0,
            kind: .awaiting(.question(title: "q")),
            timestamp: t,
            awaitingDetail: "问题\n- A: 描述"
        )
        #expect(detailed.detailAffordance == .sideCard)
    }

    @Test("短 user/assistant 文本(≤3 行 + ≤180 字)→ .none(直显,无需展开)")
    func shortText() {
        #expect(text(.user(text: "hi")).detailAffordance == .none)
        #expect(text(.assistant(text: String(repeating: "x", count: 50))).detailAffordance == .none)   // 50 < 70
        let threeLines = (1...3).map { "行 \($0)" }.joined(separator: "\n")
        #expect(text(.assistant(text: threeLines)).detailAffordance == .none)                          // 3 ≤ 3 行
    }

    @Test("超 3 行 / 超 70 字 → .sideCard(2026-06-16:主流最多 3 行,超则截断+点击看详情)")
    func longText() {
        #expect(text(.assistant(text: String(repeating: "x", count: 80))).detailAffordance == .sideCard)    // >70 字符
        let fourLines = (1...4).map { "行 \($0)" }.joined(separator: "\n")
        #expect(text(.user(text: fourLines)).detailAffordance == .sideCard)                                 // >3 行
    }
}
